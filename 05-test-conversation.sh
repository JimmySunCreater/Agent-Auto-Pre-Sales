#!/bin/bash
# =============================================================================
# Phase 3: Smoke-test Conversations（四语各一句 + Memory 演示）
#
# 用同一个 actor-id (demo-user-001) 跑 4 个独立 session：
#   1. 英语：混动系统提问（并透露偏好 → 写入 Memory）
#   2. 德语：越野能力
#   3. 意大利语：价格（走 web_search）
#   4. 中文：座椅布局
# 每次 invoke 都会产生 OTel trace（评估阶段读取）。
# 同一 actor 的偏好会被 Memory 抽取，下次会话自动注入——正好演示跨会话记忆。
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/00-config.sh"
WORKDIR=~/workshop/$TANK500_HARNESS_NAME
ACTOR="demo-user-001"

echo "========================================="
echo "Phase 3: Smoke-test Conversations"
echo "========================================="

cd $WORKDIR

new_session() {
  # 兼容 macOS（uuidgen）与 Linux（/proc）；注意不能接管道，否则退出码被 tr 吃掉、兜底失效
  local uuid
  uuid=$(uuidgen 2>/dev/null) || uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) || \
    uuid=$(python3 -c "import uuid; print(uuid.uuid4())")
  uuid=$(echo "$uuid" | tr 'A-Z' 'a-z')
  echo "session-${uuid}-$(date +%s)"
}

check_invoke() {
  # agentcore invoke 即使模型调用失败也返回 exit 0，显式检测错误输出
  if echo "$1" | grep -qiE "AccessDeniedException|Model access is denied|^Error:|aws-marketplace:Subscribe"; then
    echo ""
    echo "❌ Agent 对话失败。若提示 'Model access is denied'，请在 Bedrock 控制台"
    echo "   启用 00-config.sh 中 TANK500_MODEL_ID 对应的模型后重试。"
    exit 1
  fi
}

run_turn() {
  local label="$1" message="$2"
  local session
  session=$(new_session)
  echo ""
  echo "🗣️  [$label] session=$session"
  echo "    Q: $message"
  echo ""
  local out
  # </dev/null：防 stdin 劫持（nohup/后台运行时 CLI 等待 stdin 会挂死）
  out=$(npx agentcore invoke \
    --session-id "$session" \
    --actor-id "$ACTOR" \
    --stream \
    "$message" </dev/null 2>&1)
  echo "$out"
  check_invoke "$out"
}

run_turn "EN · 车型咨询 + 偏好写入" \
  "Hi! I'm interested in hybrid SUVs, my budget is around 65,000 EUR and I live in Munich. Can you tell me how the Tank 500's hybrid system works?"

run_turn "DE · 越野能力" \
  "Wie gut ist der Tank 500 im Gelände? Welche Wattiefe und Böschungswinkel hat er?"

run_turn "IT · 实时价格（web_search）" \
  "Quanto costa il Tank 500 in Italia? Ci sono promozioni al momento?"

run_turn "ZH · 座椅布局" \
  "Tank 500 是几座的？第三排空间怎么样？"

echo ""
echo "========================================="
echo "✅ Smoke test complete (actor: $ACTOR)"
echo ""
echo "提示：四个 session 共用同一个 actor-id。第 1 句透露的偏好（混动 / 预算 6.5 万欧 /"
echo "慕尼黑）会被 Memory 抽取；稍后再问 '根据我的预算推荐一下' 可验证跨会话记忆。"
echo ""
echo "  Next: Run 06-setup-eval-env.sh"
