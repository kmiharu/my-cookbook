mock_provider "aws" {
  mock_data "aws_partition" {
    override_during = plan
    defaults = {
      partition  = "aws"
      dns_suffix = "amazonaws.com"
    }
  }

  mock_data "aws_caller_identity" {
    override_during = plan
    defaults = {
      account_id = "111122223333"
    }
  }
}

mock_provider "cloudflare" {}

run "dynamodb_http" {
  command = plan

  assert {
    condition = (
      length(aws_dynamodb_table.products) == 1 &&
      length(local.list_indexes) == 2 &&
      !aws_dynamodb_table.products[0].stream_enabled &&
      length(aws_rds_cluster.database) == 0 &&
      length(aws_vpc_endpoint.secrets) == 0 &&
      length(aws_lambda_function.application) == 1 &&
      length(aws_lambda_function.application["api"].vpc_config) == 0
    )
    error_message = "DynamoDB should use two list indexes and an API Lambda without an Aurora dependency."
  }

  assert {
    condition = (
      aws_apigatewayv2_integration.http[0].payload_format_version == "2.0" &&
      endswith(aws_lambda_function.application["api"].handler, ".APIGatewayV2HTTPEventFunction") &&
      length(aws_api_gateway_rest_api.rest) == 0 &&
      length(cloudflare_dns_record.api) == 0
    )
    error_message = "The default configuration should select only the HTTP API v2 handler."
  }
}

run "aurora_rest_with_proxy_and_domain" {
  command = plan

  variables {
    database_type      = "aurora"
    api_type           = "rest"
    pg_secret_arn      = "arn:aws:secretsmanager:us-east-1:111122223333:secret:cookbook-app-abcdef"
    enable_rds_proxy   = true
    domain_name        = "api.example.com"
    cloudflare_zone_id = "00000000000000000000000000000000"
  }

  assert {
    condition = (
      length(aws_dynamodb_table.products) == 0 &&
      length(aws_vpc_endpoint.dynamodb) == 0 &&
      length(aws_vpc_endpoint.secrets) == 1 &&
      length(aws_lambda_function.application) == 1 &&
      length(aws_rds_cluster_instance.writer) == 1 &&
      aws_db_proxy.database[0].require_tls &&
      length(aws_vpc_security_group_ingress_rule.proxy) == 1
    )
    error_message = "Aurora should use the private TLS proxy path with no DynamoDB resources."
  }

  assert {
    condition = (
      endswith(aws_lambda_function.application["api"].handler, ".ApiGatewayProxyRequestEventFunction") &&
      length(aws_api_gateway_base_path_mapping.rest) == 1 &&
      length(aws_apigatewayv2_api.http) == 0 &&
      !cloudflare_dns_record.api[0].proxied &&
      !cloudflare_dns_record.certificate[0].proxied
    )
    error_message = "REST API and certificate validation should share a DNS-only regional custom domain."
  }
}

run "hybrid_http_with_snapstart" {
  command = plan

  variables {
    database_type        = "hybrid"
    pg_secret_arn        = "arn:aws:secretsmanager:us-east-1:111122223333:secret:cookbook-app-abcdef"
    enable_api_snapstart = true
  }

  assert {
    condition = (
      aws_dynamodb_table.products[0].stream_view_type == "NEW_AND_OLD_IMAGES" &&
      length(aws_dynamodb_table.products[0].global_secondary_index) == 0 &&
      length(aws_vpc_endpoint.dynamodb) == 1 &&
      length(aws_vpc_security_group_egress_rule.dynamodb) == 1 &&
      length(aws_vpc_security_group_ingress_rule.database) == 3 &&
      length(aws_db_proxy.database) == 0
    )
    error_message = "Hybrid should use Streams with private access to DynamoDB and a direct Aurora database path."
  }

  assert {
    condition = (
      length(aws_lambda_function.application) == 2 &&
      aws_lambda_function.application["sync"].handler == "cookbook.api.sync.SyncHandler" &&
      contains(aws_lambda_event_source_mapping.sync[0].function_response_types, "ReportBatchItemFailures") &&
      length(aws_s3_bucket.sync_failures) == 1 &&
      length(aws_lambda_alias.api) == 1 &&
      aws_lambda_function.application["api"].snap_start[0].apply_on == "PublishedVersions"
    )
    error_message = "Hybrid should enable the sync Lambda with a failed-record destination and the optional published API alias."
  }
}
