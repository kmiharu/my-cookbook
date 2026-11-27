data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  trust_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = {
        StringEquals = { "aws:SourceAccount" = data.aws_caller_identity.current.account_id }
        ArnLike      = { "aws:SourceArn" = "arn:${data.aws_partition.current.partition}:ecs:${var.region}:${data.aws_caller_identity.current.account_id}:*" }
      }
    }]
  })
  partner_role_arn = try(var.partner.role_arn, null)
  readable_buckets = compact([
    var.input_bucket,
    var.internal_bucket,
    local.partner_role_arn == null ? try(var.partner.bucket, null) : null,
  ])
  writable_buckets = compact([
    var.internal_bucket,
    local.partner_role_arn == null ? try(var.partner.bucket, null) : null,
  ])
  s3_arn = "arn:${data.aws_partition.current.partition}:s3:::"
  table_arns = [
    var.dynamo_table.arn,
    var.dynamo_operations_table.arn
  ]
  container_name = "batch"
}

resource "aws_ecr_repository" "batch" {
  name                 = var.name
  image_tag_mutability = "IMMUTABLE"
  force_delete         = false
  image_scanning_configuration {
    scan_on_push = true
  }
}

resource "aws_cloudwatch_log_group" "batch" {
  name              = "/ecs/${var.name}"
  retention_in_days = var.log_retention_days
}

resource "aws_ecs_cluster" "batch" {
  name = var.name
}

resource "aws_iam_role" "execution" {
  name               = "${var.name}-execution"
  assume_role_policy = local.trust_policy
}

resource "aws_iam_role_policy" "execution" {
  name = "pull-image-log-and-inject-secret"
  role = aws_iam_role.execution.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect   = "Allow"
        Action   = ["ecr:GetAuthorizationToken"]
        Resource = ["*"]
      },
      {
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
        Resource = [aws_ecr_repository.batch.arn]
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = ["${aws_cloudwatch_log_group.batch.arn}:*"]
      },
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = compact([var.db_secret_arn, var.target_db_secret_arn])
      }
      ], length(var.execution_kms_key_arns) == 0 ? [] : [{
        Effect   = "Allow"
        Action   = ["kms:Decrypt"]
        Resource = var.execution_kms_key_arns
    }])
  })
}

resource "aws_iam_role" "task" {
  name               = "${var.name}-task"
  assume_role_policy = local.trust_policy
}

resource "aws_iam_role_policy" "task" {
  name = "transfer-and-deliver-batch-data"
  role = aws_iam_role.task.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucket", "s3:GetBucketVersioning"]
        Resource = distinct([for bucket in local.readable_buckets : "${local.s3_arn}${bucket}"])
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject", "s3:GetObjectVersion"]
        Resource = distinct([for bucket in local.readable_buckets : "${local.s3_arn}${bucket}/*"])
      },
      {
        Effect   = "Allow"
        Action   = ["s3:ListBucketMultipartUploads"]
        Resource = distinct([for bucket in local.writable_buckets : "${local.s3_arn}${bucket}"])
      },
      {
        Effect   = "Allow"
        Action   = ["s3:PutObject", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
        Resource = distinct([for bucket in local.writable_buckets : "${local.s3_arn}${bucket}/*"])
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:DescribeTable", "dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem", "dynamodb:UpdateItem", "dynamodb:Scan", "dynamodb:Query", "dynamodb:BatchWriteItem", "dynamodb:ConditionCheckItem"]
        Resource = concat(local.table_arns, ["${var.dynamo_table.arn}/index/*"])
      }
      ], length(var.task_kms_key_arns) == 0 ? [] : [{
        Effect   = "Allow"
        Action   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"]
        Resource = var.task_kms_key_arns
        }], local.partner_role_arn == null ? [] : [{
        Effect   = "Allow"
        Action   = ["sts:AssumeRole"]
        Resource = [local.partner_role_arn]
    }])
  })
}

locals {
  environment = merge({
    SPRING_PROFILES_ACTIVE        = "ecs"
    BATCH_DB_URL                  = var.db_url
    BATCH_INPUT_BUCKET            = var.input_bucket
    BATCH_INPUT_PREFIX            = var.input_prefix
    BATCH_INPUT_REGION            = coalesce(var.input_region, var.region)
    BATCH_INTERNAL_BUCKET         = var.internal_bucket
    BATCH_INTERNAL_REGION         = coalesce(var.internal_region, var.region)
    BATCH_INTERNAL_PREFIX         = var.internal_prefix
    BATCH_DYNAMO_TABLE            = var.dynamo_table.name
    BATCH_DYNAMO_REGION           = coalesce(var.dynamo_region, var.region)
    BATCH_DYNAMO_OPERATIONS_TABLE = var.dynamo_operations_table.name
    AWS_REGION                    = var.region
    JAVA_TOOL_OPTIONS             = "-Xmx512m -XX:+ExitOnOutOfMemoryError"
    }, var.partner == null ? {} : {
    BATCH_PARTNER_BUCKET = var.partner.bucket
    BATCH_PARTNER_REGION = var.partner.region
    BATCH_PARTNER_PREFIX = var.partner.prefix
    }, local.partner_role_arn == null ? {} : {
    BATCH_PARTNER_ROLE_ARN = local.partner_role_arn
    }, var.target_db_url == null ? {} : {
    BATCH_TARGET_DB_URL = var.target_db_url
  })
  container_definitions = [{
    name        = local.container_name
    image       = var.image_uri
    essential   = true
    stopTimeout = 120
    environment = [for name, value in local.environment : { name = name, value = value }]
    secrets = concat([
      { name = "BATCH_DB_USER", valueFrom = "${var.db_secret_arn}:username::" },
      { name = "BATCH_DB_PASSWORD", valueFrom = "${var.db_secret_arn}:password::" },
      ], var.target_db_secret_arn == null ? [] : [
      { name = "BATCH_TARGET_DB_USER", valueFrom = "${var.target_db_secret_arn}:username::" },
      { name = "BATCH_TARGET_DB_PASSWORD", valueFrom = "${var.target_db_secret_arn}:password::" },
    ])
    logConfiguration = {
      logDriver = "awslogs"
      options = {
        awslogs-group         = aws_cloudwatch_log_group.batch.name
        awslogs-region        = var.region
        awslogs-stream-prefix = "job"
      }
    }
  }]
}

resource "aws_ecs_task_definition" "batch" {
  count                    = var.image_uri == null ? 0 : 1
  family                   = var.name
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.cpu
  memory                   = var.memory
  execution_role_arn       = aws_iam_role.execution.arn
  task_role_arn            = aws_iam_role.task.arn
  container_definitions    = jsonencode(local.container_definitions)
  runtime_platform {
    operating_system_family = "LINUX"
    cpu_architecture        = var.architecture
  }
  lifecycle {
    precondition {
      condition     = (var.target_db_url == null) == (var.target_db_secret_arn == null)
      error_message = "Provide both target_db_url and target_db_secret_arn to enable the migration target."
    }
    precondition {
      condition = (
        var.cpu == 1024 && var.memory >= 2048 && var.memory <= 8192 && var.memory % 1024 == 0 ||
        var.cpu == 2048 && var.memory >= 4096 && var.memory <= 16384 && var.memory % 1024 == 0 ||
        var.cpu == 4096 && var.memory >= 8192 && var.memory <= 30720 && var.memory % 1024 == 0 ||
        var.cpu == 8192 && var.memory >= 16384 && var.memory <= 61440 && var.memory % 4096 == 0
      )
      error_message = "Use supported Fargate CPU-memory combinations for 1, 2, 4 or 8 vCPU."
    }
    precondition {
      condition     = startswith(var.image_uri, "${aws_ecr_repository.batch.repository_url}@")
      error_message = "Push the digest to the ECR repository managed by this module."
    }
  }
}
