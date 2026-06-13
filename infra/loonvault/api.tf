# ── API Gateway v2 HTTP API ───────────────────────────────────────────────────
resource "aws_apigatewayv2_api" "main" {
  name          = local.name_prefix
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = ["*"]
    allow_methods = ["GET"]
    allow_headers = ["Content-Type"]
    max_age       = 300
  }
}

# Access log group (G-09)
resource "aws_cloudwatch_log_group" "api_access" {
  #checkov:skip=CKV_AWS_338:30-day retention for portfolio POC
  name              = "/loonvault/api-access"
  retention_in_days = 30
  kms_key_id        = aws_kms_key.main.arn
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_access.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      sourceIp       = "$context.identity.sourceIp"
      routeKey       = "$context.routeKey"
      status         = "$context.status"
      protocol       = "$context.protocol"
      responseLength = "$context.responseLength"
      authorizerError = "$context.authorizer.error"
    })
  }

  default_route_settings {
    throttling_burst_limit = 50
    throttling_rate_limit  = 20
  }
}

# ── Lambda authorizer ─────────────────────────────────────────────────────────
resource "aws_apigatewayv2_authorizer" "origin_secret" {
  api_id                            = aws_apigatewayv2_api.main.id
  authorizer_type                   = "REQUEST"
  authorizer_uri                    = aws_lambda_function.authorizer.invoke_arn
  identity_sources                  = ["$request.header.x-origin-secret"]
  name                              = "origin-secret"
  authorizer_payload_format_version = "2.0"
  enable_simple_responses           = true

  # 5-minute authorizer result cache (matches in-memory SSM cache in handler)
  authorizer_result_ttl_in_seconds = 300
}

resource "aws_lambda_permission" "authorizer_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.authorizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

# ── Route and integration ─────────────────────────────────────────────────────
resource "aws_apigatewayv2_integration" "read" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.read.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "get_series" {
  api_id             = aws_apigatewayv2_api.main.id
  route_key          = "GET /series/{code}"
  target             = "integrations/${aws_apigatewayv2_integration.read.id}"
  authorization_type = "CUSTOM"
  authorizer_id      = aws_apigatewayv2_authorizer.origin_secret.id
}

resource "aws_lambda_permission" "read_apigw" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.read.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
