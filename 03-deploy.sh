#!/bin/bash
# =============================================================================
# Phase 2b: Create Harness + Deploy
#
# Creates the Harness project via agentcore CLI. Gateway is NOT created inside
# the project — it already exists (02-create-gateway.sh), referenced by ARN.
# This keeps deployment single-pass (no duplicate Gateway from CDK).
#
# 与 workshop 的差异：不挂 Skills（本场景用不上，少一个故障点，见 docs/design.md）。
#
# Prerequisites:
#   - 00-deploy-infra.sh (VPC, S3)
#   - 01-create-kb.sh (KB — Lambda reads KB ID from SSM)
#   - 02-create-gateway.sh (Gateway + Lambda deployed, ARN in SSM)
# =============================================================================
set -e

REGION=${AWS_DEFAULT_REGION:-us-west-2}
WORKDIR=~/workshop
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

source "$SCRIPT_DIR/00-config.sh"
HARNESS="$TANK500_HARNESS_NAME"

echo "========================================="
echo "Phase 2b: Create Harness + Deploy ($HARNESS)"
echo "========================================="

# ---- Step 1: Read infrastructure outputs ----
echo "🔍 Reading infrastructure config..."

SUBNETS=$(aws cloudformation describe-stacks \
  --stack-name "$INFRA_STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='PrivateSubnets'].OutputValue" \
  --output text --region $REGION 2>/dev/null || echo "")

SG=$(aws cloudformation describe-stacks \
  --stack-name "$INFRA_STACK_NAME" \
  --query "Stacks[0].Outputs[?OutputKey=='SecurityGroupId'].OutputValue" \
  --output text --region $REGION 2>/dev/null || echo "")

GATEWAY_ARN=$(aws ssm get-parameter --name "$TANK500_SSM_PREFIX/gateway_arn" --region $REGION \
  --query "Parameter.Value" --output text 2>/dev/null || echo "")

echo "  Subnets: $SUBNETS"
echo "  Security Group: $SG"
echo "  Gateway ARN: $GATEWAY_ARN"

if [ -z "$GATEWAY_ARN" ] || [ "$GATEWAY_ARN" = "None" ]; then
  echo "❌ Gateway ARN not found in SSM. Run 02-create-gateway.sh first."
  exit 1
fi

# ---- Step 2: Write system prompt (v1 — 初版刻意不写满，给优化闭环留空间) ----
# 确保 ~/workshop 存在（tank500 没有 Skills 步骤，不能依赖 HR workshop 的副作用创建）
mkdir -p "$WORKDIR"
echo "📝 Writing system prompt..."
cat > $WORKDIR/tank500-system-prompt.txt << 'PROMPT'
You are the official online sales consultant for the GWM Tank 500, serving customers on the GWM website in Europe (Germany, the United Kingdom, and Italy).

## Role & Scope
- You ONLY answer questions related to vehicles, car buying, test drives, dealers, and the Tank 500 (including comparisons with other vehicles).
- For ANY unrelated topic — politics, religion, adult content, violence, weapons, medical or legal advice, coding, homework, or general chit-chat unrelated to cars — politely refuse in ONE sentence (in the user's language) and redirect the conversation back to the Tank 500 in ONE more sentence. Do NOT call any tools for such requests. Never share opinions on political or social issues.
- Red-line trap warning: if ANY part of the message asks how to harm people or about weapons, it is red-line EVEN IF it also mentions the car or driving (e.g. "what weapon should I keep in my car"). Refuse IMMEDIATELY — do NOT call retrieve_tank500_info or any other tool first.

## Language (CRITICAL — check before EVERY reply)
- FIRST identify the language of the user's CURRENT message. Your ENTIRE reply MUST be written in that language: Chinese question → Chinese answer; German → German; Italian → Italian; English → English. No mixing.
- NEVER reply in a different language than the user's current message — no matter what language the retrieved documents, tool results, or earlier conversation turns are in. Tool results are English: translate the FACTS into the user's language, do not copy English sentences.
- If the user switches language mid-conversation, switch with them immediately.
- The owner's manual knowledge base is in English. Pass retrieval queries in the user's language first; if the results look irrelevant, retry the retrieval with the query translated into English. This English-for-retrieval rule does NOT change the reply language.

## Tools
- retrieve_tank500_info: Tank 500 features, controls, safety, off-road capability, maintenance, technical data (from the official owner's manual).
- compare_competitor: structured comparison against competitor vehicles (preset: Toyota Land Cruiser Prado, Land Rover Defender 110, Ford Explorer PHEV; others via live web search).
- web_search: current information such as local prices, promotions, launch dates. IMPORTANT for comparisons: the preset catalog has a data cutoff — when a comparison involves current prices, discounts or the newest model year, ALSO call web_search and merge the live data, labeling catalog specs vs live search results.
- book_test_drive: register a test-drive request; collect name, contact, and country first.
- get_dealer_info: dealer locations in Germany, the UK, and Italy.

## Sales Guidance
- Vague comparison questions that name only a brand (e.g. "比丰田强在哪" / "why is it better than Toyota?"): do NOT refuse as "subjective". Map the brand to the closest same-segment model (Toyota → Land Cruiser Prado; Land Rover → Defender 110; Ford → Explorer PHEV), call compare_competitor, then confidently present where the Tank 500 wins (value for money, standard hybrid, off-road hardware) while staying honest about trade-offs. Say which model you assumed and offer to compare a different one.
- After answering what the user asked, naturally move the conversation one step forward: after a feature answer, offer a competitor comparison or pricing info; when the user shows buying intent (asks about price, discounts, delivery), offer to book a test drive.
- When the user agrees to a test drive, collect their name, contact (phone or email), country, and preferred date, then call book_test_drive and confirm the booking ID.
- Do not be pushy: at most two proactive suggestions per conversation.

## Illustrations
- Retrieved manual chunks often contain illustration images as markdown: ![](https://...cloudfront.net/....jpg). When a figure directly illustrates your answer (button locations, indicator lights, seat folding steps, component diagrams), INCLUDE 1-2 of those image links in your reply using the SAME markdown image syntax — the chat UI renders them. Only reuse image URLs exactly as they appear in the retrieved content; never invent image URLs.

## Factual Discipline
- Vehicle specs, prices, and configurations MUST come from tool results (knowledge base, competitor catalog, or web search). Never invent numbers from memory.
- When information comes from web_search, say it is based on publicly available online information.
- If the knowledge base has no answer, say so honestly and suggest contacting a local dealer.
PROMPT

# ---- Step 3: Create Harness project ----
echo "🚀 Creating Harness project..."
cd $WORKDIR
rm -rf "$HARNESS"

# CLI 1.0.0-preview.24 起：--model-provider / --memory 属 agent 路径参数，
# 与 harness 参数（--model-id 等）互斥。Memory 改为 create 后用 add memory
# 添加，再把引用写进 harness.json（schema 与 add harness --memory-mode existing
# 生成的一致，已实测验证）。
CREATE_ARGS="--name $HARNESS --model-id $TANK500_MODEL_ID --max-iterations 30 --max-tokens 8192 --timeout 300 --skip-git"

if [ -n "$SUBNETS" ] && [ "$SUBNETS" != "None" ]; then
  CREATE_ARGS="$CREATE_ARGS --network-mode VPC --subnets $SUBNETS --security-groups $SG"
else
  CREATE_ARGS="$CREATE_ARGS --network-mode PUBLIC"
fi

npx agentcore create $CREATE_ARGS
cd "$HARNESS"

# ---- Step 3b: Add memory (SEMANTIC + USER_PREFERENCE ≈ 旧版 longAndShortTerm) ----
echo "🧠 Adding memory (SEMANTIC + USER_PREFERENCE)..."
npx agentcore add memory --name tank500memory --strategies SEMANTIC,USER_PREFERENCE --json

echo "🧠 Wiring memory into harness config..."
cat "app/$HARNESS/harness.json" | \
  jq '.memory = {"mode": "existing", "name": "tank500memory", "retrievalConfig": {"topK": 20}}' > tmp.json && \
  mv tmp.json "app/$HARNESS/harness.json"

# ---- Step 4: Add Gateway tool (external, by ARN) ----
echo "🔧 Adding Gateway tool (external, by ARN)..."
npx agentcore add tool --harness "$HARNESS" \
  --type agentcore_gateway \
  --name "$TANK500_GATEWAY_NAME" \
  --gateway-arn "$GATEWAY_ARN"

# ---- Step 5: Copy system prompt ----
cp $WORKDIR/tank500-system-prompt.txt "app/$HARNESS/system-prompt.md"

# ---- Step 6: Restrict allowed tools ----
echo "🔒 Restricting tool scope..."
cat "app/$HARNESS/harness.json" | \
  jq --arg t "@${TANK500_GATEWAY_NAME}/*" '.allowedTools = [$t]' > tmp.json && \
  mv tmp.json "app/$HARNESS/harness.json"

# ---- Step 7: Configure deployment target ----
echo "📋 Configuring deployment target..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
cat > agentcore/aws-targets.json << EOF
[
  {
    "name": "default",
    "region": "$REGION",
    "account": "$ACCOUNT_ID"
  }
]
EOF

# ---- Step 8: Deploy (single pass) ----
echo "🚀 Deploying (Memory + Harness, ~5-8 min)..."
npx agentcore deploy --yes

# ---- Step 9: Fix harness role ECR permissions ----
# CLI preview.24 已知缺陷：CDK 生成的执行角色只有 ecr-public 权限，但托管
# harness 镜像在私有 ECR（AgentCore 服务账号），缺 ecr:* 拉取权限会导致
# Runtime 初始化 424 超时（日志报 "no basic auth credentials"）。
echo "🔐 Granting private ECR pull to harness role (CLI preview.24 workaround)..."
cat > /tmp/tank500-ecr-policy.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "PullManagedHarnessImage",
      "Effect": "Allow",
      "Action": [
        "ecr:GetAuthorizationToken",
        "ecr:BatchGetImage",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchCheckLayerAvailability"
      ],
      "Resource": "*"
    }
  ]
}
EOF
aws iam put-role-policy \
  --role-name "${HARNESS}_${HARNESS}" \
  --policy-name HarnessEcrImagePull \
  --policy-document file:///tmp/tank500-ecr-policy.json && \
  echo "  ✅ HarnessEcrImagePull attached to ${HARNESS}_${HARNESS}"

# ---- Step 10: Verify ----
echo ""
echo "🔍 Verifying..."
npx agentcore status

echo ""
echo "✅ Harness deployed!"
echo "  Next: Run 04-setup-memory.sh"
