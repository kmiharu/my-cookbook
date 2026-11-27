variable "name" {
  type = string
}
variable "region" {
  type = string
}
variable "db_url" {
  type = string
  validation {
    condition     = can(regex("^jdbc:postgresql://[^/@]+/", var.db_url)) && can(regex("[?&]sslmode=verify-full($|&)", var.db_url)) && !can(regex("(?i)[?&](user|password|sslpassword)=", var.db_url))
    error_message = "Use a PostgreSQL JDBC URL with sslmode=verify-full and no credentials."
  }
}
variable "db_secret_arn" {
  type = string
}
variable "execution_kms_key_arns" {
  type    = list(string)
  default = []
}
variable "task_kms_key_arns" {
  type    = list(string)
  default = []
}
variable "internal_bucket" {
  type = string
}
variable "input_bucket" {
  type = string
}
variable "partner" {
  type = object({
    bucket   = string
    region   = string
    role_arn = optional(string)
    prefix   = optional(string, "")
  })
  default  = null
  nullable = true
}
variable "dynamo_table" {
  type = object({
    name = string
    arn  = string
  })
}
variable "dynamo_operations_table" {
  type = object({
    name = string
    arn  = string
  })
}
variable "subnet_ids" {
  type = list(string)
  validation {
    condition     = length(var.subnet_ids) >= 1 && length(var.subnet_ids) <= 16
    error_message = "Select 1–16 ECS task subnets."
  }
}
variable "security_group_ids" {
  type = list(string)
  validation {
    condition     = length(var.security_group_ids) >= 1 && length(var.security_group_ids) <= 5
    error_message = "Select 1–5 ECS task security groups."
  }
}
variable "image_uri" {
  type     = string
  default  = null
  nullable = true
  validation {
    condition     = var.image_uri == null ? true : can(regex("@sha256:[0-9a-f]{64}$", var.image_uri))
    error_message = "Pass an immutable ECR image URI with its sha256 digest."
  }
}
variable "cpu" {
  type    = number
  default = 1024
}
variable "memory" {
  type    = number
  default = 4096
}
variable "architecture" {
  type    = string
  default = "X86_64"
  validation {
    condition     = contains(["X86_64", "ARM64"], var.architecture)
    error_message = "Set architecture to X86_64 or ARM64."
  }
}
variable "log_retention_days" {
  type    = number
  default = 30
}
variable "input_prefix" {
  type    = string
  default = ""
}
variable "internal_prefix" {
  type    = string
  default = ""
}
variable "input_region" {
  type    = string
  default = null
}
variable "internal_region" {
  type    = string
  default = null
}
variable "target_db_url" {
  type    = string
  default = null
  validation {
    condition     = var.target_db_url == null ? true : can(regex("^jdbc:postgresql://[^/@]+/", var.target_db_url)) && can(regex("[?&]sslmode=verify-full($|&)", var.target_db_url)) && !can(regex("(?i)[?&](user|password|sslpassword)=", var.target_db_url))
    error_message = "Use a PostgreSQL target JDBC URL with sslmode=verify-full and no credentials."
  }
}
variable "dynamo_region" {
  type    = string
  default = null
}
variable "target_db_secret_arn" {
  type    = string
  default = null
}
