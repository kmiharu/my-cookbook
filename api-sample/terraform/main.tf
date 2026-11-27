locals {
  dynamodb   = var.database_type != "aurora"
  postgres   = var.database_type != "dynamodb"
  hybrid     = var.database_type == "hybrid"
  list_gsis  = var.database_type == "dynamodb"
  proxy      = local.postgres && var.enable_rds_proxy
  http_api   = var.api_type == "http"
  has_domain = var.domain_name != null
  db_name    = "products"

  functions = merge(
    { api = "${var.name}-api" },
    local.hybrid ? { sync = "${var.name}-sync" } : {}
  )

  list_indexes = local.list_gsis ? {
    all-products         = "listPk"
    products-by-category = "categoryPk"
  } : {}

  pg_endpoint = local.postgres ? (local.proxy ? aws_db_proxy.database[0].endpoint : aws_rds_cluster.database[0].endpoint) : null
  pg_tls      = local.proxy ? "sslfactory=org.postgresql.ssl.DefaultJavaSSLFactory" : "sslrootcert=/var/task/rds-ca.pem"
  pg_environment = local.postgres ? {
    PG_JDBC_URL   = "jdbc:postgresql://${local.pg_endpoint}:5432/${local.db_name}?sslmode=verify-full&${local.pg_tls}"
    PG_SECRET_ARN = var.pg_secret_arn
    PG_POOL_SIZE  = tostring(var.pg_pool_size)
  } : {}
}

resource "terraform_data" "configuration" {
  lifecycle {
    precondition {
      condition     = local.postgres ? var.pg_secret_arn != null : !var.enable_rds_proxy
      error_message = "Aurora and hybrid require pg_secret_arn. RDS Proxy requires Aurora."
    }
    precondition {
      condition = local.postgres && var.pg_secret_arn != null ? startswith(
        var.pg_secret_arn, "arn:${data.aws_partition.current.partition}:secretsmanager:${var.aws_region}:${data.aws_caller_identity.current[0].account_id}:secret:"
      ) : true
      error_message = "Use a runtime secret in the same AWS account and Region."
    }
    precondition {
      condition     = local.has_domain ? can(regex("^[0-9a-f]{32}$", var.cloudflare_zone_id)) : var.cloudflare_zone_id == null
      error_message = "Set domain_name and a 32-character Cloudflare zone ID together."
    }
  }
}

resource "aws_dynamodb_table" "products" {
  count            = local.dynamodb ? 1 : 0
  name             = "${var.name}-products"
  billing_mode     = "PAY_PER_REQUEST"
  hash_key         = "id"
  stream_enabled   = local.hybrid
  stream_view_type = local.hybrid ? "NEW_AND_OLD_IMAGES" : null

  dynamic "attribute" {
    for_each = local.list_gsis ? toset(["id", "listPk", "categoryPk", "listSk"]) : toset(["id"])
    content {
      name = attribute.value
      type = "S"
    }
  }

  dynamic "global_secondary_index" {
    for_each = local.list_indexes
    content {
      name            = global_secondary_index.key
      hash_key        = global_secondary_index.value
      range_key       = "listSk"
      projection_type = "ALL"
    }
  }
}

resource "aws_cloudwatch_log_group" "function" {
  for_each          = local.functions
  name              = "/aws/lambda/${each.value}"
  retention_in_days = 14
}

resource "aws_lambda_function" "application" {
  for_each                       = local.functions
  function_name                  = each.value
  runtime                        = "java21"
  architectures                  = ["x86_64"]
  filename                       = var.lambda_zip_path
  source_code_hash               = try(filebase64sha256(var.lambda_zip_path), null)
  role                           = aws_iam_role.function[each.key].arn
  memory_size                    = each.key == "api" ? var.api_memory_mb : 1024
  timeout                        = each.key == "api" ? 28 : 75
  publish                        = each.key == "api" && var.enable_api_snapstart
  reserved_concurrent_executions = each.key == "api" ? var.api_reserved_concurrency : -1

  handler = each.key == "sync" ? "cookbook.api.sync.SyncHandler" : (
    local.http_api ? "io.micronaut.function.aws.proxy.payload2.APIGatewayV2HTTPEventFunction" :
    "io.micronaut.function.aws.proxy.payload1.ApiGatewayProxyRequestEventFunction"
  )

  environment {
    variables = merge(
      {
        APP_RUNTIME   = "aws"
        APP_ROLE      = each.key
        DATABASE_TYPE = var.database_type
      },
      local.dynamodb ? { DYNAMODB_TABLE = aws_dynamodb_table.products[0].name } : {},
      local.hybrid && each.key == "api" ? { AWS_ACCOUNT_ID_ENDPOINT_MODE = "disabled" } : {},
      local.pg_environment
    )
  }

  dynamic "vpc_config" {
    for_each = local.postgres ? [1] : []
    content {
      subnet_ids         = aws_subnet.private[*].id
      security_group_ids = [aws_security_group.client[each.key].id]
    }
  }

  dynamic "snap_start" {
    for_each = each.key == "api" && var.enable_api_snapstart ? [1] : []
    content {
      apply_on = "PublishedVersions"
    }
  }

  depends_on = [terraform_data.configuration, aws_iam_role_policy.function, aws_vpc_endpoint.secrets, aws_vpc_endpoint.dynamodb]
}

resource "aws_lambda_alias" "api" {
  count            = var.enable_api_snapstart ? 1 : 0
  name             = "live"
  function_name    = aws_lambda_function.application["api"].function_name
  function_version = aws_lambda_function.application["api"].version
}
