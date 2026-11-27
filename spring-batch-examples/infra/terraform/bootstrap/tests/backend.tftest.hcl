mock_provider "aws" {
  override_during = plan
  mock_resource "aws_s3_bucket" {
    defaults = { arn = "arn:aws:s3:::example-cookbook-state" }
  }
}

run "locked_state_bucket" {
  command = plan

  variables {
    bucket_name = "example-cookbook-state"
  }

  assert {
    condition     = aws_s3_bucket.state.force_destroy == false && one(aws_s3_bucket_versioning.state.versioning_configuration).status == "Enabled" && aws_s3_bucket_public_access_block.state.block_public_policy
    error_message = "The state bucket must preserve version history and block public access."
  }
  assert {
    condition     = !strcontains(output.backend_operator_policy, "dynamodb") && strcontains(output.backend_operator_policy, "*.tfstate.tflock")
    error_message = "The backend principal must manage S3 lockfiles within the selected state prefix."
  }
}
