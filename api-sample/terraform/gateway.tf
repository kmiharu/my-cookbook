locals {
  api_invoke_arn = var.enable_api_snapstart ? aws_lambda_alias.api[0].invoke_arn : aws_lambda_function.application["api"].invoke_arn
  api_execution_arn = local.http_api ? (
    aws_apigatewayv2_api.http[0].execution_arn
  ) : aws_api_gateway_rest_api.rest[0].execution_arn
}

resource "aws_apigatewayv2_api" "http" {
  count         = local.http_api ? 1 : 0
  name          = var.name
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "http" {
  count                  = local.http_api ? 1 : 0
  api_id                 = aws_apigatewayv2_api.http[0].id
  integration_type       = "AWS_PROXY"
  integration_uri        = local.api_invoke_arn
  integration_method     = "POST"
  payload_format_version = "2.0"
  timeout_milliseconds   = 29000
}

resource "aws_apigatewayv2_route" "products" {
  for_each  = local.http_api ? toset(["ANY /products", "ANY /products/{id}"]) : toset([])
  api_id    = aws_apigatewayv2_api.http[0].id
  route_key = each.key
  target    = "integrations/${aws_apigatewayv2_integration.http[0].id}"
}

resource "aws_cloudwatch_log_group" "http_access" {
  count             = local.http_api ? 1 : 0
  name              = "/aws/apigateway/${var.name}"
  retention_in_days = 14
}

resource "aws_apigatewayv2_stage" "default" {
  count       = local.http_api ? 1 : 0
  api_id      = aws_apigatewayv2_api.http[0].id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.http_access[0].arn
    format = jsonencode({
      requestId         = "$context.requestId"
      method            = "$context.httpMethod"
      route             = "$context.routeKey"
      status            = "$context.status"
      responseLatencyMs = "$context.responseLatency"
    })
  }
}

resource "aws_api_gateway_rest_api" "rest" {
  count = local.http_api ? 0 : 1
  name  = var.name

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  body = jsonencode({
    openapi = "3.0.1"
    info    = { title = var.name, version = "1.0.0" }
    paths = {
      for path in ["/products", "/products/{id}"] : path => {
        "x-amazon-apigateway-any-method" = {
          parameters = path == "/products/{id}" ? [{
            in = "path", name = "id", required = true, schema = { type = "string" }
          }] : []
          responses = { "200" = { description = "Lambda response" } }
          "x-amazon-apigateway-integration" = {
            type       = "aws_proxy"
            httpMethod = "POST"
            uri        = local.api_invoke_arn
          }
        }
      }
    }
  })
}

resource "aws_api_gateway_deployment" "rest" {
  count       = local.http_api ? 0 : 1
  rest_api_id = aws_api_gateway_rest_api.rest[0].id
  triggers    = { specification = sha1(aws_api_gateway_rest_api.rest[0].body) }

  lifecycle { create_before_destroy = true }
}

resource "aws_api_gateway_stage" "rest" {
  count         = local.http_api ? 0 : 1
  rest_api_id   = aws_api_gateway_rest_api.rest[0].id
  deployment_id = aws_api_gateway_deployment.rest[0].id
  stage_name    = "v1"
}

resource "aws_lambda_permission" "gateway" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.application["api"].function_name
  qualifier     = var.enable_api_snapstart ? aws_lambda_alias.api[0].name : null
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${local.api_execution_arn}/*/*/*"
}
