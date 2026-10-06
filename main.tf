terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 5.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.4" }
  }
}

provider "aws" {
  region = var.aws_region
  default_tags {
    tags = {
      Project   = "ZeroTrust-LLM-Gateway"
      ManagedBy = "Terraform"
    }
  }
}

variable "aws_region" {
  type    = string
  default = "us-east-1"
}

# Fetch the current AWS Account ID dynamically
data "aws_caller_identity" "current" {}

# KMS Key with explicit policy allowing CloudWatch Logs service access
resource "aws_kms_key" "gateway_audit_key" {
  description             = "KMS Key for Zero-Trust LLM Gateway audit logs"
  deletion_window_in_days = 7
  enable_key_rotation     = true

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # 1. Root / Account Admin Access
      {
        Sid    = "EnableIAMUserPermissions"
        Effect = "Allow"
        Principal = {
          AWS = "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
        }
        Action   = "kms:*"
        Resource = "*"
      },
      # 2. Allow CloudWatch Logs service in this region to use the key
      {
        Sid    = "AllowCloudWatchLogs"
        Effect = "Allow"
        Principal = {
          Service = "logs.${var.aws_region}.amazonaws.com"
        }
        Action = [
          "kms:Encrypt*",
          "kms:Decrypt*",
          "kms:ReEncrypt*",
          "kms:GenerateDataKey*",
          "kms:Describe*"
        ]
        Resource = "*"
        Condition = {
          ArnLike = {
            "kms:EncryptionContext:aws:logs:arn" = "arn:aws:logs:${var.aws_region}:${data.aws_caller_identity.current.account_id}:log-group:*"
          }
        }
      }
    ]
  })
}

resource "aws_cloudwatch_log_group" "audit_logs" {
  name              = "/aws/llm-gateway/sanitized-audits"
  retention_in_days = 14
  kms_key_id        = aws_kms_key.gateway_audit_key.arn
}

resource "aws_dynamodb_table" "token_quotas" {
  name         = "llm-client-token-quotas"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ApiKeyId"

  attribute {
    name = "ApiKeyId"
    type = "S"
  }

  ttl {
    attribute_name = "TtlExpiry"
    enabled        = true
  }
}
