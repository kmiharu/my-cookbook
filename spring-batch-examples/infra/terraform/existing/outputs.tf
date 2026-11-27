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
