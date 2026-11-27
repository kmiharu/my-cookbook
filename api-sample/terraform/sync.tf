resource "aws_s3_bucket" "sync_failures" {
  count  = local.hybrid ? 1 : 0
  bucket = "${var.name}-sync-${data.aws_caller_identity.current[0].account_id}-${var.aws_region}"
}

resource "aws_s3_bucket_public_access_block" "sync_failures" {
  count                   = local.hybrid ? 1 : 0
  bucket                  = aws_s3_bucket.sync_failures[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "sync_failures" {
  count  = local.hybrid ? 1 : 0
  bucket = aws_s3_bucket.sync_failures[0].id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "sync_failures" {
  count  = local.hybrid ? 1 : 0
  bucket = aws_s3_bucket.sync_failures[0].id

  rule {
    id     = "expire-failed-invocations"
    status = "Enabled"
    filter {}
    expiration { days = 30 }
  }
}

resource "aws_lambda_event_source_mapping" "sync" {
  count                          = local.hybrid ? 1 : 0
  event_source_arn               = aws_dynamodb_table.products[0].stream_arn
  function_name                  = aws_lambda_function.application["sync"].arn
  starting_position              = "TRIM_HORIZON"
  batch_size                     = 5
  parallelization_factor         = 1
  maximum_record_age_in_seconds  = 3600
  maximum_retry_attempts         = 5
  bisect_batch_on_function_error = true
  function_response_types        = ["ReportBatchItemFailures"]

  destination_config {
    on_failure {
      destination_arn = aws_s3_bucket.sync_failures[0].arn
    }
  }

  depends_on = [
    aws_s3_bucket_public_access_block.sync_failures,
    aws_s3_bucket_server_side_encryption_configuration.sync_failures,
  ]
}
