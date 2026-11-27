variable "region" {
  type = string
}

variable "caller_task_role_arn" {
  description = "Task role ARN supplied by the sender account."
  type        = string
}

variable "bucket_arn" {
  description = "Recipient-owned existing bucket ARN."
  type        = string
}

variable "object_prefix" {
  description = "Prefix including the trailing slash. Empty grants access across the bucket."
  type        = string
  validation {
    condition     = var.object_prefix == "" || endswith(var.object_prefix, "/")
    error_message = "Include a trailing slash in a nonempty prefix."
  }
}

variable "kms_key_arn" {
  description = "Existing recipient CMK ARN for role access. Null for buckets without a customer-managed key."
  type        = string
  default     = null
}

variable "assume_role_name" {
  description = "Set to create a dedicated recipient role in this root. Leave null for direct TaskRole access."
  type        = string
  default     = null
}

variable "terraform_operator_role_arn" {
  description = "Optional role the Terraform operator uses in the recipient account."
  type        = string
  default     = null
}

provider "aws" {
  alias  = "recipient"
  region = var.region
  dynamic "assume_role" {
    for_each = var.terraform_operator_role_arn == null ? [] : [var.terraform_operator_role_arn]
    content {
      role_arn = assume_role.value
    }
  }
}

data "aws_iam_policy_document" "trust" {
  provider = aws.recipient
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [var.caller_task_role_arn]
    }
  }
}

resource "aws_iam_role" "recipient" {
  provider           = aws.recipient
  count              = var.assume_role_name == null ? 0 : 1
  name               = var.assume_role_name
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

locals {
  effective_role_arn = var.assume_role_name == null ? var.caller_task_role_arn : aws_iam_role.recipient[0].arn
  object_resources   = ["${var.bucket_arn}/${var.object_prefix}*"]
  object_actions     = ["s3:PutObject", "s3:GetObject", "s3:GetObjectVersion", "s3:AbortMultipartUpload", "s3:ListMultipartUploadParts"]
  bucket_actions     = ["s3:ListBucket", "s3:ListBucketMultipartUploads"]
  kms_actions        = ["kms:Encrypt", "kms:Decrypt", "kms:GenerateDataKey"]
}

resource "aws_iam_role_policy" "recipient" {
  provider = aws.recipient
  count    = var.assume_role_name == null ? 0 : 1
  name     = "write-and-verify-batch-artifacts"
  role     = aws_iam_role.recipient[0].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat([
      { Effect = "Allow", Action = local.object_actions, Resource = local.object_resources },
      { Effect = "Allow", Action = local.bucket_actions, Resource = [var.bucket_arn] }
      ], var.kms_key_arn == null ? [] : [{
        Effect = "Allow", Action = local.kms_actions, Resource = [var.kms_key_arn]
    }])
  })
}

output "assume_role_arn" {
  description = "Use as partner.role_arn in the sender task configuration."
  value       = try(aws_iam_role.recipient[0].arn, null)
}

output "bucket_policy_statements" {
  description = "Review and merge these statements into the recipient's existing bucket policy."
  value = [
    {
      Sid       = "AllowBatchObjectTransfers"
      Effect    = "Allow"
      Principal = { AWS = local.effective_role_arn }
      Action    = local.object_actions
      Resource  = local.object_resources
    },
    {
      Sid       = "AllowBatchMultipartDiscovery"
      Effect    = "Allow"
      Principal = { AWS = local.effective_role_arn }
      Action    = local.bucket_actions
      Resource  = [var.bucket_arn]
    }
  ]
}

output "kms_policy_statement" {
  description = "Review and merge into the existing recipient key policy when using SSE-KMS."
  value = var.kms_key_arn == null ? null : {
    Sid       = "AllowBatchArtifactEncryption"
    Effect    = "Allow"
    Principal = { AWS = local.effective_role_arn }
    Action    = local.kms_actions
    Resource  = "*"
    Condition = { StringEquals = { "kms:ViaService" = "s3.${var.region}.amazonaws.com" } }
  }
}

output "trust_policy_principal" {
  description = "Caller principal used for AssumeRole if enabled."
  value       = var.caller_task_role_arn
}
