import json
import os
import re
import time
import boto3

bedrock = boto3.client("bedrock-runtime", region_name="us-east-1")
dynamodb = boto3.resource("dynamodb")
table = dynamodb.Table(os.environ["DYNAMODB_TABLE"])

REGEX_PATTERNS = {
    "SSN": r"\b(?!000|666|9\d{2})\d{3}-(?!00)\d{2}-(?!0000)\d{4}\b",
    "CREDIT_CARD": r"\b(?:4[0-9]{12}(?:[0-9]{3})?|5[1-5][0-9]{14}|3[47][0-9]{13})\b",
    "EMAIL": r"\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Z|a-z]{2,7}\b",
    "AWS_KEY": r"\b(AKIA|ASIA)[0-9A-Z]{16}\b"
}

DAILY_TOKEN_LIMIT = 5000

def sanitize_text(text: str) -> tuple[str, list]:
    redacted = text
    matches = []
    for pii_type, pattern in REGEX_PATTERNS.items():
        if re.search(pattern, redacted):
            matches.append(pii_type)
            redacted = re.sub(pattern, f"[REDACTED_{pii_type}]", redacted)
    return redacted, matches

def check_and_increment_tokens(api_key: str, tokens: int) -> bool:
    ttl_epoch = int(time.time()) + 86400
    try:
        res = table.update_item(
            Key={"ApiKeyId": api_key},
            UpdateExpression="SET TokensUsed = if_not_exists(TokensUsed, :zero) + :incr, TtlExpiry = if_not_exists(TtlExpiry, :ttl)",
            ExpressionAttributeValues={":zero": 0, ":incr": tokens, ":ttl": ttl_epoch},
            ReturnValues="UPDATED_NEW"
        )
        return res["Attributes"]["TokensUsed"] <= DAILY_TOKEN_LIMIT
    except Exception as e:
        print(f"DynamoDB check warning: {e}")
        return True

def handler(event, context):
    api_key = event.get("requestContext", {}).get("identity", {}).get("apiKeyId", "anonymous-client")
    
    try:
        body = json.loads(event.get("body", "{}"))
        prompt = body.get("prompt", "")
    except Exception:
        return {"statusCode": 400, "body": json.dumps({"error": "Malformed JSON payload"})}

    if not prompt:
        return {"statusCode": 400, "body": json.dumps({"error": "Prompt field cannot be empty"})}

    # 1. PII Redaction
    sanitized_prompt, detected_pii = sanitize_text(prompt)

    # 2. FinOps Quota Enforcement
    estimated_tokens = max(1, len(sanitized_prompt) // 4)
    if not check_and_increment_tokens(api_key, estimated_tokens):
        return {
            "statusCode": 429,
            "body": json.dumps({"error": "Daily token budget exceeded. FinOps guardrail active."})
        }

    # 3. Amazon Nova Micro Payload
    payload = {
        "messages": [
            {
                "role": "user",
                "content": [{"text": sanitized_prompt}]
            }
        ],
        "inferenceConfig": {
            "max_new_tokens": 300,
            "temperature": 0.7
        }
    }

    try:
        response = bedrock.invoke_model(
            modelId="us.amazon.nova-micro-v1:0",
            body=json.dumps(payload),
            contentType="application/json",
            accept="application/json"
        )
        response_body = json.loads(response["body"].read())
        llm_reply = response_body["output"]["message"]["content"][0]["text"]
    except Exception as e:
        return {"statusCode": 502, "body": json.dumps({"error": f"Inference engine failure: {str(e)}"})}

    return {
        "statusCode": 200,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps({
            "response": llm_reply,
            "pii_redacted": detected_pii,
            "tokens_consumed_estimate": estimated_tokens
        })
    }
