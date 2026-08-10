#!/bin/bash
# =============================================================================
# Phase 0a: Deploy Infrastructure (CloudFormation)
# Run AFTER 00-setup.sh, BEFORE 01-create-kb.sh
#
# 与 HR workshop 共用同一个 workshop-infra 栈（VPC + 私有子网 + NAT + 安全组、
# Data S3 桶 + Access Point、EC2 工作环境）。如果你已经跑过 HR workshop，
# 本脚本会检测到栈已存在并直接跳过——这是刻意的复用设计（docs/design.md §1.2）。
#
# 模板直接引用 workshop 仓库的 cfn/workshop-infra.yaml，不复制副本。
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/00-config.sh"

REGION=${AWS_DEFAULT_REGION:-us-west-2}
STACK_NAME=${INFRA_STACK_NAME:-workshop-infra}

# 模板查找顺序：本工程 cfn/ → 同级的 workshop 仓库 cfn/
if [ -f "$SCRIPT_DIR/cfn/workshop-infra.yaml" ]; then
  TEMPLATE="$SCRIPT_DIR/cfn/workshop-infra.yaml"
else
  TEMPLATE="$SCRIPT_DIR/../sample-eval-first-building-enterprise-agents-with-agentcore-main/cfn/workshop-infra.yaml"
fi

echo "========================================="
echo "Phase 0a: Deploy Infrastructure"
echo "========================================="
echo "  Region: $REGION | Stack: $STACK_NAME"
echo "  Template: $TEMPLATE"

[ -f "$TEMPLATE" ] || { echo "❌ 模板不存在: $TEMPLATE（请确认 workshop 仓库在同级目录）"; exit 1; }

# 已存在则跳过（与 HR workshop 共用）
if aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" >/dev/null 2>&1; then
  echo "  栈已存在，跳过创建（与 HR workshop 共用）。"
else
  # AgentCore supported AZ IDs (from official docs)
  echo "  🔍 Resolving AgentCore-compatible availability zones..."
  case "$REGION" in
    us-east-1) SUPPORTED_AZ_IDS="use1-az1 use1-az2" ;;
    us-east-2) SUPPORTED_AZ_IDS="use2-az1 use2-az2" ;;
    us-west-2) SUPPORTED_AZ_IDS="usw2-az1 usw2-az2" ;;
    *) echo "❌ Unknown region $REGION — update supported AZ list in this script"; exit 1 ;;
  esac

  AZ_ID_1=$(echo "$SUPPORTED_AZ_IDS" | awk '{print $1}')
  AZ_ID_2=$(echo "$SUPPORTED_AZ_IDS" | awk '{print $2}')

  AZ1=$(aws ec2 describe-availability-zones --region "$REGION" \
    --query "AvailabilityZones[?ZoneId=='$AZ_ID_1'].ZoneName | [0]" --output text)
  AZ2=$(aws ec2 describe-availability-zones --region "$REGION" \
    --query "AvailabilityZones[?ZoneId=='$AZ_ID_2'].ZoneName | [0]" --output text)

  if [ -z "$AZ1" ] || [ "$AZ1" = "None" ] || [ -z "$AZ2" ] || [ "$AZ2" = "None" ]; then
    echo "❌ Could not resolve AZ names for IDs: $AZ_ID_1, $AZ_ID_2"
    exit 1
  fi
  echo "  AZ1=$AZ1 ($AZ_ID_1)  AZ2=$AZ2 ($AZ_ID_2)"

  echo "🚀 Creating stack (VPC/NAT/S3/EC2, ~5-8 min)..."
  aws cloudformation create-stack --region "$REGION" \
    --stack-name "$STACK_NAME" \
    --template-body "file://$TEMPLATE" \
    --parameters "ParameterKey=AZ1,ParameterValue=$AZ1" "ParameterKey=AZ2,ParameterValue=$AZ2" \
    --capabilities CAPABILITY_NAMED_IAM >/dev/null
  echo "  ⏳ Waiting for stack create complete..."
  aws cloudformation wait stack-create-complete --region "$REGION" --stack-name "$STACK_NAME"
fi

echo ""
echo "✅ Infrastructure ready. Stack outputs:"
aws cloudformation describe-stacks --region "$REGION" --stack-name "$STACK_NAME" \
  --query 'Stacks[0].Outputs[].{Key:OutputKey,Value:OutputValue}' --output table

echo ""
echo "  Next: 01-create-kb.sh（切分手册 + 建知识库）"
