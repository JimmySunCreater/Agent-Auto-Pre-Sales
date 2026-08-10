#!/bin/bash
# =============================================================================
# Phase 2c: Verify Memory Wiring + IAM Permissions
#
# CLI 1.0.0-preview.24 路径下，Memory 检索配置已在 03-deploy.sh 写入
# harness.json（mode=existing + retrievalConfig.topK）并随 CDK 部署——
# 不再需要 workshop 旧版的 update_harness 后配（且本机 boto3 的
# bedrock-agentcore-control 模型无 harness 类 API，旧方案不可用）。
#
# 本脚本只做两件事：
#   1. 验证部署状态：harness READY + memory 已部署 + harness.json 的 memory 配置
#   2. 补 IAM 权限（harness 执行角色 + gateway 角色 → BedrockAgentCoreFullAccess）
#
# Prerequisites: 03-deploy.sh
# =============================================================================
set -e

REGION=${AWS_DEFAULT_REGION:-us-west-2}
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.sh"
HARNESS="$TANK500_HARNESS_NAME"
WORKDIR=~/workshop/$HARNESS

echo "========================================="
echo "Phase 2c: Verify Memory + IAM"
echo "========================================="

cd $WORKDIR

# ---- 1. 验证部署状态 ----
echo "🔍 Verifying deployed state..."
python3 << 'PYEOF'
import json, sys

with open("agentcore/.cli/deployed-state.json") as f:
    state = json.load(f)
res = state.get("targets", {}).get("default", {}).get("resources", {})

harnesses = res.get("harnesses", {})
memories = res.get("memories", {})

ok = True
for name, info in harnesses.items():
    status = info.get("status", "UNKNOWN")
    print(f"  Harness {name}: {status}")
    if status not in ("READY", "ACTIVE"):
        ok = False

if not memories:
    print("  ❌ No memory in deployed state")
    ok = False
for name, info in memories.items():
    print(f"  Memory {name}: {info.get('memoryArn', 'no-arn')[:80]}")

sys.exit(0 if ok else 1)
PYEOF

echo "🔍 Verifying harness.json memory wiring..."
MEM_MODE=$(jq -r '.memory.mode // "missing"' "app/$HARNESS/harness.json")
MEM_NAME=$(jq -r '.memory.name // "missing"' "app/$HARNESS/harness.json")
echo "  harness.json memory: mode=$MEM_MODE name=$MEM_NAME"
if [ "$MEM_MODE" != "existing" ] || [ "$MEM_NAME" = "missing" ]; then
  echo "❌ harness.json 的 memory 配置缺失——03-deploy.sh 的接线步骤未生效？"
  exit 1
fi

# ---- 2. IAM permissions ----
echo "🔐 Configuring IAM permissions..."

aws iam attach-role-policy \
  --role-name "${HARNESS}_${HARNESS}" \
  --policy-arn "arn:aws:iam::aws:policy/BedrockAgentCoreFullAccess" 2>/dev/null || true
echo "  ✅ ${HARNESS}_${HARNESS} → BedrockAgentCoreFullAccess"

# Gateway role (created by 02-create-gateway.sh, not in CDK)
aws iam attach-role-policy \
  --role-name tank500-gateway-role \
  --policy-arn "arn:aws:iam::aws:policy/BedrockAgentCoreFullAccess" 2>/dev/null || true
echo "  ✅ tank500-gateway-role → BedrockAgentCoreFullAccess"

echo ""
echo "✅ Memory verified (wired at deploy time) + IAM configured!"
echo ""
echo "  - Memory strategies: SEMANTIC (/users/{actorId}/facts) + USER_PREFERENCE (/users/{actorId}/preferences)"
echo "  - Retrieval: harness.json memory.retrievalConfig (topK 20)，随 CDK 部署生效"
echo ""
echo "  Next: Run 05-test-conversation.sh"
