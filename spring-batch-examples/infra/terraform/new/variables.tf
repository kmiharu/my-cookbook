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
variable "availability_zones" {
  description = "Two distinct zones in region."
  type        = list(string)
  default     = ["us-east-1a", "us-east-1b"]
}
variable "vpc_cidr" {
  type    = string
  default = "10.42.0.0/16"
}
variable "deletion_protection" {
  type    = bool
  default = true
}
variable "backup_retention_days" {
  type    = number
  default = 7
}
variable "skip_final_snapshot" {
  type    = bool
  default = false
}
variable "force_destroy_buckets" {
  type    = bool
  default = false
}
variable "enable_operation_ttl" {
  type    = bool
  default = false
}
variable "target_db_secret_arn" {
  type    = string
  default = null
}
