mock_provider "aws" {}

mock_provider "aws" {
  alias           = "recipient"
  override_during = plan
  mock_data "aws_iam_policy_document" {
    defaults = { json = "{\"Version\":\"2012-10-17\",\"Statement\":[]}" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::222222222222:role/receive" }
  }
}

variables {
  region               = "us-east-1"
  caller_task_role_arn = "arn:aws:iam::111111111111:role/cookbook-batch-task"
  bucket_arn           = "arn:aws:s3:::example-recipient"
  object_prefix        = "cookbook/"
  kms_key_arn          = "arn:aws:kms:us-east-1:222222222222:key/00000000-0000-0000-0000-000000000000"
}

run "direct_access_statements" {
  command = plan

  assert {
    condition     = output.assume_role_arn == null && output.bucket_policy_statements[0].Principal.AWS == var.caller_task_role_arn && contains(output.bucket_policy_statements[0].Resource, "${var.bucket_arn}/${var.object_prefix}*") && output.kms_policy_statement.Principal.AWS == var.caller_task_role_arn
    error_message = "Direct access must authorize the sender task role for the requested prefix and key."
  }
}

run "recipient_role" {
  command = plan

  variables {
    assume_role_name = "receive"
  }

  assert {
    condition     = output.trust_policy_principal == var.caller_task_role_arn && output.bucket_policy_statements[0].Principal.AWS == output.assume_role_arn
    error_message = "AssumeRole mode must authorize the recipient role to use the destination with the sender role as the trust principal."
  }
}
