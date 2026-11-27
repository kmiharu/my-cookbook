locals {
  business_gsi = { name = "by-status", hash = "gsi_pk", range = "gsi_sk" }
  buckets = {
    input    = var.input_bucket
    internal = var.internal_bucket
  }
}

resource "aws_kms_key" "s3" {
  description             = "${var.name} batch S3 encryption"
  deletion_window_in_days = 30
  enable_key_rotation     = true
}

resource "aws_kms_alias" "s3" {
  name          = "alias/${var.name}-batch-s3"
  target_key_id = aws_kms_key.s3.key_id
}

resource "aws_s3_bucket" "batch" {
  for_each      = local.buckets
  bucket        = each.value
  force_destroy = var.force_destroy_buckets
}

resource "aws_s3_bucket_public_access_block" "batch" {
  for_each                = aws_s3_bucket.batch
  bucket                  = each.value.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "batch" {
  for_each = aws_s3_bucket.batch
  bucket   = each.value.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_versioning" "batch" {
  for_each = aws_s3_bucket.batch
  bucket   = each.value.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "batch" {
  for_each = aws_s3_bucket.batch
  bucket   = each.value.id
  rule {
    bucket_key_enabled = true
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.s3.arn
    }
  }
}

resource "aws_s3_bucket_policy" "tls" {
  for_each = aws_s3_bucket.batch
  bucket   = each.value.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "RequireTLS"
      Effect    = "Deny"
      Principal = "*"
      Action    = "s3:*"
      Resource  = [each.value.arn, "${each.value.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
  depends_on = [aws_s3_bucket_public_access_block.batch]
}

resource "aws_s3_bucket_lifecycle_configuration" "batch" {
  for_each = aws_s3_bucket.batch
  bucket   = each.value.id
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"
    filter {}
    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}

resource "aws_dynamodb_table" "business" {
  name                        = "${var.name}-items"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "pk"
  range_key                   = "sk"
  deletion_protection_enabled = var.deletion_protection
  attribute {
    name = "pk"
    type = "S"
  }
  attribute {
    name = "sk"
    type = "S"
  }
  attribute {
    name = local.business_gsi.hash
    type = "S"
  }
  attribute {
    name = local.business_gsi.range
    type = "S"
  }
  global_secondary_index {
    name            = local.business_gsi.name
    projection_type = "ALL"
    key_schema {
      attribute_name = local.business_gsi.hash
      key_type       = "HASH"
    }
    key_schema {
      attribute_name = local.business_gsi.range
      key_type       = "RANGE"
    }
  }
  point_in_time_recovery {
    enabled = true
  }
  server_side_encryption {
    enabled = true
  }
}

resource "aws_dynamodb_table" "operations" {
  name                        = "${var.name}-operations"
  billing_mode                = "PAY_PER_REQUEST"
  hash_key                    = "operation_id"
  deletion_protection_enabled = var.deletion_protection
  attribute {
    name = "operation_id"
    type = "S"
  }
  ttl {
    attribute_name = "expires_at"
    enabled        = var.enable_operation_ttl
  }
  point_in_time_recovery {
    enabled = true
  }
  server_side_encryption {
    enabled = true
  }
}
