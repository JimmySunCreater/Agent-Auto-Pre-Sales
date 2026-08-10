#!/bin/bash
# =============================================================================
# Tank 500 Agent 全局配置 — 单一可配置来源 (Single Source of Truth)
#
# 其它脚本通过 `source 00-config.sh` 引入这些变量。
# 设计文档见 docs/design.md（§0 模型配置表）。
#
# 说明：
#   - TANK500_MODEL_ID   : Agent 本体模型（03-deploy.sh 创建 Harness 时使用）
#   - TANK500_JUDGE_MODEL: 评估器 LLM-as-judge 模型（07 注入到 evaluator Lambda
#                          的 ACC_MODEL / INTENT_MODEL / COMP_MODEL 环境变量）
#   - 二者默认相同；如需 judge 用更强模型，单独改 TANK500_JUDGE_MODEL 即可。
#
# 选型说明：默认用 Amazon Nova（us.amazon.nova-*），所有账户默认可用、
#   无需单独启用 model access。多语言（德/意）表现不足时，优化闭环的候选动作
#   之一是换 Nova Pro / Claude（需确保账户已启用对应 model access）。
# =============================================================================

# ---- 模型（可环境变量覆盖） ----
# Agent 本体默认 Claude Sonnet 5（多语言镜像稳定性显著优于 Nova 2 Lite，
# 代价是更高的 token 单价与延迟）。需要省钱跑通链路时可覆盖回 nova-2-lite。
export TANK500_MODEL_ID="${TANK500_MODEL_ID:-us.anthropic.claude-sonnet-5}"
# judge 固定 Nova 2 Lite（与历史评估基准保持一致——换 judge 会改变打分口径，
# 历史记分卡将失去可比性；如需升级 judge，请另起评估基线）
export TANK500_JUDGE_MODEL="${TANK500_JUDGE_MODEL:-us.amazon.nova-2-lite-v1:0}"
export TANK500_EMBED_MODEL="${TANK500_EMBED_MODEL:-amazon.titan-embed-text-v2:0}"

# ---- 命名（与 HR workshop 并存，互不干扰） ----
export TANK500_SSM_PREFIX="${TANK500_SSM_PREFIX:-/app/tank500}"
export TANK500_HARNESS_NAME="${TANK500_HARNESS_NAME:-tank500assistant}"
# 注意：这是 Gateway TARGET 名（决定工具前缀 tank500-tools___* 与 allowedTools）；
# Gateway 本体名是 tank500gateway（在 02/99 脚本中）
export TANK500_GATEWAY_NAME="${TANK500_GATEWAY_NAME:-tank500-tools}"
export TANK500_LAMBDA_NAME="${TANK500_LAMBDA_NAME:-tank500-tools-handler}"
export TANK500_KB_NAME="${TANK500_KB_NAME:-tank500-manual-kb}"

# ---- 基础设施（与 HR workshop 共用同一个 CFN 栈） ----
export INFRA_STACK_NAME="${INFRA_STACK_NAME:-workshop-infra}"

# ---- 手册源文件（01-create-kb.sh 会复制并校验存在性） ----
SCRIPT_DIR_CFG="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# 仓库已内置手册示例（knowledge-base/tank500-manual.md）；如需替换用 MANUAL_SOURCE 覆盖
export MANUAL_SOURCE="${MANUAL_SOURCE:-$SCRIPT_DIR_CFG/knowledge-base/tank500-manual.md}"

# ---- Tavily key 文件（02-create-gateway.sh 读取；优先级低于 TAVILY_API_KEY 环境变量） ----
export TAVILY_KEY_FILE="${TAVILY_KEY_FILE:-$SCRIPT_DIR_CFG/../tavilykey}"
