#!/bin/bash
# =============================================================================
# Phase 0b: Create Bedrock Knowledge Base (Tank 500 手册 RAG)
# Run AFTER 00-deploy-infra.sh, BEFORE 02-create-gateway.sh
#
# 两步，全部交给 knowledge-base/ 下的 Python 脚本完成：
#   1. split_manual.py —— 把用户手册按七大章节 + 大小切分成 KB 文档
#                         （输出到 knowledge-base/output/）
#   2. create_kb.py    —— 创建 KB（S3 Vectors + IAM）并灌库；
#                         KB ID 写入 SSM /app/tank500/knowledge_base_id
#
# 数据桶取自 workshop-infra CFN 栈的 DataBucketName 输出（与 HR workshop 共用桶，
# 但文档放在 tank500/ 前缀下，互不干扰）。
# =============================================================================
set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/00-config.sh"

REGION=${AWS_DEFAULT_REGION:-us-west-2}
export AWS_DEFAULT_REGION="$REGION"   # create_kb.py 通过 boto3 session 读取 region
KB_DIR="$SCRIPT_DIR/knowledge-base"
MANUAL_LOCAL="$KB_DIR/tank500-manual.md"

echo "========================================="
echo "Phase 0b: Create Bedrock Knowledge Base"
echo "========================================="
echo "  Region: $REGION"
echo "  Manual source: $MANUAL_SOURCE"

# -----------------------------------------------------------------------------
# 0. 手册就位校验 + 复制
# -----------------------------------------------------------------------------
if [ ! -f "$MANUAL_LOCAL" ]; then
  [ -f "$MANUAL_SOURCE" ] || { echo "❌ 手册源文件不存在: $MANUAL_SOURCE（用 MANUAL_SOURCE 环境变量指定）"; exit 1; }
  cp "$MANUAL_SOURCE" "$MANUAL_LOCAL"
  echo "  已复制手册到 $MANUAL_LOCAL"
else
  echo "  使用已存在的 $MANUAL_LOCAL"
fi

# -----------------------------------------------------------------------------
# 1. 依赖
# -----------------------------------------------------------------------------
echo ""
echo "📦 Installing Python dependencies..."
python3 -m pip install --user --quiet --break-system-packages boto3 botocore retrying 2>/dev/null || \
  python3 -m pip install --user --quiet boto3 botocore retrying 2>/dev/null || true

# -----------------------------------------------------------------------------
# 2. 切分手册（输出到 knowledge-base/output/，幂等：先清空旧输出）
# -----------------------------------------------------------------------------
echo ""
echo "📝 Splitting manual into KB documents..."
python3 "$KB_DIR/split_manual.py" "$MANUAL_LOCAL" "$KB_DIR/output"

# -----------------------------------------------------------------------------
# 3. 创建 KB 并灌库（S3 Vectors + IAM 角色 + ingestion）
# -----------------------------------------------------------------------------
echo ""
echo "🧠 Creating Bedrock Knowledge Base + ingesting documents..."
python3 "$KB_DIR/create_kb.py" --mode create

echo ""
echo "  Next: 02-create-gateway.sh（部署工具 Lambda + Gateway，需要 Tavily key）"
