resource "aws_acm_certificate" "api" {
  count             = local.has_domain ? 1 : 0
  domain_name       = var.domain_name
  validation_method = "DNS"

  lifecycle { create_before_destroy = true }
}

locals {
  validation_record = local.has_domain ? one(aws_acm_certificate.api[0].domain_validation_options) : null
}

resource "cloudflare_dns_record" "certificate" {
  count   = local.has_domain ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = trimsuffix(local.validation_record.resource_record_name, ".")
  type    = local.validation_record.resource_record_type
  content = trimsuffix(local.validation_record.resource_record_value, ".")
  ttl     = 300
  proxied = false
}

resource "aws_acm_certificate_validation" "api" {
  count                   = local.has_domain ? 1 : 0
  certificate_arn         = aws_acm_certificate.api[0].arn
  validation_record_fqdns = [cloudflare_dns_record.certificate[0].name]
}

resource "aws_apigatewayv2_domain_name" "http" {
  count       = local.has_domain && local.http_api ? 1 : 0
  domain_name = var.domain_name

  domain_name_configuration {
    certificate_arn = aws_acm_certificate_validation.api[0].certificate_arn
    endpoint_type   = "REGIONAL"
    security_policy = "TLS_1_2"
  }
}

resource "aws_apigatewayv2_api_mapping" "http" {
  count       = local.has_domain && local.http_api ? 1 : 0
  api_id      = aws_apigatewayv2_api.http[0].id
  domain_name = aws_apigatewayv2_domain_name.http[0].id
  stage       = aws_apigatewayv2_stage.default[0].id
}

resource "aws_api_gateway_domain_name" "rest" {
  count                    = local.has_domain && !local.http_api ? 1 : 0
  domain_name              = var.domain_name
  regional_certificate_arn = aws_acm_certificate_validation.api[0].certificate_arn
  security_policy          = "TLS_1_2"

  endpoint_configuration { types = ["REGIONAL"] }
}

resource "aws_api_gateway_base_path_mapping" "rest" {
  count       = local.has_domain && !local.http_api ? 1 : 0
  api_id      = aws_api_gateway_rest_api.rest[0].id
  domain_name = aws_api_gateway_domain_name.rest[0].domain_name
  stage_name  = aws_api_gateway_stage.rest[0].stage_name
}

resource "cloudflare_dns_record" "api" {
  count   = local.has_domain ? 1 : 0
  zone_id = var.cloudflare_zone_id
  name    = var.domain_name
  type    = "CNAME"
  content = local.http_api ? aws_apigatewayv2_domain_name.http[0].domain_name_configuration[0].target_domain_name : aws_api_gateway_domain_name.rest[0].regional_domain_name
  ttl     = 300
  proxied = false
}
