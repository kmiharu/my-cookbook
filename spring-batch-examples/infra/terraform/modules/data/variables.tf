variable "name" {
  type = string
}
variable "input_bucket" {
  type = string
}
variable "internal_bucket" {
  type = string
}
variable "deletion_protection" {
  type    = bool
  default = true
}
variable "force_destroy_buckets" {
  type    = bool
  default = false
}
variable "enable_operation_ttl" {
  type    = bool
  default = false
}
