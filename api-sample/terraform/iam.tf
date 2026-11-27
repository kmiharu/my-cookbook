locals {
  secret_policy_statements = concat(
    local.postgres ? [{
      Effect   = "Allow"
      Action   = ["secretsmanager:GetSecretValue"]
      Resource = var.pg_secret_arn
    }] : [],
    local.postgres && var.pg_secret_kms_key_arn != null ? [{
      Effect   = "Allow"
      Action   = ["kms:Decrypt"]
      Resource = var.pg_secret_kms_key_arn
      Condition = {
        StringEquals = {
          "kms:ViaService"                  = "secretsmanager.${var.aws_region}.${data.aws_partition.current.dns_suffix}"
          "kms:EncryptionContext:SecretARN" = var.pg_secret_arn
        }
      }
    }] : []
  )
}

resource "aws_iam_role" "function" {
  for_each = local.functions
  name     = each.value
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "lambda.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "function" {
  for_each = local.functions
  name     = "runtime"
  role     = aws_iam_role.function[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = concat(
      [{
        Effect   = "Allow"
        Action   = ["logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "${aws_cloudwatch_log_group.function[each.key].arn}:log-stream:*"
      }],
      local.postgres ? [{
        Effect = "Allow"
        Action = [
          "ec2:CreateNetworkInterface", "ec2:DescribeNetworkInterfaces", "ec2:DescribeSubnets",
          "ec2:DeleteNetworkInterface", "ec2:AssignPrivateIpAddresses", "ec2:UnassignPrivateIpAddresses"
        ]
        Resource = "*"
      }] : [],
      local.secret_policy_statements,
      local.dynamodb && each.key == "api" ? [{
        Effect   = "Allow"
        Action   = ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:ConditionCheckItem"]
        Resource = aws_dynamodb_table.products[0].arn
      }] : [],
      local.list_gsis && each.key == "api" ? [{
        Effect = "Allow"
        Action = ["dynamodb:Query"]
        Resource = concat(
          [aws_dynamodb_table.products[0].arn],
          [for index in keys(local.list_indexes) : "${aws_dynamodb_table.products[0].arn}/index/${index}"]
        )
      }] : [],
      each.key == "sync" ? [{
        Effect = "Allow"
        Action = [
          "dynamodb:DescribeStream", "dynamodb:GetRecords", "dynamodb:GetShardIterator"
        ]
        Resource = "${aws_dynamodb_table.products[0].arn}/stream/*"
      }] : [],
      each.key == "sync" ? [{
        Effect    = "Allow"
        Action    = ["dynamodb:ListStreams"]
        Resource  = "*"
        Condition = { StringEquals = { "aws:RequestedRegion" = var.aws_region } }
      }] : [],
      each.key == "sync" ? [
        for target in [
          { Action = "s3:ListBucket", Resource = aws_s3_bucket.sync_failures[0].arn },
          { Action = "s3:PutObject", Resource = "${aws_s3_bucket.sync_failures[0].arn}/*" }
          ] : {
          Effect    = "Allow"
          Action    = [target.Action]
          Resource  = target.Resource
          Condition = { StringEquals = { "s3:ResourceAccount" = data.aws_caller_identity.current[0].account_id } }
        }
      ] : []
    )
  })
}

resource "aws_iam_role" "proxy" {
  count = local.proxy ? 1 : 0
  name  = "${var.name}-proxy"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action    = "sts:AssumeRole"
      Effect    = "Allow"
      Principal = { Service = "rds.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "proxy" {
  count = local.proxy ? 1 : 0
  name  = "database-secret"
  role  = aws_iam_role.proxy[0].id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = local.secret_policy_statements
  })
}
