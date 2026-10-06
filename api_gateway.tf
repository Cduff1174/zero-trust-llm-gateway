resource "aws_api_gateway_rest_api" "llm_api" {
  name        = "zero-trust-llm-gateway"
  description = "Protected entry point for LLM inference"
}

resource "aws_api_gateway_resource" "chat_resource" {
  rest_api_id = aws_api_gateway_rest_api.llm_api.id
  parent_id   = aws_api_gateway_rest_api.llm_api.root_resource_id
  path_part   = "chat"
}

resource "aws_api_gateway_method" "post_chat" {
  rest_api_id      = aws_api_gateway_rest_api.llm_api.id
  resource_id      = aws_api_gateway_resource.chat_resource.id
  http_method      = "POST"
  authorization    = "NONE"
  api_key_required = true
}

resource "aws_api_gateway_integration" "lambda_integration" {
  rest_api_id             = aws_api_gateway_rest_api.llm_api.id
  resource_id             = aws_api_gateway_resource.chat_resource.id
  http_method             = aws_api_gateway_method.post_chat.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.dlp_proxy.invoke_arn
}

resource "aws_lambda_permission" "apigw_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.dlp_proxy.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.llm_api.execution_arn}/*/*"
}

resource "aws_api_gateway_deployment" "deployment" {
  depends_on  = [aws_api_gateway_integration.lambda_integration]
  rest_api_id = aws_api_gateway_rest_api.llm_api.id
}

resource "aws_api_gateway_stage" "dev" {
  deployment_id = aws_api_gateway_deployment.deployment.id
  rest_api_id   = aws_api_gateway_rest_api.llm_api.id
  stage_name    = "v1"
}

resource "aws_api_gateway_api_key" "demo_key" {
  name = "portfolio_demo_client_key"
}

resource "aws_api_gateway_usage_plan" "plan" {
  name = "llm-gateway-basic-plan"

  throttle_settings {
    burst_limit = 5
    rate_limit  = 2
  }

  quota_settings {
    limit  = 1000
    period = "DAY"
  }

  api_stages {
    api_id = aws_api_gateway_rest_api.llm_api.id
    stage  = aws_api_gateway_stage.dev.stage_name
  }
}

resource "aws_api_gateway_usage_plan_key" "main" {
  key_id        = aws_api_gateway_api_key.demo_key.id
  key_type      = "API_KEY"
  usage_plan_id = aws_api_gateway_usage_plan.plan.id
}
