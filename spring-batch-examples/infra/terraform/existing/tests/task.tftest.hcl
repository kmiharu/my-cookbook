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
      repository_url = "111111111111.dkr.ecr.us-east-1.amazonaws.com/cookbook-batch"
      arn            = "arn:aws:ecr:us-east-1:111111111111:repository/cookbook-batch"
    }
  }
}

variables {
  name                    = "cookbook-batch"
  image_uri               = "111111111111.dkr.ecr.us-east-1.amazonaws.com/cookbook-batch@sha256:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  db_url                  = "jdbc:postgresql://db.example:5432/batch?sslmode=verify-full&sslrootcert=/opt/batch/certs/rds-global-bundle.pem"
  db_secret_arn           = "arn:aws:secretsmanager:us-east-1:111111111111:secret:batch-aaaaaa"
  subnet_ids              = ["subnet-0123456789abcdef0", "subnet-0123456789abcdef1"]
  security_group_ids      = ["sg-0123456789abcdef0"]
  internal_bucket         = "cookbook-output"
  input_bucket            = "cookbook-input"
  input_prefix            = "incoming/"
  dynamo_table            = { name = "items", arn = "arn:aws:dynamodb:us-east-1:111111111111:table/items" }
  dynamo_operations_table = { name = "operations", arn = "arn:aws:dynamodb:us-east-1:111111111111:table/operations" }
}

run "existing_direct_recipient" {
  command = plan

  variables {
    partner = { bucket = "partner-output", region = "us-west-2", prefix = "receive/" }
  }

  assert {
    condition     = output.network.assignPublicIp == "DISABLED" && tolist(output.network.subnets) == var.subnet_ids && tolist(output.network.securityGroups) == var.security_group_ids
    error_message = "RunTask must receive the requested private networking configuration."
  }
  assert {
    condition = (
      module.task.task_environment.SPRING_PROFILES_ACTIVE == "ecs" &&
      module.task.task_environment.BATCH_DB_URL == var.db_url &&
      module.task.task_environment.BATCH_INPUT_BUCKET == var.input_bucket &&
      module.task.task_environment.BATCH_INPUT_PREFIX == var.input_prefix &&
      module.task.task_environment.BATCH_INTERNAL_BUCKET == var.internal_bucket &&
      module.task.task_environment.BATCH_PARTNER_BUCKET == var.partner.bucket &&
      module.task.task_environment.BATCH_PARTNER_REGION == var.partner.region &&
      module.task.task_environment.BATCH_PARTNER_PREFIX == var.partner.prefix &&
      module.task.task_environment.BATCH_DYNAMO_OPERATIONS_TABLE == var.dynamo_operations_table.name &&
      module.task.task_environment.BATCH_DYNAMO_TABLE == var.dynamo_table.name &&
      !contains(keys(module.task.task_environment), "BATCH_DB_PASSWORD") &&
      !contains(keys(module.task.task_environment), "AWS_ACCESS_KEY_ID")
    )
    error_message = "The ECS container must receive the external configuration and standard credential chain."
  }
  assert {
    condition = (
      one([for secret in module.task.secret_references : secret.valueFrom if secret.name == "BATCH_DB_USER"]) == "${var.db_secret_arn}:username::" &&
      one([for secret in module.task.secret_references : secret.valueFrom if secret.name == "BATCH_DB_PASSWORD"]) == "${var.db_secret_arn}:password::" &&
      strcontains(module.task.execution_policy, var.db_secret_arn) &&
      !strcontains(module.task.task_policy, "secretsmanager:GetSecretValue")
    )
    error_message = "DB credentials must be injected from the selected Secret by the execution role."
  }
  assert {
    condition     = strcontains(module.task.task_policy, "arn:aws:s3:::partner-output/*") && !strcontains(module.task.task_policy, "sts:AssumeRole")
    error_message = "Direct recipient access must allow the partner bucket with the task role."
  }
  assert {
    condition     = module.task.task_configuration.cpu == "1024" && module.task.task_configuration.memory == "4096" && module.task.task_configuration.architecture == "X86_64" && module.task.task_configuration.stop_timeout == 120 && module.task.task_configuration.network_mode == "awsvpc" && module.task.task_configuration.compatibilities == toset(["FARGATE"])
    error_message = "Task definition defaults must match the single-task Fargate runtime contract."
  }
}

run "existing_sts_recipient" {
  command = plan

  variables {
    partner = { bucket = "partner-output", region = "us-west-2", role_arn = "arn:aws:iam::222222222222:role/receive" }
  }

  assert {
    condition     = module.task.task_environment.BATCH_PARTNER_ROLE_ARN == var.partner.role_arn && strcontains(module.task.task_policy, var.partner.role_arn) && strcontains(module.task.task_policy, "sts:AssumeRole") && !strcontains(module.task.task_policy, "arn:aws:s3:::partner-output")
    error_message = "The task must access the partner bucket through the configured role only."
  }
}

run "creates_repository_before_first_image" {
  command = plan

  variables {
    image_uri = null
  }

  assert {
    condition     = output.task_definition == null && output.ecr_repository_url == "111111111111.dkr.ecr.us-east-1.amazonaws.com/cookbook-batch"
    error_message = "The ECR registry must exist before the first task definition is registered."
  }
}

run "separate_target_secret" {
  command = plan

  variables {
    target_db_url        = "jdbc:postgresql://target.example:5432/batch?sslmode=verify-full&sslrootcert=/opt/batch/certs/rds-global-bundle.pem"
    target_db_secret_arn = "arn:aws:secretsmanager:us-east-1:111111111111:secret:target-aaaaaa"
    dynamo_region        = "us-east-2"
  }

  assert {
    condition = (
      module.task.task_environment.BATCH_TARGET_DB_URL == var.target_db_url &&
      module.task.task_environment.BATCH_DYNAMO_REGION == var.dynamo_region &&
      one([for secret in module.task.secret_references : secret.valueFrom if secret.name == "BATCH_TARGET_DB_PASSWORD"]) == "${var.target_db_secret_arn}:password::" &&
      strcontains(module.task.execution_policy, var.target_db_secret_arn)
    )
    error_message = "The migration destination must use its own Secret and the selected DynamoDB region must reach the task."
  }
}
