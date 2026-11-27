module "network_db" {
  source = "../modules/network-db"

  name                  = var.name
  availability_zones    = var.availability_zones
  vpc_cidr              = var.vpc_cidr
  deletion_protection   = var.deletion_protection
  backup_retention_days = var.backup_retention_days
  skip_final_snapshot   = var.skip_final_snapshot
}

module "data" {
  source = "../modules/data"

  name                  = var.name
  input_bucket          = var.input_bucket
  internal_bucket       = var.internal_bucket
  deletion_protection   = var.deletion_protection
  force_destroy_buckets = var.force_destroy_buckets
  enable_operation_ttl  = var.enable_operation_ttl
}

resource "aws_secretsmanager_secret" "batch_user" {
  name                    = "${var.name}/postgres/batch-user"
  recovery_window_in_days = 30
}

module "task" {
  source = "../modules/task"

  name                    = var.name
  region                  = var.region
  image_uri               = var.image_uri
  cpu                     = var.cpu
  memory                  = var.memory
  architecture            = var.architecture
  log_retention_days      = var.log_retention_days
  db_url                  = "jdbc:postgresql://${module.network_db.db_endpoint}:5432/batch?sslmode=verify-full&sslrootcert=/opt/batch/certs/rds-global-bundle.pem"
  db_secret_arn           = aws_secretsmanager_secret.batch_user.arn
  target_db_secret_arn    = var.target_db_secret_arn
  target_db_url           = var.target_db_url
  execution_kms_key_arns  = var.execution_kms_key_arns
  task_kms_key_arns       = concat([module.data.s3_kms_key_arn], var.task_kms_key_arns)
  subnet_ids              = module.network_db.private_subnet_ids
  security_group_ids      = [module.network_db.task_security_group_id]
  input_bucket            = module.data.input_bucket
  input_prefix            = var.input_prefix
  internal_bucket         = module.data.internal_bucket
  internal_prefix         = var.internal_prefix
  partner                 = var.partner
  dynamo_table            = module.data.dynamo_table
  dynamo_operations_table = module.data.dynamo_operations_table
}
