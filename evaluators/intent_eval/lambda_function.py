"""intent_eval — 意图识别率评估器（TRACE 级，L1 代码判定为主）。

docs/design.md §4.2：
  1. judge 对 query 做意图分类 → detected_intent（6 类枚举）
  2. 代码检查 tool_calls 实际路径是否落在该意图的期望行为集合内
  value = 1.0 / 0.0。detected_intent 写入 explanation（批量脚本据此与黄金集
  expected_intent 对照输出混淆矩阵）。

  多轮 session 特殊分支（评估器自主判定，不依赖黄金集标注）：
  检测到多个用户轮次时跳过单轮 query 分类，改走 session 级行为扫描——
  session 内出现 book_test_drive 即 detected_intent=test_drive 且 Pass；
  否则拼接全部用户输入交 judge 分类再做行为核对。
"""
import json
import os
import sys

sys.path.insert(0, os.path.dirname(__file__))

from bedrock_agentcore.evaluation.custom_code_based_evaluators import (
    custom_code_based_evaluator,
    EvaluatorInput,
    EvaluatorOutput,
)

from shared.llm_client import LLMClient
from span_adapter import (
    extract_trace_view,
    count_user_turns,
    session_tool_names,
    all_user_queries,
)

REGION = os.environ.get("INTENT_REGION") or os.environ.get("AWS_REGION", "us-west-2")
JUDGE_MODEL = os.environ.get("INTENT_MODEL", "us.amazon.nova-2-lite-v1:0")

INTENTS = ("vehicle_info", "comparison", "web_info", "test_drive", "dealer", "off_topic")

# intent → 期望行为（docs/design.md §4.2 权威映射表）
# required: 必须出现的工具（任一即可）；allowed_extra: 允许附带的工具
EXPECTED_BEHAVIOR = {
    "vehicle_info": {"required": {"retrieve_tank500_info"}},
    "comparison": {"required": {"compare_competitor"}, "allowed_extra": {"web_search"}},
    "web_info": {"required": {"web_search"}},
    "test_drive": {"required": {"book_test_drive"}},   # trace 或 session 级
    "dealer": {"required": {"get_dealer_info"}},
    "off_topic": {"required": set()},                   # 不调任何业务工具（纯代码判定）
}

CLASSIFY_PROMPT = """You are classifying the intent of a customer message sent to a car-sales \
assistant for the GWM Tank 500 (European market). Classify into EXACTLY ONE of:

- vehicle_info: asking about Tank 500 features, controls, safety, off-road capability, \
maintenance, seats, technical data (answerable from the owner's manual)
- comparison: asking to compare the Tank 500 with another vehicle / competitor
- web_info: asking for current market information — local price, discounts, promotions, \
launch dates, availability
- test_drive: expressing intent to test drive, book an appointment, or leaving contact details
- dealer: asking where to find a dealer / showroom
- off_topic: anything unrelated to vehicles or car buying (politics, adult content, violence, \
coding, medical advice, general chit-chat...)

The message may be in Chinese, English, German, Italian or another language.

Customer message:
---
{query}
---

Respond with ONLY a JSON object: {{"intent": "<one of the six labels>"}}"""

_llm = None


def _client():
    global _llm
    if _llm is None:
        _llm = LLMClient(model_id=JUDGE_MODEL, region=REGION)
    return _llm


def _classify(query: str) -> str:
    resp = _client().invoke(CLASSIFY_PROMPT.format(query=query[:2000]), max_tokens=100)
    text = resp.text.strip()
    # 容忍 judge 输出裹了代码块或多余文字
    start, end = text.find("{"), text.rfind("}")
    if start >= 0 and end > start:
        try:
            intent = json.loads(text[start:end + 1]).get("intent", "")
            if intent in INTENTS:
                return intent
        except Exception:
            pass
    # 兜底：在原文里找枚举词
    low = text.lower()
    for i in INTENTS:
        if i in low:
            return i
    return ""


def _behavior_matches(intent: str, actual_tools: set) -> bool:
    """L1 代码判定：实际工具路径是否符合该意图的期望行为。"""
    spec = EXPECTED_BEHAVIOR[intent]
    required = spec["required"]
    if not required:  # off_topic：不允许任何业务工具
        return len(actual_tools) == 0
    return bool(required & actual_tools)


def _diag_spans(session_spans, target_trace_id):
    """诊断：逐条打印 chat span 的 input/output messages 结构（进 Lambda 日志）。"""
    try:
        print(f"[DIAG] n_spans={len(session_spans)} target_trace={target_trace_id}")
        for i, s in enumerate(session_spans):
            if not isinstance(s, dict):
                continue
            n_ev = len(s.get("span_events") or [])
            if n_ev == 0:
                continue
            print(f"[DIAG] span{i} name={s.get('name')!r} n_events={n_ev} trace={s.get('trace_id')}")
            for e in (s.get("span_events") or []):
                body = e.get("body") or {}
                if not isinstance(body, dict):
                    continue
                for side in ("input", "output"):
                    obj = body.get(side)
                    if not isinstance(obj, dict):
                        continue
                    msgs = obj.get("messages") or []
                    print(f"[DIAG]   {side}: n_messages={len(msgs)}")
                    for j, m in enumerate(msgs):
                        if isinstance(m, dict):
                            role = m.get("role", "<none>")
                            c = m.get("content")
                            ctype = type(c).__name__
                            if isinstance(c, dict):
                                ckeys = sorted(c.keys())
                                # 每个子键的值尾部（跳过 system prompt 长头部）
                                detail = {k: (str(v)[-160:] if len(str(v)) > 160 else str(v))
                                          for k, v in c.items()}
                                print(f"[DIAG]     msg{j} role={role} content=dict keys={ckeys} tail={json.dumps(detail, ensure_ascii=False)[:400]}")
                            else:
                                sv = str(c)
                                print(f"[DIAG]     msg{j} role={role} content={ctype} len={len(sv)} tail={sv[-200:]!r}")
                        else:
                            print(f"[DIAG]     msg{j} raw={str(m)[-200:]!r}")
    except Exception as e:
        import traceback
        print("[DIAG] failed:", traceback.format_exc()[:800])


@custom_code_based_evaluator()
def handler(input: EvaluatorInput, context) -> EvaluatorOutput:
    try:
        # 需要排查 span 结构时：给 evaluator Lambda 设 INTENT_DIAG=1 后重跑
        if os.environ.get("INTENT_DIAG") == "1":
            _diag_spans(input.session_spans, input.target_trace_id)
        view = extract_trace_view(input.session_spans, input.target_trace_id)
        trace_tools = {c["name"] for c in view["tool_calls"]}
        n_turns = count_user_turns(input.session_spans)

        # ---- 多轮 session 分支（docs/design.md §4.2）----
        if n_turns > 1:
            sess_tools = session_tool_names(input.session_spans)
            if "book_test_drive" in sess_tools:
                return EvaluatorOutput(
                    value=1.0, label="Pass",
                    explanation=(
                        f"detected_intent=test_drive | multi_turn={n_turns} | "
                        f"session_tools={sorted(sess_tools)} | matched=True "
                        f"(session 级行为扫描命中 book_test_drive)"
                    ),
                )
            joined = " || ".join(all_user_queries(input.session_spans))[:2000]
            detected = _classify(joined) if joined else ""
            if not detected:
                return EvaluatorOutput(
                    value=0.0, label="Fail",
                    explanation=f"detected_intent=unknown | multi_turn={n_turns} | judge 分类失败，计 Fail",
                )
            matched = _behavior_matches(detected, sess_tools)
            return EvaluatorOutput(
                value=1.0 if matched else 0.0,
                label="Pass" if matched else "Fail",
                explanation=(
                    f"detected_intent={detected} | multi_turn={n_turns} | "
                    f"session_tools={sorted(sess_tools)} | matched={matched}"
                ),
            )

        # ---- 单轮分支 ----
        query = view["query"]
        if not query:
            # 技术约束（实测）：Strands telemetry 不把 user message 写进 span，
            # input.messages 只有 system + tool 角色。有工具调用时可从工具入参
            # 反推 query；完全无工具调用时拿不到任何用户文本——此时唯一可判定的
            # 是"Agent 未调用任何业务工具"，即 off_topic 的期望行为（纯代码判定，
            # 与 §4.2 映射表一致）。拒答内容的质量由 compliance_eval 负责。
            if not trace_tools and view["response"]:
                return EvaluatorOutput(
                    value=1.0, label="Pass",
                    explanation=(
                        "detected_intent=off_topic | actual_tools=[] | matched=True "
                        "(无用户文本可分类 → 按行为判定：未调用任何业务工具，符合 off_topic 期望)"
                    ),
                )
            return EvaluatorOutput(
                value=0.0, label="Fail",
                explanation=(
                    f"detected_intent=unknown | actual_tools={sorted(trace_tools)} | "
                    f"无用户文本可分类，且存在工具调用（非 off_topic 行为），计 Fail"
                ),
            )

        detected = _classify(query)
        if not detected:
            return EvaluatorOutput(
                value=0.0, label="Fail",
                explanation=f"detected_intent=unknown | judge 分类失败 (query: {query[:60]})，计 Fail",
            )

        # test_drive 允许 session 级命中（本轮可能只在收集信息，工具在后续轮）
        actual = trace_tools if detected != "test_drive" else (
            trace_tools | session_tool_names(input.session_spans)
        )
        matched = _behavior_matches(detected, actual)
        return EvaluatorOutput(
            value=1.0 if matched else 0.0,
            label="Pass" if matched else "Fail",
            explanation=(
                f"detected_intent={detected} | actual_tools={sorted(actual)} | "
                f"matched={matched} (query: {query[:60]})"
            ),
        )
    except Exception as e:
        import traceback
        print("[INTENT] EXCEPTION:", traceback.format_exc())
        return EvaluatorOutput(
            value=None, label="Error",
            errorCode="INTENT_EVAL_FAILED", errorMessage=str(e)[:500],
        )
