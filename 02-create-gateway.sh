#!/bin/bash
# =============================================================================
# Phase 2: Deploy Tank 500 Tools Lambda + Create Gateway
#
# 1. Tavily API key → SSM SecureString /app/tank500/tavily_api_key
#    （优先用 TAVILY_API_KEY 环境变量；否则若参数不存在则交互式提示输入）
# 2. 部署 tank500-tools-handler Lambda（handler + competitors.json 打包），
#    IAM：基础执行 + Bedrock（KB retrieve）+ SSM 读参 + S3 写 leads/
# 3. 创建 Gateway + Lambda target（gateway/create_gateway.py, boto3）
#    Gateway ARN → SSM /app/tank500/gateway_arn
#
# 幂等：重复运行安全。`02-create-gateway.sh delete` 删除 Gateway（Lambda 与
# IAM 角色保留，重跑 create 会复用）。
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.sh"

REGION=${AWS_DEFAULT_REGION:-us-west-2}
WORKDIR=~/workshop/$TANK500_HARNESS_NAME

GATEWAY_NAME="tank500gateway"
TARGET_NAME="$TANK500_GATEWAY_NAME"          # tank500-tools → 工具前缀 tank500-tools___*
GW_ROLE_NAME="tank500-gateway-role"

FUNCTION_NAME="$TANK500_LAMBDA_NAME"          # tank500-tools-handler
LAMBDA_ROLE_NAME="tank500-tools-lambda-role"
KB_ID_SSM_PARAM="$TANK500_SSM_PREFIX/knowledge_base_id"
TAVILY_KEY_SSM_PARAM="$TANK500_SSM_PREFIX/tavily_api_key"

# -----------------------------------------------------------------------------
# Teardown short-circuit
# -----------------------------------------------------------------------------
if [ "${1:-}" = "delete" ] || [ "${1:-}" = "--delete" ]; then
  echo "========================================="
  echo "Phase 2: Delete Gateway"
  echo "========================================="
  export AWS_DEFAULT_REGION="$REGION"
  python3 -m pip install --user --quiet boto3 botocore 2>/dev/null || true
  python3 "$SCRIPT_DIR/gateway/create_gateway.py" delete --name "$GATEWAY_NAME"
  echo "  ✅ Gateway teardown complete"
  exit 0
fi

echo "========================================="
echo "Phase 2: Deploy Lambda + Create Gateway"
echo "========================================="

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# -----------------------------------------------------------------------------
# 0. Tavily API key → SSM SecureString
# -----------------------------------------------------------------------------
echo "🔑 Ensuring Tavily API key in SSM ($TAVILY_KEY_SSM_PARAM)..."
if [ -n "${TAVILY_API_KEY:-}" ]; then
  aws ssm put-parameter --name "$TAVILY_KEY_SSM_PARAM" --type SecureString \
    --value "$TAVILY_API_KEY" --overwrite --region "$REGION" >/dev/null
  echo "  已从 TAVILY_API_KEY 环境变量写入。"
elif aws ssm get-parameter --name "$TAVILY_KEY_SSM_PARAM" --region "$REGION" >/dev/null 2>&1; then
  echo "  参数已存在，跳过（如需更新：export TAVILY_API_KEY=... 后重跑本脚本）。"
elif [ -n "${TAVILY_KEY_FILE:-}" ] && [ -f "$TAVILY_KEY_FILE" ]; then
  # 从 key 文件读取（00-config.sh 的 TAVILY_KEY_FILE，去掉首尾空白/换行；不回显内容）
  KEY_FROM_FILE=$(tr -d '[:space:]' < "$TAVILY_KEY_FILE")
  [ -n "$KEY_FROM_FILE" ] || { echo "❌ key 文件为空: $TAVILY_KEY_FILE"; exit 1; }
  aws ssm put-parameter --name "$TAVILY_KEY_SSM_PARAM" --type SecureString \
    --value "$KEY_FROM_FILE" --overwrite --region "$REGION" >/dev/null
  unset KEY_FROM_FILE
  echo "  已从 key 文件写入: $TAVILY_KEY_FILE"
else
  echo -n "  请输入 Tavily API key（tvly-...）: "
  read -r -s TAVILY_INPUT
  echo ""
  [ -n "$TAVILY_INPUT" ] || { echo "❌ 未输入 key。也可以 export TAVILY_API_KEY=... 后重跑。"; exit 1; }
  aws ssm put-parameter --name "$TAVILY_KEY_SSM_PARAM" --type SecureString \
    --value "$TAVILY_INPUT" --overwrite --region "$REGION" >/dev/null
  unset TAVILY_INPUT
  echo "  已写入 SSM SecureString。"
fi

# -----------------------------------------------------------------------------
# 1. Resolve leads bucket (workshop-infra DataBucketName output)
# -----------------------------------------------------------------------------
echo "🪣 Resolving leads bucket from CFN stack '$INFRA_STACK_NAME'..."
# 栈输出兼容两种命名（本模板输出 SkillsBucketName，与 create_kb.py 的回退一致）
LEADS_BUCKET=$(aws cloudformation describe-stacks --stack-name "$INFRA_STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='DataBucketName' || OutputKey=='SkillsBucketName'].OutputValue | [0]" \
  --output text --region "$REGION" 2>/dev/null || echo "")
if [ -z "$LEADS_BUCKET" ] || [ "$LEADS_BUCKET" = "None" ]; then
  echo "  ⚠️  未取到 DataBucketName（workshop-infra 未部署？）。留资将只写日志不落 S3。"
  LEADS_BUCKET=""
else
  echo "  Leads bucket: $LEADS_BUCKET (prefix leads/)"
fi

# -----------------------------------------------------------------------------
# 2. Deploy the Tank 500 Tools Lambda
# -----------------------------------------------------------------------------
echo "📦 Deploying Tank 500 Tools Lambda ($FUNCTION_NAME)..."
LAMBDA_ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${LAMBDA_ROLE_NAME}"

echo "  🔐 Creating Lambda execution role..."
aws iam create-role \
  --role-name "$LAMBDA_ROLE_NAME" \
  --assume-role-policy-document '{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"lambda.amazonaws.com"},"Action":"sts:AssumeRole"}]}' \
  --region $REGION 2>/dev/null || echo "    Role already exists"

aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole 2>/dev/null || true
aws iam attach-role-policy --role-name "$LAMBDA_ROLE_NAME" \
  --policy-arn arn:aws:iam::aws:policy/AmazonBedrockFullAccess 2>/dev/null || true

# SSM 读参（KB ID + Tavily key，SecureString 用默认 aws/ssm 密钥，无需显式 kms:Decrypt）
# + S3 写 leads/ 前缀
LEADS_S3_STATEMENT=""
if [ -n "$LEADS_BUCKET" ]; then
  LEADS_S3_STATEMENT=",
      {
        \"Effect\": \"Allow\",
        \"Action\": \"s3:PutObject\",
        \"Resource\": \"arn:aws:s3:::${LEADS_BUCKET}/leads/*\"
      }"
fi
aws iam put-role-policy --role-name "$LAMBDA_ROLE_NAME" \
  --policy-name "tank500-tools-access" \
  --policy-document "{
    \"Version\": \"2012-10-17\",
    \"Statement\": [
      {
        \"Effect\": \"Allow\",
        \"Action\": \"ssm:GetParameter\",
        \"Resource\": [
          \"arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter${KB_ID_SSM_PARAM}\",
          \"arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter${TAVILY_KEY_SSM_PARAM}\"
        ]
      }${LEADS_S3_STATEMENT}
    ]
  }"

# Package: handler + competitors.json
echo "  📦 Packaging Lambda..."
( cd "$SCRIPT_DIR/lambda" && zip -j /tmp/tank500-tools-lambda.zip tank500_tools_handler.py competitors.json >/dev/null )

LAMBDA_ENV="Variables={KB_ID_SSM_PARAM=$KB_ID_SSM_PARAM,TAVILY_KEY_SSM_PARAM=$TAVILY_KEY_SSM_PARAM,LEADS_BUCKET=$LEADS_BUCKET}"

echo "  🚀 Deploying function code..."
if aws lambda get-function --function-name "$FUNCTION_NAME" --region $REGION >/dev/null 2>&1; then
  aws lambda update-function-code \
    --function-name "$FUNCTION_NAME" \
    --zip-file fileb:///tmp/tank500-tools-lambda.zip \
    --region $REGION > /dev/null
  aws lambda wait function-updated --function-name "$FUNCTION_NAME" --region $REGION
  aws lambda update-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --timeout 30 --memory-size 512 \
    --environment "$LAMBDA_ENV" \
    --region $REGION > /dev/null
  echo "    Updated existing function"
else
  sleep 10  # Wait for role propagation
  aws lambda create-function \
    --function-name "$FUNCTION_NAME" \
    --runtime python3.12 \
    --handler tank500_tools_handler.lambda_handler \
    --role "$LAMBDA_ROLE_ARN" \
    --zip-file fileb:///tmp/tank500-tools-lambda.zip \
    --timeout 30 \
    --memory-size 512 \
    --environment "$LAMBDA_ENV" \
    --region $REGION > /dev/null
  echo "    Created new function"
fi

# Allow AgentCore Gateway to invoke the function
echo "  🔗 Adding Gateway invoke permission..."
aws lambda add-permission \
  --function-name "$FUNCTION_NAME" \
  --statement-id agentcore-gateway-invoke \
  --action lambda:InvokeFunction \
  --principal bedrock-agentcore.amazonaws.com \
  --region $REGION 2>/dev/null || echo "    Permission already exists"

# Warn if the KB ID SSM parameter doesn't exist yet
if ! aws ssm get-parameter --name "$KB_ID_SSM_PARAM" --region $REGION >/dev/null 2>&1; then
  echo "  ⚠️  SSM 参数 $KB_ID_SSM_PARAM 不存在 —— retrieve_tank500_info 将无法检索。"
  echo "      请先运行 01-create-kb.sh。"
fi
echo "  ✅ Lambda deployed"

# -----------------------------------------------------------------------------
# 3. Resolve the Lambda ARN
# -----------------------------------------------------------------------------
TANK500_LAMBDA_ARN=$(aws lambda get-function \
  --function-name "$FUNCTION_NAME" --region $REGION \
  --query "Configuration.FunctionArn" --output text 2>/dev/null || echo "")
if [ -z "$TANK500_LAMBDA_ARN" ] || [ "$TANK500_LAMBDA_ARN" = "None" ]; then
  TANK500_LAMBDA_ARN="arn:aws:lambda:${REGION}:${ACCOUNT_ID}:function:${FUNCTION_NAME}"
fi
echo "  Lambda ARN: $TANK500_LAMBDA_ARN"

# -----------------------------------------------------------------------------
# 4. Create the Gateway IAM role + Gateway + Lambda target (boto3)
# -----------------------------------------------------------------------------
export AWS_DEFAULT_REGION="$REGION"

echo "📦 Ensuring Python dependencies (boto3)..."
python3 -m pip install --user --quiet boto3 botocore 2>/dev/null || true

echo "🚀 Creating Gateway IAM role + Gateway + Lambda target via boto3..."
python3 "$SCRIPT_DIR/gateway/create_gateway.py" create \
  --name "$GATEWAY_NAME" \
  --target-name "$TARGET_NAME" \
  --lambda-arn "$TANK500_LAMBDA_ARN" \
  --role-name "$GW_ROLE_NAME" \
  --schema-file "$SCRIPT_DIR/gateway/tank500-tools-schema.json"

# -----------------------------------------------------------------------------
# 5. Restrict the harness tool scope (if the harness already exists)
# -----------------------------------------------------------------------------
if [ -f "$WORKDIR/app/$TANK500_HARNESS_NAME/harness.json" ]; then
  echo "🔒 Restricting tool scope..."
  jq ".allowedTools = [\"@${TARGET_NAME}/*\"]" \
    "$WORKDIR/app/$TANK500_HARNESS_NAME/harness.json" > "$WORKDIR/tmp.json" \
    && mv "$WORKDIR/tmp.json" "$WORKDIR/app/$TANK500_HARNESS_NAME/harness.json"
fi

echo ""
echo "  Next: Run 03-deploy.sh（创建并部署 Harness）"
