output "endpoint_url" {
  value = "${aws_api_gateway_stage.dev.invoke_url}/chat"
}

output "api_key_value" {
  value     = aws_api_gateway_api_key.demo_key.value
  sensitive = true
}

output "api_key_id" {
  value = aws_api_gateway_api_key.demo_key.id
}
