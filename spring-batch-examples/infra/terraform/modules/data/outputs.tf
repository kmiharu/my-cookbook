output "input_bucket" {
  value = aws_s3_bucket.batch["input"].bucket
}
output "internal_bucket" {
  value = aws_s3_bucket.batch["internal"].bucket
}
output "s3_kms_key_arn" {
  value = aws_kms_key.s3.arn
}
output "dynamo_table" {
  value = { name = aws_dynamodb_table.business.name, arn = aws_dynamodb_table.business.arn }
}
output "dynamo_operations_table" {
  value = { name = aws_dynamodb_table.operations.name, arn = aws_dynamodb_table.operations.arn }
}
output "dynamo_schema" {
  value = {
    table   = { pk = aws_dynamodb_table.business.hash_key, sk = aws_dynamodb_table.business.range_key }
    gsi     = { (local.business_gsi.name) = { HASH = local.business_gsi.hash, RANGE = local.business_gsi.range } }
    ops     = aws_dynamodb_table.operations.hash_key
    ttl     = one(aws_dynamodb_table.operations.ttl).enabled
    billing = aws_dynamodb_table.business.billing_mode
  }
}
