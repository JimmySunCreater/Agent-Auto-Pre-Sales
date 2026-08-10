#!/bin/bash
# =============================================================================
# Cleanup: Destroy tank500-agent resources
#
# 删除顺序按依赖反向：
#   1. Harness + Runtime（DeleteHarness 级联删 Runtime，释放 VPC ENI）
#   1b. AgentCore CFN 栈（Memory + 三个自定义 evaluator + harness 角色）
#   2. 独立 Gateway + 角色（boto3 创建，不在 CFN 栈里）
#   3. Knowledge Base（KB + S3 Vectors + IAM + SSM）
#   4. 工具 Lambda + 角色 + SSM 参数（Tavily key 等）+ S3 leads/
#
# ⚠️ workshop-infra CFN 栈（VPC/S3/EC2）与 HR workshop 共用，本脚本【默认不删】。
#    确认不再需要时，用 HR workshop 的 99-cleanup.sh 删栈，或手动删除。
#
# 失败不中断：单项删除失败打印 ⚠️ 后继续。幂等，可重复运行。
# =============================================================================
# 注意：本脚本逐项失败继续，因此不使用 set -e。

REGION=${AWS_DEFAULT_REGION:-us-west-2}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.sh"
HARNESS="$TANK500_HARNESS_NAME"
GATEWAY_NAME="tank500gateway"
GW_ROLE_NAME="tank500-gateway-role"
FUNCTION_NAME="$TANK500_LAMBDA_NAME"
LAMBDA_ROLE_NAME="tank500-tools-lambda-role"

echo "========================================="
echo "Tank 500 Agent Cleanup"
echo "========================================="
echo "Region: $REGION"
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text 2>/dev/null)

# -----------------------------------------------------------------------------
# Step 1: Harness + Runtime（先删，释放 VPC ENI）
# -----------------------------------------------------------------------------
echo "🗑️  Step 1: Deleting AgentCore Harness + Runtime..."
for HID in $(aws bedrock-agentcore-control list-harnesses --region $REGION \
  --query "harnesses[?starts_with(harnessName,'$HARNESS')].harnessId" --output text 2>/dev/null); do
  aws bedrock-agentcore-control delete-harness --harness-id "$HID" --region $REGION >/dev/null 2>&1 && \
    echo "  ✅ delete-harness $HID submitted (cascades to Runtime)" || \
    echo "  ⚠️  delete-harness $HID failed (may already be gone)"
done
echo "  ⏳ Waiting for Harness/Runtime deletion..."
for i in $(seq 1 40); do
  HLEFT=$(aws bedrock-agentcore-control list-harnesses --region $REGION \
    --query "harnesses[?starts_with(harnessName,'$HARNESS')].harnessId" --output text 2>/dev/null)
  RLEFT=$(aws bedrock-agentcore-control list-agent-runtimes --region $REGION \
    --query "agentRuntimes[?starts_with(agentRuntimeName,'harness_$HARNESS')].agentRuntimeId" --output text 2>/dev/null)
  [ -z "$HLEFT" ] && [ -z "$RLEFT" ] && { echo "  ✅ Harness and Runtime deleted"; break; }
  sleep 15
done

# Step 1b 前置：删掉 07 脚本 out-of-band 挂到 evaluator 执行角色上的内联策略。
# CFN 删 Role 时不认识这条策略会 DeleteConflict → 栈 DELETE_FAILED。
echo "  🧹 Removing out-of-band inline policies from evaluator roles..."
for FN in ${HARNESS}-eval-tank500_accuracy ${HARNESS}-eval-tank500_intent ${HARNESS}-eval-tank500_compliance; do
  ROLE=$(aws lambda get-function-configuration --function-name "$FN" --region $REGION \
    --query Role --output text 2>/dev/null | sed 's/.*role\///')
  if [ -n "$ROLE" ] && [ "$ROLE" != "None" ]; then
    aws iam delete-role-policy --role-name "$ROLE" \
      --policy-name EvaluatorBedrockInvoke 2>/dev/null && \
      echo "    ✅ removed EvaluatorBedrockInvoke from $ROLE" || true
  fi
done

# Step 1b: AgentCore CFN 栈（Memory + evaluators + roles）
echo "  🗑️  Deleting AgentCore CFN stack (Memory, evaluators, roles)..."
if aws cloudformation describe-stacks --stack-name "AgentCore-$HARNESS-default" --region $REGION >/dev/null 2>&1; then
  aws cloudformation delete-stack --stack-name "AgentCore-$HARNESS-default" --region $REGION 2>/dev/null
  aws cloudformation wait stack-delete-complete \
    --stack-name "AgentCore-$HARNESS-default" --region $REGION 2>/dev/null && \
    echo "  ✅ AgentCore CFN stack deleted" || echo "  ⚠️  AgentCore stack deletion timed out, check console"
else
  echo "  ⚠️  AgentCore CFN stack not found (already deleted)"
fi

# 残留 evaluator 日志组会阻塞下次重部署
for FUNC in ${HARNESS}-eval-tank500_accuracy ${HARNESS}-eval-tank500_intent ${HARNESS}-eval-tank500_compliance; do
  aws logs delete-log-group --log-group-name "/aws/lambda/$FUNC" --region $REGION 2>/dev/null && \
    echo "  ✅ log group /aws/lambda/$FUNC deleted" || true
done

# -----------------------------------------------------------------------------
# Step 2: 独立 Gateway + 角色
# -----------------------------------------------------------------------------
echo ""
echo "🗑️  Step 2: Deleting standalone Gateway ($GATEWAY_NAME)..."
if [ -f "$SCRIPT_DIR/gateway/create_gateway.py" ]; then
  AWS_DEFAULT_REGION="$REGION" python3 "$SCRIPT_DIR/gateway/create_gateway.py" \
    delete --name "$GATEWAY_NAME" 2>&1 || echo "  ⚠️  Gateway delete failed (may already be gone)"
else
  echo "  ⚠️  gateway/create_gateway.py not found, skipping"
fi
for P in $(aws iam list-role-policies --role-name "$GW_ROLE_NAME" --query "PolicyNames[]" --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name "$GW_ROLE_NAME" --policy-name "$P" 2>/dev/null
done
for PA in $(aws iam list-attached-role-policies --role-name "$GW_ROLE_NAME" --query "AttachedPolicies[*].PolicyArn" --output text 2>/dev/null); do
  aws iam detach-role-policy --role-name "$GW_ROLE_NAME" --policy-arn "$PA" 2>/dev/null
done
aws iam delete-role --role-name "$GW_ROLE_NAME" 2>/dev/null && \
  echo "  ✅ Gateway role $GW_ROLE_NAME deleted" || echo "  ⚠️  Gateway role not found"

# -----------------------------------------------------------------------------
# Step 3: Knowledge Base（KB + S3 Vectors + IAM + SSM）
# -----------------------------------------------------------------------------
echo ""
echo "🗑️  Step 3: Deleting Knowledge Base (+ S3 Vectors + IAM + SSM)..."
if [ -f "$SCRIPT_DIR/knowledge-base/create_kb.py" ]; then
  AWS_DEFAULT_REGION="$REGION" python3 "$SCRIPT_DIR/knowledge-base/create_kb.py" \
    --mode delete 2>&1 || echo "  ⚠️  KB delete failed (may already be gone)"
else
  echo "  ⚠️  knowledge-base/create_kb.py not found, skipping"
fi

# -----------------------------------------------------------------------------
# Step 4: 工具 Lambda + 角色 + SSM 参数 + S3 leads/
# -----------------------------------------------------------------------------
echo ""
echo "🗑️  Step 4: Deleting tools Lambda, roles, SSM params, S3 leads..."
aws lambda delete-function --function-name "$FUNCTION_NAME" --region $REGION 2>/dev/null && \
  echo "  ✅ Lambda $FUNCTION_NAME deleted" || echo "  ⚠️  Lambda not found"

for P in $(aws iam list-role-policies --role-name "$LAMBDA_ROLE_NAME" --query "PolicyNames[]" --output text 2>/dev/null); do
  aws iam delete-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-name "$P" 2>/dev/null
done
for PA in $(aws iam list-attached-role-policies --role-name "$LAMBDA_ROLE_NAME" --query "AttachedPolicies[*].PolicyArn" --output text 2>/dev/null); do
  aws iam detach-role-policy --role-name "$LAMBDA_ROLE_NAME" --policy-arn "$PA" 2>/dev/null
done
aws iam delete-role --role-name "$LAMBDA_ROLE_NAME" 2>/dev/null && \
  echo "  ✅ Lambda role $LAMBDA_ROLE_NAME deleted" || echo "  ⚠️  Lambda role not found"

for PARAM in "$TANK500_SSM_PREFIX/gateway_arn" "$TANK500_SSM_PREFIX/tavily_api_key" "$TANK500_SSM_PREFIX/knowledge_base_id"; do
  aws ssm delete-parameter --name "$PARAM" --region $REGION 2>/dev/null && \
    echo "  ✅ SSM $PARAM deleted" || true
done

# leads/ 前缀（数据桶属于共用 infra 栈，只清对象不删桶）
DATA_BUCKET=$(aws cloudformation describe-stacks --stack-name "$INFRA_STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='DataBucketName' || OutputKey=='SkillsBucketName'].OutputValue | [0]" \
  --output text --region $REGION 2>/dev/null)
if [ -n "$DATA_BUCKET" ] && [ "$DATA_BUCKET" != "None" ]; then
  aws s3 rm "s3://$DATA_BUCKET/leads/" --recursive --region $REGION 2>/dev/null && \
    echo "  ✅ s3://$DATA_BUCKET/leads/ emptied" || true
  aws s3 rm "s3://$DATA_BUCKET/tank500/" --recursive --region $REGION 2>/dev/null && \
    echo "  ✅ s3://$DATA_BUCKET/tank500/ (KB docs) emptied" || true
fi

# 本地项目目录
rm -rf ~/workshop/$HARNESS 2>/dev/null && echo "  ✅ ~/workshop/$HARNESS removed" || true

echo ""
echo "========================================="
echo "✅ Tank 500 agent cleanup complete."
echo ""
echo "⚠️  workshop-infra CFN 栈（VPC/NAT/S3/EC2）与 HR workshop 共用，本脚本未删除。"
echo "    NAT 网关按小时计费——若两个 demo 都不再需要，请运行 HR workshop 的"
echo "    99-cleanup.sh 删除该栈，或在 CloudFormation 控制台手动删除。"
echo ""
echo "⚠️  CloudWatch Transaction Search（X-Ray → CloudWatchLogs，100% 采样）是账户级"
echo "    配置，与 HR workshop 共用，本脚本未回滚。若确认不再需要："
echo "    aws xray update-trace-segment-destination --destination XRay --region $REGION"
echo "========================================="
