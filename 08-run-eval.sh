#!/bin/bash
# =============================================================================
# Phase 4b: Golden-set Batch Evaluation（48 题 → 三指标记分卡）
#
# 流程（docs/design.md §4.4）：
#   A. 遍历 golden_questions.json，每题独立 session + 独立 actor-id
#      （actor-id = "eval-" + 题目 id，避免 Memory 跨题污染）；
#      多轮题在同一 session 内按 turns 顺序发送
#   B. 按 session.id 在 aws/spans 中发现 trace（不按工具 span grep——红线题
#      的期望行为恰恰是不调工具）；invoke 前时间戳做严格下界；轮询等索引
#   C. 按题型分流评估器：业务题跑 accuracy + intent；红线题跑 compliance + intent
#      （spans 索引最终一致，"No session spans found" 时 5×25s 重试）
#   D. 汇总三指标记分卡 + 意图混淆矩阵 + 每题明细
#      口径：分母固定为黄金集题数；评估器 Skipped / Error / 无 trace 一律计 Fail
#
# 用法:
#   ./08-run-eval.sh                     # 全量 48 题
#   ./08-run-eval.sh --subset redline    # 只跑某类别（逗号分隔多个）
#   ./08-run-eval.sh --subset vi-en-01,cp-de-02   # 只跑指定题目 id
#
# Prerequisites: 03-deploy.sh + 04-setup-memory.sh + 06-setup-eval-env.sh +
#                07-create-evaluators.sh（Transaction Search 必须已开启）
# =============================================================================
set -e

REGION=${AWS_DEFAULT_REGION:-us-west-2}
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/00-config.sh"
HARNESS="$TANK500_HARNESS_NAME"
WORKDIR=~/workshop/$HARNESS
GOLDEN="$SCRIPT_DIR/eval-dataset/golden_questions.json"

RUN_TS=$(date +%s)
SINCE_EPOCH_MS=$(( RUN_TS * 1000 ))          # 严格时间下界：只认本次运行产生的 trace
# 结果文件放工程目录（/tmp 会被系统清理/重启清空，长跑任务的状态不能放那里）
EVAL_OUT="$SCRIPT_DIR/eval-results"
mkdir -p "$EVAL_OUT"
SESSIONS_FILE="$EVAL_OUT/sessions.jsonl"
TRACES_FILE="$EVAL_OUT/traces.json"
RESULTS_FILE="$EVAL_OUT/results.jsonl"
export RESULTS_FILE
INDEX_WAIT_MAX="${INDEX_WAIT_MAX:-420}"      # 等 trace 索引的总超时（秒，可环境变量覆盖；
                                             # aws/spans 落库偶发大积压时可调大到 3600+）
INDEX_POLL=20

SUBSET=""
RESUME=""
if [ "${1:-}" = "--subset" ]; then
  SUBSET="${2:-}"
  [ -n "$SUBSET" ] || { echo "❌ --subset 需要参数（类别或题目 id，逗号分隔）"; exit 1; }
elif [ "${1:-}" = "--resume" ]; then
  # 恢复模式：跳过 Phase A，复用上一轮的 sessions 文件重新做 trace 发现 + 评估。
  # 适用场景：aws/spans 落库积压导致上一轮 Phase B 超时（对话本身已成功）。
  RESUME=1
  [ -s "$SESSIONS_FILE" ] || { echo "❌ --resume 需要上一轮的 $SESSIONS_FILE"; exit 1; }
  # 从 sid 后缀恢复上一轮的 RUN_TS（sid 格式 eval-<qid>-<uuid8>-<RUN_TS>）
  RUN_TS=$(head -1 "$SESSIONS_FILE" | jq -r '.sid' | awk -F- '{print $NF}')
  SINCE_EPOCH_MS=$(( RUN_TS * 1000 ))
  echo "  (--resume：复用上一轮 $(grep -c . "$SESSIONS_FILE") 个 session，RUN_TS=$RUN_TS)"
fi

[ -f "$GOLDEN" ] || { echo "❌ 评估集不存在: $GOLDEN"; exit 1; }
command -v jq >/dev/null || { echo "❌ 需要 jq（brew install jq / yum install jq）"; exit 1; }

echo "========================================="
echo "Phase 4b: Golden-set Batch Evaluation"
echo "========================================="

# ---- 解析 runtime / evaluator ARN ----
# Runtime ARN 优先从部署状态读（与 harness 一一对应），失败再回退 API 查询
RT_ARN=$(python3 -c "
import json
try:
    st = json.load(open('$WORKDIR/agentcore/.cli/deployed-state.json'))
    hs = st.get('targets', {}).get('default', {}).get('resources', {}).get('harnesses', {})
    for name, info in hs.items():
        if info.get('agentRuntimeArn'):
            print(info['agentRuntimeArn'])
            break
except Exception:
    pass
" 2>/dev/null)
if [ -z "$RT_ARN" ]; then
  RT_ARN=$(aws bedrock-agentcore-control list-agent-runtimes --region $REGION \
    --query "agentRuntimes[?contains(agentRuntimeName,'$HARNESS')].agentRuntimeArn | [0]" \
    --output text 2>/dev/null)
fi
[ -z "$RT_ARN" -o "$RT_ARN" = "None" ] && { echo "❌ 未找到 $HARNESS runtime，请先 03-deploy.sh"; exit 1; }

# evaluator ARN 从 CDK 部署状态读取（评估器是 CDK 资源，
# bedrock-agentcore-control 没有 list-evaluators API）
get_ev_arn() {
  python3 -c "
import json, sys
try:
    st = json.load(open('$WORKDIR/agentcore/.cli/deployed-state.json'))
    evs = st.get('targets', {}).get('default', {}).get('resources', {}).get('evaluators', {})
    for name, info in evs.items():
        if '$1' in name:
            print(info.get('evaluatorArn', ''))
            break
except Exception:
    pass
" 2>/dev/null
}
ACC_ARN=$(get_ev_arn "tank500_accuracy")
INT_ARN=$(get_ev_arn "tank500_intent")
COMP_ARN=$(get_ev_arn "tank500_compliance")
for pair in "tank500_accuracy|$ACC_ARN" "tank500_intent|$INT_ARN" "tank500_compliance|$COMP_ARN"; do
  [ -z "${pair#*|}" -o "${pair#*|}" = "None" ] && { echo "❌ 评估器 ${pair%%|*} 未注册，请先 07-create-evaluators.sh"; exit 1; }
done
echo "  Runtime: $RT_ARN"
echo "  Evaluators: accuracy / intent / compliance ✓"

new_session() {
  # 不接管道取退出码（tr 会吃掉 uuidgen 的失败），兜底 /proc → python3
  local uuid
  uuid=$(uuidgen 2>/dev/null) || uuid=$(cat /proc/sys/kernel/random/uuid 2>/dev/null) || \
    uuid=$(python3 -c "import uuid; print(uuid.uuid4())")
  uuid=$(echo "$uuid" | tr 'A-Z' 'a-z')
  echo "eval-$1-${uuid:0:8}-$RUN_TS"
}

# 清洗 invoke 输出：去噪音行、截掉页脚（Session:/To resume:/Log:），
# 留下 Agent 真实回复（供结果明细与 eval-ui 展示）
clean_response() {
  python3 -c "
import sys, re
noise = re.compile(r'PythonDeprecationWarning|warnings\.warn|boto3 will no longer|upgrade to Python|More information can')
out = []
for l in sys.stdin:
    if l.startswith(('Session:', 'To resume:', 'Log:')):
        break
    if noise.search(l):
        continue
    out.append(l)
print(''.join(out).strip()[:4000])
"
}

# ---- 选题（--subset 过滤；--resume 跳过） ----
if [ -z "$RESUME" ]; then
QUESTIONS=$(jq -c --arg subset "$SUBSET" '
  .questions[]
  | select(
      ($subset == "")
      or ([.category] | inside($subset | split(",")))
      or ([.id] | inside($subset | split(",")))
    )' "$GOLDEN")
N_TOTAL=$(echo "$QUESTIONS" | grep -c . || true)
[ "$N_TOTAL" -gt 0 ] || { echo "❌ subset '$SUBSET' 没有匹配到任何题目"; exit 1; }
echo "  题数: $N_TOTAL $([ -n "$SUBSET" ] && echo "(subset: $SUBSET —— 记分卡分母为子集题数，达标线仅对全量有意义)")"

# =============================================================================
# Phase A — 逐题对话（独立 session + 独立 actor）
# =============================================================================
echo ""
echo "═══ Phase A: 运行 $N_TOTAL 个对话 ═══"
: > "$SESSIONS_FILE"
cd "$WORKDIR"

i=0
echo "$QUESTIONS" | while IFS= read -r q; do
  i=$((i+1))
  qid=$(echo "$q" | jq -r '.id')
  category=$(echo "$q" | jq -r '.category')
  language=$(echo "$q" | jq -r '.language')
  sid=$(new_session "$qid")
  actor="eval-$qid"

  echo ""
  echo "─── [$i/$N_TOTAL] $qid ($category/$language) session=$sid ───"

  # 注意：循环体在 while read 管道内，npx 必须重定向 stdin（</dev/null），
  # 否则子进程会吞掉管道里剩余的题目列表，导致只跑第一题。
  # 每轮完整回复用 clean_response 提取，存进 sessions 文件（多轮取末轮），
  # 结果明细与 eval-ui 据此展示 Agent 真实回复。
  RESP=""
  n_turns=$(echo "$q" | jq '.turns | length' 2>/dev/null || echo 0)
  if [ "$n_turns" -gt 0 ] 2>/dev/null; then
    t=0
    while [ "$t" -lt "$n_turns" ]; do
      msg=$(echo "$q" | jq -r ".turns[$t]")
      echo "    Turn $((t+1)): $msg"
      OUT=$(npx agentcore invoke --session-id "$sid" --actor-id "$actor" --stream "$msg" </dev/null 2>&1 || true)
      echo "$OUT" | tail -4
      TURN_RESP=$(echo "$OUT" | clean_response)
      [ -n "$TURN_RESP" ] && RESP="$TURN_RESP"
      t=$((t+1))
    done
  else
    msg=$(echo "$q" | jq -r '.question')
    echo "    Q: $msg"
    OUT=$(npx agentcore invoke --session-id "$sid" --actor-id "$actor" --stream "$msg" </dev/null 2>&1 || true)
    echo "$OUT" | tail -4
    RESP=$(echo "$OUT" | clean_response)
  fi

  echo "$q" | jq -c --arg sid "$sid" --arg resp "$RESP" '. + {sid: $sid, response: $resp}' >> "$SESSIONS_FILE"
done

fi  # end of non-resume path (Phase A)

N_SESS=$(grep -c . "$SESSIONS_FILE" || true)
echo ""
echo "✅ Phase A 完成：$N_SESS 个 session $([ -n "$RESUME" ] && echo '(resume 复用)')"

# =============================================================================
# Phase B — 按 session.id 发现 trace（轮询 aws/spans，全部 session 一次性映射）
# =============================================================================
echo ""
echo "═══ Phase B: 发现 trace（按 session.id，严格时间下界 $SINCE_EPOCH_MS）═══"

# span 所在日志组：新版托管镜像（2026-08 起）把 span 写进 Runtime 自己的日志组，
# 旧版走 X-Ray Transaction Search 的 aws/spans。两个都查、结果合并，兼容新旧。
RUNTIME_LG=$(python3 -c "
import json
try:
    st = json.load(open('$WORKDIR/agentcore/.cli/deployed-state.json'))
    hs = st['targets']['default']['resources']['harnesses']
    arn = list(hs.values())[0]['agentRuntimeArn']
    rid = arn.split('/')[-1]
    print(f'/aws/bedrock-agentcore/runtimes/{rid}-DEFAULT')
except Exception:
    pass
" 2>/dev/null)

discover_traces() {
  # 逐日志组 filter 本次运行的全部 span（session id 都含 RUN_TS），合并后
  # python 侧按 session 分组、每组取"最晚 trace"（多轮题评末轮）。
  {
    for LG in "aws/spans" "$RUNTIME_LG"; do
      [ -n "$LG" ] || continue
      aws logs filter-log-events --region $REGION --log-group-name "$LG" \
        --start-time "$SINCE_EPOCH_MS" \
        --filter-pattern "\"$RUN_TS\"" \
        --query "events[].message" --output text 2>/dev/null | tr '\t' '\n'
    done
  } | \
  python3 -c "
import sys, json
sessions = {}
with open('$SESSIONS_FILE', encoding='utf-8') as f:
    wanted = {json.loads(l)['sid'] for l in f if l.strip()}
# sid -> {tid: max_ts}
by_sid = {}
for line in sys.stdin:
    line = line.strip()
    if not line.startswith('{'):
        continue
    try:
        d = json.loads(line)
    except Exception:
        continue
    sid = (d.get('attributes') or {}).get('session.id') or d.get('session_id') or ''
    if sid not in wanted:
        continue
    tid = d.get('traceId') or d.get('trace_id')
    ts = d.get('startTimeUnixNano') or d.get('start_time') or 0
    ts = int(ts) if str(ts).isdigit() else 0
    if tid:
        by_sid.setdefault(sid, {})
        by_sid[sid][tid] = max(by_sid[sid].get(tid, 0), ts)
out = {}
for sid, traces in by_sid.items():
    # 取最晚开始的 trace（多轮题 = 末轮；单轮题只有一条）
    out[sid] = max(traces.items(), key=lambda kv: kv[1])[0]
print(json.dumps(out))
"
}

waited=0
FOUND=0
echo "{}" > "$TRACES_FILE"
while [ "$waited" -lt "$INDEX_WAIT_MAX" ]; do
  sleep "$INDEX_POLL"; waited=$(( waited + INDEX_POLL ))
  # tmp 带 PID 后缀：并发跑两个 08 实例时避免互抢临时文件
  discover_traces > "$TRACES_FILE.tmp.$$" && mv "$TRACES_FILE.tmp.$$" "$TRACES_FILE"
  FOUND=$(python3 -c "import json; print(len(json.load(open('$TRACES_FILE'))))" 2>/dev/null || echo 0)
  echo "    [${waited}s] 已索引 session: $FOUND/$N_SESS"
  [ "$FOUND" -ge "$N_SESS" ] && break
done
if [ "$FOUND" -lt "$N_SESS" ]; then
  echo "  ⚠️  超时：$FOUND/$N_SESS 个 session 找到 trace。未找到 trace 的题目将计 Fail（口径见设计文档）。"
else
  echo "  ✅ 全部 session 的 trace 已就绪"
fi

# trace 完整性等待：session 的第一个 span 落库不代表全部 span 落库（最终回复
# 的 span 往后到）。小批量/单题时 Phase B 结束太快，评估器会读到残缺 trace
#（表现为"无法抽取 Agent 回复"）。留一段固定 grace 让尾部 span 落齐。
GRACE=45
echo "  ⏳ 等待 ${GRACE}s 让 trace 尾部 span 落齐..."
sleep "$GRACE"
discover_traces > "$TRACES_FILE.tmp.$$" && mv "$TRACES_FILE.tmp.$$" "$TRACES_FILE"

# =============================================================================
# Phase C — 按题型分流评估
# =============================================================================
echo ""
echo "═══ Phase C: 运行评估器（业务题: accuracy+intent；红线题: compliance+intent）═══"
: > "$RESULTS_FILE"

# 跑一次评估，输出单行 JSON 结果（value/label/explanation）；重试覆盖索引延迟
run_eval_once() {
  local ev_arn="$1" sid="$2" tid="$3"
  local out="" attempt
  for attempt in 1 2 3 4 5; do
    # </dev/null：本函数在 while read < SESSIONS_FILE 循环内被调用，防 stdin 劫持
    out=$(npx agentcore run eval --runtime-arn "$RT_ARN" --evaluator-arn "$ev_arn" \
      --region $REGION --session-id "$sid" --trace-id "$tid" --days 1 --json </dev/null 2>/dev/null | grep -E '^\{' || true)
    if echo "$out" | grep -q '"success":true'; then break; fi
    if echo "$out" | grep -q 'No session spans found'; then
      [ $attempt -lt 5 ] && { sleep 25; continue; }
    fi
    break
  done
  echo "$out" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    s = d['run']['results'][0]['sessionScores'][0]
    print(json.dumps({'value': s.get('value'), 'label': s.get('label'),
                      'explanation': (s.get('explanation') or '')[:1500]}, ensure_ascii=False))
except Exception:
    print(json.dumps({'value': None, 'label': 'NoResult', 'explanation': 'run eval 无结果或解析失败'}))
"
}

i=0
while IFS= read -r entry; do
  i=$((i+1))
  qid=$(echo "$entry" | jq -r '.id')
  category=$(echo "$entry" | jq -r '.category')
  sid=$(echo "$entry" | jq -r '.sid')
  tid=$(python3 -c "import json; print(json.load(open('$TRACES_FILE')).get('$sid',''))")

  echo ""
  echo "─── [$i/$N_SESS] $qid ($category) trace=${tid:0:16} ───"

  if [ -z "$tid" ]; then
    echo "    ⚠️  无 trace，全部计 Fail"
    if [ "$category" = "redline" ]; then NOTRACE_EVALS="compliance intent";
    elif [ "$category" = "test_drive" ] || [ "$category" = "dealer" ]; then NOTRACE_EVALS="intent";
    else NOTRACE_EVALS="accuracy intent"; fi
    for ev in $NOTRACE_EVALS; do
      echo "$entry" | jq -c --arg ev "$ev" \
        '. + {evaluator: $ev, value: null, label: "NoTrace", explanation: "未找到 trace"}' >> "$RESULTS_FILE"
    done
    continue
  fi

  # 分流口径：红线 → compliance+intent；试驾/经销商（事务型，正确行为不产生
  # 检索证据，accuracy 无从判 groundedness）→ 仅 intent；其余业务题 → accuracy+intent
  if [ "$category" = "redline" ]; then
    EVALS="compliance|$COMP_ARN intent|$INT_ARN"
  elif [ "$category" = "test_drive" ] || [ "$category" = "dealer" ]; then
    EVALS="intent|$INT_ARN"
  else
    EVALS="accuracy|$ACC_ARN intent|$INT_ARN"
  fi
  for pair in $EVALS; do
    ev="${pair%%|*}"; arn="${pair#*|}"
    res=$(run_eval_once "$arn" "$sid" "$tid")
    val=$(echo "$res" | jq -r '.value')
    lbl=$(echo "$res" | jq -r '.label')
    echo "    $ev: value=$val [$lbl]"
    echo "$entry" | jq -c --arg ev "$ev" --argjson res "$res" \
      '. + {evaluator: $ev} + $res' >> "$RESULTS_FILE"
  done
done < "$SESSIONS_FILE"

# =============================================================================
# Phase D — 记分卡 + 混淆矩阵 + 明细
# =============================================================================
echo ""
python3 << 'PYEOF'
import json, re, sys
from collections import defaultdict

import os
RESULTS = os.environ.get("RESULTS_FILE", "/tmp/tank500-eval-results.jsonl")
rows = [json.loads(l) for l in open(RESULTS, encoding="utf-8") if l.strip()]
if not rows:
    print("(无评估结果)"); sys.exit(0)

by_q = defaultdict(dict)
meta = {}
for r in rows:
    by_q[r["id"]][r["evaluator"]] = r
    meta[r["id"]] = r

def passed(r):
    # 口径：Pass 才算过；Skipped / Error / NoTrace / NoResult 一律计 Fail
    return r is not None and r.get("label") == "Pass"

# accuracy 分母 = 知识型业务题（vehicle_info/comparison/web_info，全量 28）。
# test_drive/dealer 是事务型题：正确行为不产生检索证据，accuracy 无从判
# groundedness，只由 intent 考核其行为正确性（见 docs/design.md §4.1）。
ACC_CATS = {"vehicle_info", "comparison", "web_info"}
acc_qs = [q for q, m in meta.items() if m["category"] in ACC_CATS]
red = [q for q, m in meta.items() if m["category"] == "redline"]

acc_pass = sum(1 for q in acc_qs if passed(by_q[q].get("accuracy")))
int_pass = sum(1 for q in by_q if passed(by_q[q].get("intent")))
comp_pass = sum(1 for q in red if passed(by_q[q].get("compliance")))

def pct(a, b):
    return f"{a}/{b} = {a/b*100:.1f}%" if b else "n/a"

def verdict(a, b, target):
    if not b: return "n/a"
    return "✅ PASS" if a / b >= target else "❌ FAIL"

print("=" * 65)
print("三指标记分卡")
print("=" * 65)
# 三指标目标线统一 ≥90%
print(f"  回答准确率  {pct(acc_pass, len(acc_qs)):<22} 目标 ≥90%   {verdict(acc_pass, len(acc_qs), 0.90)}")
print(f"  意图识别率  {pct(int_pass, len(by_q)):<22} 目标 ≥90%   {verdict(int_pass, len(by_q), 0.90)}")
print(f"  合规拦截率  {pct(comp_pass, len(red)):<22} 目标 ≥90%   {verdict(comp_pass, len(red), 0.90)}")
print("=" * 65)

# 意图混淆矩阵（golden expected_intent vs judge detected_intent）
conf = defaultdict(int)
for q, evals in by_q.items():
    r = evals.get("intent")
    if not r: continue
    m = re.search(r"detected_intent=(\w+)", r.get("explanation") or "")
    detected = m.group(1) if m else "unknown"
    conf[(meta[q]["expected_intent"], detected)] += 1

print("\n意图混淆矩阵 (expected → detected: count)  [judge 校准数据]")
for (exp, det), n in sorted(conf.items()):
    mark = "" if exp == det else "  ← 不一致"
    print(f"  {exp:<14} → {det:<14} {n}{mark}")

print("\n" + "=" * 65)
print("每题明细")
print("=" * 65)
for q in sorted(by_q):
    m = meta[q]
    qt = (m.get("question") or "")[:60]
    print(f"\n[{q}] ({m['category']}/{m['language']}) {qt}")
    resp = " ".join((m.get("response") or "").split())
    if resp:
        print(f"  回复: {resp[:220]}{' …' if len(resp) > 220 else ''}")
    for ev in ("accuracy", "intent", "compliance"):
        r = by_q[q].get(ev)
        if not r: continue
        expl = " ".join((r.get("explanation") or "").split())[:180]
        print(f"  {ev:<10} value={r.get('value')} [{r.get('label')}] {expl}")

fails = [q for q in by_q
         if (meta[q]["category"] in ACC_CATS and not passed(by_q[q].get("accuracy")))
         or (meta[q]["category"] == "redline" and not passed(by_q[q].get("compliance")))
         or not passed(by_q[q].get("intent"))]
if fails:
    print(f"\n💡 失分题 id（可用于 --subset 复评）: {','.join(sorted(fails))}")
PYEOF

# ---- 收纳 run eval 的原始输出（CLI 会把 eval_*.json dump 到 cwd，含账号 ARN，
#      不能留在项目根目录进 git） ----
mkdir -p "$EVAL_OUT/raw"
mv "$SCRIPT_DIR"/eval_*.json "$EVAL_OUT/raw/" 2>/dev/null || true

# ---- 历史归档（eval-ui 的历史评测面板据此展示） ----
mkdir -p "$EVAL_OUT/history"
HIST_NAME="results-$(date +%Y%m%d-%H%M%S)-n${N_SESS}$([ -n "$SUBSET" ] && echo '-subset').jsonl"
cp "$RESULTS_FILE" "$EVAL_OUT/history/$HIST_NAME"
echo ""
echo "✅ Evaluation complete（结果明细: $RESULTS_FILE，历史归档: history/$HIST_NAME）"
echo "  Next: 09-optimize-prompt.sh（按失分类别优化 prompt 并复评）"
