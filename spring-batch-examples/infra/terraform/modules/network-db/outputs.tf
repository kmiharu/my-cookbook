output "db_endpoint" {
  value = aws_rds_cluster.batch.endpoint
}
output "admin_secret_arn" {
  value = try(one(aws_rds_cluster.batch.master_user_secret).secret_arn, null)
}
output "private_subnet_ids" {
  value = [for subnet in aws_subnet.private : subnet.id]
}
output "task_security_group_id" {
  value = aws_security_group.task.id
}
output "db_security_group_id" {
  value = aws_security_group.db.id
}
output "configuration" {
  value = {
    engine              = aws_rds_cluster.batch.engine
    engine_mode         = aws_rds_cluster.batch.engine_mode
    engine_version      = aws_rds_cluster.batch.engine_version
    instance_class      = aws_rds_cluster_instance.writer.instance_class
    managed_secret      = aws_rds_cluster.batch.manage_master_user_password
    publicly_accessible = aws_rds_cluster_instance.writer.publicly_accessible
  }
}
