output "api_base_url" {
  description = "Public API URL for the configured gateway and stage."
  value = local.has_domain ? "https://${var.domain_name}" : (
    local.http_api ? aws_apigatewayv2_api.http[0].api_endpoint : aws_api_gateway_stage.rest[0].invoke_url
  )
}

output "migration_connection" {
  description = "Private placement and bootstrap secret ARN for an independently managed Aurora migration runner."
  value = local.postgres ? {
    writer_host       = aws_rds_cluster.database[0].endpoint
    database          = local.db_name
    subnet_ids        = aws_subnet.private[*].id
    security_group_id = aws_security_group.client["migration"].id
    admin_secret_arn  = aws_rds_cluster.database[0].master_user_secret[0].secret_arn
  } : null
}

output "sync_failure_bucket" {
  description = "Bucket containing failed Streams invocations and their records."
  value       = local.hybrid ? aws_s3_bucket.sync_failures[0].id : null
}
