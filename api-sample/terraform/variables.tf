variable "name" {
  description = "Prefix for AWS resource names."
  type        = string
  default     = "cookbook-products"
  validation {
    condition     = can(regex("^[a-z]([a-z0-9]|-[a-z0-9]){1,24}$", var.name)) && length(var.name) <= 25
    error_message = "Use 2 to 25 lowercase letters, digits, or single hyphens, starting with a letter and ending with a letter or digit."
  }
}

variable "aws_region" {
  description = "AWS Region for this stack, including the optional regional ACM certificate."
  type        = string
  default     = "us-east-1"
}

variable "database_type" {
  description = "Persistence mode for the API Lambda."
  type        = string
  default     = "dynamodb"
  validation {
    condition     = contains(["dynamodb", "aurora", "hybrid"], var.database_type)
    error_message = "Choose dynamodb, aurora, or hybrid."
  }
}

variable "api_type" {
  description = "API Gateway HTTP API payload 2.0 or REST API payload 1.0."
  type        = string
  default     = "http"
  validation {
    condition     = contains(["http", "rest"], var.api_type)
    error_message = "Choose http or rest."
  }
}

variable "lambda_zip_path" {
  description = "Gradle deployment ZIP path. Relative paths are resolved from the Terraform working directory."
  type        = string
  default     = "../app/build/distributions/api-lambda.zip"
}

variable "api_memory_mb" {
  description = "Memory allocated to the API Lambda."
  type        = number
  default     = 1024
}

variable "api_reserved_concurrency" {
  description = "API Lambda concurrency cap. Use -1 for unreserved concurrency."
  type        = number
  default     = -1
}

variable "enable_api_snapstart" {
  description = "Publish API Lambda versions with SnapStart and route requests through an alias."
  type        = bool
  default     = false
}

variable "availability_zone_ids" {
  description = "Two distinct AZ IDs in aws_region for private subnets. Choose IDs that support RDS Proxy when it is enabled."
  type        = list(string)
  default     = ["use1-az1", "use1-az2"]
  validation {
    condition     = length(var.availability_zone_ids) == 2 && length(distinct(var.availability_zone_ids)) == 2
    error_message = "Specify two distinct availability zone IDs."
  }
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL 16 minor version. Verify regional availability before future deployment."
  type        = string
  default     = "16.11"
}

variable "pg_secret_arn" {
  description = "Existing same-account, same-region Secrets Manager secret with runtime database username and password."
  type        = string
  default     = null
  validation {
    condition     = var.pg_secret_arn == null ? true : can(regex("^arn:[^:]+:secretsmanager:[^:]+:[0-9]{12}:secret:.+$", var.pg_secret_arn))
    error_message = "Use a complete Secrets Manager secret ARN."
  }
}

variable "pg_secret_kms_key_arn" {
  description = "Customer-managed encryption key ARN for pg_secret_arn. Leave null for aws/secretsmanager."
  type        = string
  default     = null
}

variable "pg_pool_size" {
  description = "Maximum JDBC connection pool size per Lambda execution environment."
  type        = number
  default     = 2
  validation {
    condition     = var.pg_pool_size >= 1 && var.pg_pool_size <= 32 && floor(var.pg_pool_size) == var.pg_pool_size
    error_message = "Specify an integer from 1 to 32."
  }
}

variable "enable_rds_proxy" {
  description = "Place RDS Proxy between Lambda and Aurora."
  type        = bool
  default     = false
}

variable "domain_name" {
  description = "Fully qualified API domain in an existing Cloudflare DNS zone. Null disables the domain."
  type        = string
  default     = null
  validation {
    condition     = var.domain_name == null ? true : can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?(\\.[a-z0-9]([a-z0-9-]*[a-z0-9])?)+$", var.domain_name))
    error_message = "Use a lowercase fully qualified hostname such as api.example.com."
  }
}

variable "cloudflare_zone_id" {
  description = "ID of the existing Cloudflare DNS zone containing domain_name."
  type        = string
  default     = null
}
