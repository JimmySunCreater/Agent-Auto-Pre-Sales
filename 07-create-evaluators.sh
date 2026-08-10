#!/bin/bash
# =============================================================================
# Phase 4a: Create Custom Evaluators（三指标）
#
# 注册并部署三个自定义 code-based evaluator（均为 TRACE 级）：
#   - tank500_accuracy    : 回答准确率 value=min(GR,RQC)，Pass≥0.7，目标 ≥90%
#   - tank500_intent      : 意图识别率 judge 分类 + 代码行为匹配，目标 ≥80%
#   - tank500_compliance  : 合规拦截率 红线判定 + 拒答双重检查，目标 ≥95%
#
# 继承 HR workshop 踩过的三个 CLI 坑的 workaround：
#   1. `agentcore add evaluator` 注册时会用 scaffold 覆盖源码 → 注册后整目录还原
#   2. evaluator 代码更新后 deploy 需清 .cache 才会重建
#   3. evaluator 执行角色默认无 Bedrock 权限 → 部署后手动补
# =============================================================================
set -e

REGION=${AWS_DEFAULT_REGION:-us-west-2}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
SRC_DIR="$SCRIPT_DIR/evaluators"

source "$SCRIPT_DIR/00-config.sh"
HARNESS="$TANK500_HARNESS_NAME"
WORKDIR=~/workshop/$HARNESS

echo "========================================="
echo "Phase 4a: Create Custom Evaluators"
echo "========================================="

cd $WORKDIR

# -----------------------------------------------------------------------------
# 把 evaluator 源码放到项目下（codeLocation 相对 ~/workshop/tank500assistant）
# -----------------------------------------------------------------------------
mkdir -p evaluators
for ev in accuracy_eval intent_eval compliance_eval; do
  cp -r "$SRC_DIR/$ev" evaluators/
done
echo "📁 Evaluator source copied to $WORKDIR/evaluators/"

# -----------------------------------------------------------------------------
# 注册 + 还原代码（规避 CLI scaffold 覆盖）
# -----------------------------------------------------------------------------
register_evaluator() {
  local name="$1" level="$2" srcdir="$3" codeloc="$4"
  echo ""
  echo "🔧 Registering evaluator: $name ($level)"

  cat > /tmp/${name}-config.json <<JSON
{
  "codeBased": {
    "managed": {
      "codeLocation": "$codeloc",
      "entrypoint": "lambda_function.handler",
      "timeoutSeconds": 600
    }
  }
}
JSON

  local out
  out=$(npx agentcore add evaluator --name "$name" --level "$level" \
    --type code-based --config /tmp/${name}-config.json --json 2>&1 | tail -1)
  if echo "$out" | grep -q '"success":true'; then
    echo "  registered (new)"
  elif echo "$out" | grep -qi "already exists"; then
    echo "  already registered (will redeploy latest code)"
  else
    echo "  $out"
  fi

  # CLI scaffold 会重建 codeLocation 目录，丢掉 shared/ 等子模块 → 整目录还原
  rm -rf "evaluators/$srcdir"
  cp -r "$SRC_DIR/$srcdir" evaluators/
  echo "  ✅ $name source ready (full tree restored)"
}

register_evaluator "tank500_accuracy"   "TRACE" "accuracy_eval"   "evaluators/accuracy_eval"
register_evaluator "tank500_intent"     "TRACE" "intent_eval"     "evaluators/intent_eval"
register_evaluator "tank500_compliance" "TRACE" "compliance_eval" "evaluators/compliance_eval"

EVAL_LAMBDAS="${HARNESS}-eval-tank500_accuracy ${HARNESS}-eval-tank500_intent ${HARNESS}-eval-tank500_compliance"

# -----------------------------------------------------------------------------
# 部署（清缓存 + 预删残留日志组 + 显式失败检测）
# -----------------------------------------------------------------------------
echo ""
echo "🚀 Deploying evaluators (clearing build cache first)..."
rm -rf agentcore/.cache/tank500_accuracy agentcore/.cache/tank500_intent \
       agentcore/.cache/tank500_compliance 2>/dev/null || true

echo "  🧹 清理可能残留的 evaluator 日志组（避免 CDK LogGroup AlreadyExists）..."
for FN in $EVAL_LAMBDAS; do
  aws logs delete-log-group --log-group-name "/aws/lambda/$FN" --region $REGION 2>/dev/null \
    && echo "    removed stale log group /aws/lambda/$FN" || true
done

set +e
npx agentcore deploy --yes 2>&1 | tee /tmp/tank500-eval-deploy.log | tail -5
DEPLOY_RC=${PIPESTATUS[0]}
set -e
if [ "$DEPLOY_RC" -ne 0 ] || grep -qiE '\[ERROR\]|DeploymentError|FAILED' /tmp/tank500-eval-deploy.log; then
  echo ""
  echo "❌ 评估器部署失败（见上）。常见原因：残留日志组 / 上次部署回滚未清。"
  echo "   排查：tail -40 \$(ls -t agentcore/.cli/logs/deploy/*.log | head -1)"
  echo "   多数情况重跑本脚本即可（已自动预删日志组）。"
  exit 1
fi

# -----------------------------------------------------------------------------
# 补 Bedrock 权限到 evaluator 执行角色（LLM-judge 必需）
# -----------------------------------------------------------------------------
echo ""
echo "🔐 Granting Bedrock permissions to evaluator roles..."
cat > /tmp/eval-bedrock-policy.json <<JSON
{
  "Version": "2012-10-17",
  "Statement": [{
    "Effect": "Allow",
    "Action": ["bedrock:InvokeModel", "bedrock:InvokeModelWithResponseStream"],
    "Resource": [
      "arn:aws:bedrock:*::foundation-model/*",
      "arn:aws:bedrock:*:${ACCOUNT_ID}:inference-profile/*"
    ]
  }]
}
JSON

for FN in $EVAL_LAMBDAS; do
  ROLE=$(aws lambda get-function-configuration --function-name "$FN" --region $REGION \
    --query Role --output text 2>/dev/null | sed 's/.*role\///')
  if [ -n "$ROLE" ]; then
    aws iam put-role-policy --role-name "$ROLE" \
      --policy-name EvaluatorBedrockInvoke \
      --policy-document file:///tmp/eval-bedrock-policy.json 2>/dev/null && \
      echo "  ✅ $FN → $ROLE"
  fi
done

# -----------------------------------------------------------------------------
# 注入 judge 模型环境变量（由 00-config.sh 的 TANK500_JUDGE_MODEL 统一控制）
# -----------------------------------------------------------------------------
echo ""
echo "🧠 Setting judge model on evaluator Lambdas ($TANK500_JUDGE_MODEL)..."
aws lambda update-function-configuration \
  --function-name "${HARNESS}-eval-tank500_accuracy" --region $REGION \
  --environment "Variables={ACC_MODEL=$TANK500_JUDGE_MODEL,ACC_EMBED_MODEL=$TANK500_EMBED_MODEL}" >/dev/null 2>&1 && \
  echo "  ✅ tank500_accuracy ACC_MODEL=$TANK500_JUDGE_MODEL" || \
  echo "  ⚠️  failed to set ACC_MODEL (lambda will fall back to its default)"
aws lambda update-function-configuration \
  --function-name "${HARNESS}-eval-tank500_intent" --region $REGION \
  --environment "Variables={INTENT_MODEL=$TANK500_JUDGE_MODEL}" >/dev/null 2>&1 && \
  echo "  ✅ tank500_intent INTENT_MODEL=$TANK500_JUDGE_MODEL" || \
  echo "  ⚠️  failed to set INTENT_MODEL"
aws lambda update-function-configuration \
  --function-name "${HARNESS}-eval-tank500_compliance" --region $REGION \
  --environment "Variables={COMP_MODEL=$TANK500_JUDGE_MODEL}" >/dev/null 2>&1 && \
  echo "  ✅ tank500_compliance COMP_MODEL=$TANK500_JUDGE_MODEL" || \
  echo "  ⚠️  failed to set COMP_MODEL"

echo ""
echo "✅ Evaluators created and deployed"
echo "  - tank500_accuracy    (TRACE)  回答准确率 ≥90%"
echo "  - tank500_intent      (TRACE)  意图识别率 ≥80%"
echo "  - tank500_compliance  (TRACE)  合规拦截率 ≥95%"
echo "  Next: Run 08-run-eval.sh (48 题批量评估)"
