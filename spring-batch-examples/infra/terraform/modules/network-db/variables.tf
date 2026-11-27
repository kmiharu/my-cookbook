variable "name" {
  type = string
}
variable "availability_zones" {
  type = list(string)
  validation {
    condition     = length(var.availability_zones) == 2 && length(distinct(var.availability_zones)) == 2
    error_message = "Provide two distinct availability zones in the AWS provider region."
  }
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
