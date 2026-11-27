mock_provider "aws" {
  override_during = plan
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_resource "aws_cloudwatch_log_group" {
    defaults = { arn = "arn:aws:logs:us-east-1:111111111111:log-group:/ecs/cookbook-batch" }
  }
  mock_resource "aws_ecr_repository" {
    defaults = {
      repository_url = "111111111111.dkr.ecr.us-east-1.amazonaws.com/cookbook-sandbox"
      arn            = "arn:aws:ecr:us-east-1:111111111111:repository/cookbook-sandbox"
    }
  }
  mock_resource "aws_rds_cluster" {
    defaults = { endpoint = "sandbox.cluster-example.us-east-1.rds.amazonaws.com" }
  }
  mock_resource "aws_secretsmanager_secret" {
    defaults = { arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:cookbook-sandbox/postgres/batch-user-aaaaaa" }
  }
  mock_resource "aws_kms_key" {
    defaults = { arn = "arn:aws:kms:us-east-1:111111111111:key/00000000-0000-0000-0000-000000000000" }
  }
  mock_resource "aws_dynamodb_table" {
    defaults = { arn = "arn:aws:dynamodb:us-east-1:111111111111:table/cookbook-sandbox" }
  }
}

variables {
  name            = "cookbook-sandbox"
  input_bucket    = "111111111111-cookbook-input-sandbox"
  internal_bucket = "111111111111-cookbook-output-sandbox"
  image_uri       = "111111111111.dkr.ecr.us-east-1.amazonaws.com/cookbook-sandbox@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
}

run "new_private_stack" {
  command = plan

  assert {
    condition = (
      module.network_db.configuration.engine == "aurora-postgresql" &&
      module.network_db.configuration.engine_mode == "provisioned" &&
      module.network_db.configuration.engine_version == "16.15" &&
      module.network_db.configuration.instance_class == "db.serverless" &&
      module.network_db.configuration.managed_secret &&
      !module.network_db.configuration.publicly_accessible
    )
    error_message = "The stack must configure a private Aurora PostgreSQL writer with a managed administrator secret."
  }
  assert {
    condition = (
      output.dynamo_schema.table.pk == "pk" &&
      output.dynamo_schema.table.sk == "sk" &&
      output.dynamo_schema.gsi["by-status"].HASH == "gsi_pk" &&
      output.dynamo_schema.gsi["by-status"].RANGE == "gsi_sk" &&
      output.dynamo_schema.ops == "operation_id" &&
      output.dynamo_schema.billing == "PAY_PER_REQUEST" &&
      !output.dynamo_schema.ttl
    )
    error_message = "The DynamoDB key layout and optional operation expiry must match the local schema contract."
  }
  assert {
    condition = (
      module.task.task_environment.BATCH_INPUT_BUCKET == var.input_bucket &&
      module.task.task_environment.BATCH_INTERNAL_BUCKET == var.internal_bucket &&
      module.task.task_environment.BATCH_DYNAMO_TABLE == "${var.name}-items" &&
      module.task.task_environment.BATCH_DYNAMO_OPERATIONS_TABLE == "${var.name}-operations" &&
      startswith(module.task.task_environment.BATCH_DB_URL, "jdbc:postgresql://${output.db_endpoint}:5432/batch?sslmode=verify-full") &&
      one([for secret in module.task.secret_references : secret.valueFrom if secret.name == "BATCH_DB_PASSWORD"]) == "${output.batch_secret_arn}:password::" &&
      strcontains(module.task.task_policy, module.data.s3_kms_key_arn)
    )
    error_message = "The Terraform-managed S3, DynamoDB, Aurora, KMS and secret values must flow into task settings."
  }
}
