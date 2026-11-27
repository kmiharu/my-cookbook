locals {
  zone_numbers = { for i, az in var.availability_zones : az => i }
}

resource "aws_vpc" "batch" {
  cidr_block           = var.vpc_cidr
  enable_dns_hostnames = true
  enable_dns_support   = true
  tags                 = { Name = var.name }
}

resource "aws_subnet" "public" {
  for_each          = local.zone_numbers
  vpc_id            = aws_vpc.batch.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, each.value)
  tags              = { Name = "${var.name}-public-${each.key}" }
}

resource "aws_subnet" "private" {
  for_each          = local.zone_numbers
  vpc_id            = aws_vpc.batch.id
  availability_zone = each.key
  cidr_block        = cidrsubnet(var.vpc_cidr, 8, each.value + 10)
  tags              = { Name = "${var.name}-private-${each.key}" }
}

resource "aws_internet_gateway" "batch" {
  vpc_id = aws_vpc.batch.id
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.batch.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.batch.id
  }
}

resource "aws_route_table_association" "public" {
  for_each       = aws_subnet.public
  subnet_id      = each.value.id
  route_table_id = aws_route_table.public.id
}

resource "aws_eip" "nat" {
  domain = "vpc"
}

resource "aws_nat_gateway" "batch" {
  allocation_id = aws_eip.nat.id
  subnet_id     = aws_subnet.public[var.availability_zones[0]].id
  depends_on    = [aws_internet_gateway.batch]
}

resource "aws_route_table" "private" {
  vpc_id = aws_vpc.batch.id
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = aws_nat_gateway.batch.id
  }
}

resource "aws_route_table_association" "private" {
  for_each       = aws_subnet.private
  subnet_id      = each.value.id
  route_table_id = aws_route_table.private.id
}

resource "aws_security_group" "task" {
  name        = "${var.name}-task"
  description = "Batch ECS task"
  vpc_id      = aws_vpc.batch.id
}

resource "aws_security_group" "db" {
  name        = "${var.name}-aurora"
  description = "Aurora access from batch tasks"
  vpc_id      = aws_vpc.batch.id
}

resource "aws_vpc_security_group_egress_rule" "https" {
  security_group_id = aws_security_group.task.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  cidr_ipv4         = "0.0.0.0/0"
}

resource "aws_vpc_security_group_egress_rule" "postgres" {
  security_group_id            = aws_security_group.task.id
  referenced_security_group_id = aws_security_group.db.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_vpc_security_group_ingress_rule" "postgres" {
  security_group_id            = aws_security_group.db.id
  referenced_security_group_id = aws_security_group.task.id
  ip_protocol                  = "tcp"
  from_port                    = 5432
  to_port                      = 5432
}

resource "aws_db_subnet_group" "batch" {
  name       = var.name
  subnet_ids = [for subnet in aws_subnet.private : subnet.id]
}

resource "aws_rds_cluster_parameter_group" "batch" {
  name   = "${var.name}-pg16"
  family = "aurora-postgresql16"
  parameter {
    name  = "rds.force_ssl"
    value = "1"
  }
}

resource "aws_rds_cluster" "batch" {
  cluster_identifier              = var.name
  engine                          = "aurora-postgresql"
  engine_mode                     = "provisioned"
  engine_version                  = "16.15"
  database_name                   = "batch"
  master_username                 = "batch_admin"
  manage_master_user_password     = true
  storage_encrypted               = true
  backup_retention_period         = var.backup_retention_days
  deletion_protection             = var.deletion_protection
  skip_final_snapshot             = var.skip_final_snapshot
  final_snapshot_identifier       = var.skip_final_snapshot ? null : "${var.name}-final"
  db_subnet_group_name            = aws_db_subnet_group.batch.name
  vpc_security_group_ids          = [aws_security_group.db.id]
  db_cluster_parameter_group_name = aws_rds_cluster_parameter_group.batch.name
  serverlessv2_scaling_configuration {
    min_capacity = 0.5
    max_capacity = 4
  }
}

resource "aws_rds_cluster_instance" "writer" {
  identifier           = "${var.name}-writer"
  cluster_identifier   = aws_rds_cluster.batch.id
  instance_class       = "db.serverless"
  engine               = aws_rds_cluster.batch.engine
  engine_version       = aws_rds_cluster.batch.engine_version
  db_subnet_group_name = aws_db_subnet_group.batch.name
  publicly_accessible  = false
}
