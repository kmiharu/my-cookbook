terraform {
  required_version = "= 1.13.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "= 6.20.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "= 5.19.1"
    }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = { Project = var.name }
  }
}

provider "cloudflare" {}

data "aws_partition" "current" {}

data "aws_caller_identity" "current" {
  count = local.postgres ? 1 : 0
}
