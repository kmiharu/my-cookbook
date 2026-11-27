variable "name" {
  type = string
  validation {
    condition     = can(regex("^[a-z][a-z0-9-]{1,40}$", var.name))
    error_message = "Use a lowercase name, 2–41 characters."
  }
}
variable "region" {
  type    = string
  default = "us-east-1"
}
variable "image_uri" {
  type    = string
  default = null
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
}
variable "log_retention_days" {
  type    = number
  default = 30
}
variable "input_bucket" {
  type = string
}
variable "internal_bucket" {
  type = string
}
variable "input_prefix" {
  type    = string
  default = ""
}
variable "internal_prefix" {
  type    = string
  default = ""
}
variable "partner" {
  type = object({
    bucket   = string
    region   = string
    role_arn = optional(string)
    prefix   = optional(string, "")
  })
  default = null
}
variable "execution_kms_key_arns" {
  type    = list(string)
  default = []
}
variable "task_kms_key_arns" {
  type    = list(string)
  default = []
}
variable "target_db_url" {
  type    = string
  default = null
}
variable "db_url" {
  description = "JDBC URL containing the Aurora/PostgreSQL endpoint and TLS options only."
  type        = string
}
variable "db_secret_arn" {
  description = "Secret ARN with username and password JSON fields for the batch database user."
  type        = string
}
variable "subnet_ids" {
  type = list(string)
}
variable "security_group_ids" {
  type = list(string)
}
variable "input_region" {
  type    = string
  default = null
}
variable "internal_region" {
  type    = string
  default = null
}
variable "dynamo_table" {
  type = object({ name = string, arn = string })
}
variable "dynamo_operations_table" {
  type = object({ name = string, arn = string })
}
variable "dynamo_region" {
  type    = string
  default = null
}
variable "target_db_secret_arn" {
  type    = string
  default = null
}
