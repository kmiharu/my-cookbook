output "cluster" {
  value = aws_ecs_cluster.batch.name
}
output "task_definition" {
  value = try(aws_ecs_task_definition.batch[0].arn, null)
}
output "network" {
  value = {
    subnets        = var.subnet_ids
    securityGroups = var.security_group_ids
    assignPublicIp = "DISABLED"
  }
}
output "container_name" {
  value = local.container_name
}
output "image_uri" {
  value = var.image_uri
}
output "ecr_repository_url" {
  value = aws_ecr_repository.batch.repository_url
}
output "log_group" {
  value = aws_cloudwatch_log_group.batch.name
}
output "region" {
  value = var.region
}
output "task_role_arn" {
  value = aws_iam_role.task.arn
}
output "execution_role_arn" {
  value = aws_iam_role.execution.arn
}
output "task_environment" {
  value = local.environment
}
output "secret_references" {
  value = local.container_definitions[0].secrets
}
output "task_policy" {
  value = aws_iam_role_policy.task.policy
}
output "execution_policy" {
  value = aws_iam_role_policy.execution.policy
}
output "task_configuration" {
  value = var.image_uri == null ? null : {
    cpu             = aws_ecs_task_definition.batch[0].cpu
    memory          = aws_ecs_task_definition.batch[0].memory
    architecture    = one(aws_ecs_task_definition.batch[0].runtime_platform).cpu_architecture
    network_mode    = aws_ecs_task_definition.batch[0].network_mode
    compatibilities = aws_ecs_task_definition.batch[0].requires_compatibilities
    stop_timeout    = one(jsondecode(aws_ecs_task_definition.batch[0].container_definitions)).stopTimeout
  }
}
