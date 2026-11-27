resource "aws_vpc" "database" {
  count                = local.postgres ? 1 : 0
  cidr_block           = "10.40.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

resource "aws_subnet" "private" {
  count                = local.postgres ? 2 : 0
  vpc_id               = aws_vpc.database[0].id
  availability_zone_id = var.availability_zone_ids[count.index]
  cidr_block           = cidrsubnet(aws_vpc.database[0].cidr_block, 8, count.index)
}

resource "aws_route_table" "private" {
  count  = local.postgres ? 1 : 0
  vpc_id = aws_vpc.database[0].id
}

resource "aws_route_table_association" "private" {
  count          = local.postgres ? 2 : 0
  route_table_id = aws_route_table.private[0].id
  subnet_id      = aws_subnet.private[count.index].id
}

locals {
  database_clients = local.postgres ? merge(local.functions, { migration = "${var.name}-migration" }) : {}
  database_sources = merge(
    { for key, name in local.database_clients : key => name if key == "migration" || !local.proxy },
    local.proxy ? { proxy = "${var.name}-proxy" } : {}
  )
}

resource "aws_security_group" "client" {
  for_each    = local.database_clients
  name        = each.value
  description = "Private database client traffic for ${each.key}"
  vpc_id      = aws_vpc.database[0].id
}

resource "aws_security_group" "database" {
  count       = local.postgres ? 1 : 0
  name        = "${var.name}-database"
  description = "Aurora PostgreSQL ingress"
  vpc_id      = aws_vpc.database[0].id
}

resource "aws_security_group" "secrets" {
  count       = local.postgres ? 1 : 0
  name        = "${var.name}-secrets"
  description = "Secrets Manager VPC endpoint ingress"
  vpc_id      = aws_vpc.database[0].id
}

resource "aws_security_group" "proxy" {
  count       = local.proxy ? 1 : 0
  name        = "${var.name}-proxy"
  description = "RDS Proxy client and Aurora traffic"
  vpc_id      = aws_vpc.database[0].id
}

resource "aws_vpc_security_group_ingress_rule" "database" {
  for_each                     = local.database_sources
  security_group_id            = aws_security_group.database[0].id
  referenced_security_group_id = each.key == "proxy" ? aws_security_group.proxy[0].id : aws_security_group.client[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "database" {
  for_each                     = local.database_sources
  security_group_id            = each.key == "proxy" ? aws_security_group.proxy[0].id : aws_security_group.client[each.key].id
  referenced_security_group_id = aws_security_group.database[0].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "proxy" {
  for_each                     = local.proxy ? local.functions : {}
  security_group_id            = aws_security_group.proxy[0].id
  referenced_security_group_id = aws_security_group.client[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_egress_rule" "proxy" {
  for_each                     = local.proxy ? local.functions : {}
  security_group_id            = aws_security_group.client[each.key].id
  referenced_security_group_id = aws_security_group.proxy[0].id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "secrets" {
  for_each                     = local.database_clients
  security_group_id            = aws_security_group.secrets[0].id
  referenced_security_group_id = aws_security_group.client[each.key].id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_security_group_egress_rule" "secrets" {
  for_each                     = local.database_clients
  security_group_id            = aws_security_group.client[each.key].id
  referenced_security_group_id = aws_security_group.secrets[0].id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

resource "aws_vpc_endpoint" "secrets" {
  count               = local.postgres ? 1 : 0
  vpc_id              = aws_vpc.database[0].id
  service_name        = "com.amazonaws.${var.aws_region}.secretsmanager"
  vpc_endpoint_type   = "Interface"
  private_dns_enabled = true
  subnet_ids          = aws_subnet.private[*].id
  security_group_ids  = [aws_security_group.secrets[0].id]
}

resource "aws_vpc_endpoint" "dynamodb" {
  count             = local.hybrid ? 1 : 0
  vpc_id            = aws_vpc.database[0].id
  service_name      = "com.amazonaws.${var.aws_region}.dynamodb"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.private[0].id]
}

resource "aws_vpc_security_group_egress_rule" "dynamodb" {
  count             = local.hybrid ? 1 : 0
  security_group_id = aws_security_group.client["api"].id
  prefix_list_id    = aws_vpc_endpoint.dynamodb[0].prefix_list_id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

resource "aws_db_subnet_group" "database" {
  count      = local.postgres ? 1 : 0
  name       = "${var.name}-database"
  subnet_ids = aws_subnet.private[*].id
}

resource "aws_rds_cluster" "database" {
  count                       = local.postgres ? 1 : 0
  cluster_identifier          = var.name
  engine                      = "aurora-postgresql"
  engine_mode                 = "provisioned"
  engine_version              = var.aurora_engine_version
  database_name               = local.db_name
  master_username             = "cookbook_admin"
  manage_master_user_password = true
  db_subnet_group_name        = aws_db_subnet_group.database[0].name
  vpc_security_group_ids      = [aws_security_group.database[0].id]
  storage_encrypted           = true
  backup_retention_period     = 7
  copy_tags_to_snapshot       = true
  final_snapshot_identifier   = "${var.name}-final"

  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 2
  }
}

resource "aws_rds_cluster_instance" "writer" {
  count                      = local.postgres ? 1 : 0
  identifier                 = "${var.name}-writer"
  cluster_identifier         = aws_rds_cluster.database[0].id
  instance_class             = "db.serverless"
  engine                     = aws_rds_cluster.database[0].engine
  engine_version             = aws_rds_cluster.database[0].engine_version
  db_subnet_group_name       = aws_db_subnet_group.database[0].name
  publicly_accessible        = false
  auto_minor_version_upgrade = false
}

resource "aws_db_proxy" "database" {
  count                  = local.proxy ? 1 : 0
  name                   = var.name
  engine_family          = "POSTGRESQL"
  require_tls            = true
  role_arn               = aws_iam_role.proxy[0].arn
  vpc_subnet_ids         = aws_subnet.private[*].id
  vpc_security_group_ids = [aws_security_group.proxy[0].id]

  auth {
    auth_scheme               = "SECRETS"
    client_password_auth_type = "POSTGRES_SCRAM_SHA_256"
    iam_auth                  = "DISABLED"
    secret_arn                = var.pg_secret_arn
  }

  depends_on = [aws_iam_role_policy.proxy]
}

resource "aws_db_proxy_default_target_group" "database" {
  count         = local.proxy ? 1 : 0
  db_proxy_name = aws_db_proxy.database[0].name

  connection_pool_config {
    connection_borrow_timeout    = 10
    max_connections_percent      = 80
    max_idle_connections_percent = 40
  }
}

resource "aws_db_proxy_target" "writer" {
  count                 = local.proxy ? 1 : 0
  db_proxy_name         = aws_db_proxy.database[0].name
  target_group_name     = aws_db_proxy_default_target_group.database[0].name
  db_cluster_identifier = aws_rds_cluster.database[0].id

  depends_on = [aws_rds_cluster_instance.writer]
}
