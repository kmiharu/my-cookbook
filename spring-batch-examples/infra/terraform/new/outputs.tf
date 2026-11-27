output "region" {
  description = "AWS region passed to ECS and ECR CLI calls."
  value       = module.task.region
}
output "cluster" {
  description = "ECS cluster name for RunTask and DescribeTasks."
  value       = module.task.cluster
}
output "task_definition" {
  description = "Registered ECS task definition revision ARN. Null until image_uri is supplied."
  value       = module.task.task_definition
}
output "network" {
  description = "awsvpc configuration with private subnet and security group IDs."
  value       = module.task.network
}
output "container_name" {
  description = "Container selected for command override and exit status."
  value       = module.task.container_name
}
output "image_uri" {
  description = "Application image URI including immutable digest."
  value       = module.task.image_uri
}
output "ecr_repository_url" {
  description = "Repository URL for the build and push script."
  value       = module.task.ecr_repository_url
}
output "log_group" {
  description = "CloudWatch Logs group for job output."
  value       = module.task.log_group
}
output "task_role_arn" {
  description = "Application IAM role. Pass to the partner for bucket, KMS or role trust policies."
  value       = module.task.task_role_arn
}
output "execution_role_arn" {
  description = "ECS role for image pull, log delivery and secret injection."
  value       = module.task.execution_role_arn
}
output "db_endpoint" {
  description = "Private Aurora writer endpoint for administration and migration."
  value       = module.network_db.db_endpoint
}
output "admin_secret_arn" {
  description = "Aurora-managed admin Secret ARN for database setup."
  value       = module.network_db.admin_secret_arn
}
output "batch_secret_arn" {
  description = "Secret ARN whose values are provided outside Terraform after creating the batch database user."
  value       = aws_secretsmanager_secret.batch_user.arn
}
output "dynamo_schema" {
  description = "Table key attributes used to compare AWS definition with DynamoDB Local."
  value       = module.data.dynamo_schema
}
