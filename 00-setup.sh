#!/bin/bash
# =============================================================================
# Phase 0: Environment Setup
# 校验 CLI 工具链与手册源文件。
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/00-config.sh"

echo "========================================="
echo "Phase 0: Environment Setup (Tank 500 Agent)"
echo "========================================="

# Verify tools
echo "🔍 Verifying tools..."
npx agentcore --version || { echo "❌ agentcore CLI not found. Run: npm i -g @aws/agentcore@preview"; exit 1; }
node --version || { echo "❌ Node.js not found (need v20+)"; exit 1; }
aws --version || { echo "❌ AWS CLI not found"; exit 1; }
python3 --version || { echo "❌ Python 3 not found (need 3.10+)"; exit 1; }

REGION=${AWS_DEFAULT_REGION:-us-west-2}
echo "  Region: $REGION"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
echo "  Account: $ACCOUNT_ID"

# Verify manual source exists
if [ -f "$MANUAL_SOURCE" ]; then
  echo "  Manual: $MANUAL_SOURCE ($(wc -l < "$MANUAL_SOURCE" | tr -d ' ') lines)"
else
  echo "⚠️  手册源文件不存在: $MANUAL_SOURCE"
  echo "   请把 Tank 500 用户手册 md 放到该路径，或用 MANUAL_SOURCE 环境变量指定。"
  echo "   （01-create-kb.sh 之前必须就位）"
fi

echo ""
echo "  Model (agent): $TANK500_MODEL_ID"
echo "  Model (judge): $TANK500_JUDGE_MODEL"
echo "  Model (embed): $TANK500_EMBED_MODEL"
echo ""
echo "✅ Environment ready"
echo "  Next: Run 00-deploy-infra.sh"
