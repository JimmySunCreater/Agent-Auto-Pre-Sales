"""把 AgentCore 的 session_spans（ADOT span dict）解析成统一的 TraceView。

TraceView（docs/design.md §4.0）：
  query:       用户本轮输入（从 chat/LLM span 的 user 消息抽取，兜底用工具入参）
  tool_calls:  [{name, input, output}, ...]  # tank500-tools___* 的 execute_tool span
  evidence:    证据类工具（KB/竞品/搜索）返回内容拼接
  response:    Agent 最终回复文本
另提供 session 级辅助：
  count_user_turns(spans)     # session 内用户轮次数（≈ 不同 trace 数）
  session_tool_names(spans)   # session 内出现过的业务工具名集合
  all_user_queries(spans)     # session 内全部用户输入（多轮意图分类用）

结构解析逻辑继承自 workshop 的 thelma_eval/span_adapter.py（execute_tool span 的
三层嵌套 JSON、chat span 的 assistant 纯文本判定）。
"""
from __future__ import annotations

import json
import re

# 业务工具（tank500-tools___ 前缀在 span 名/工具名里）
EVIDENCE_TOOL_MARKERS = ("retrieve_tank500_info", "compare_competitor", "web_search")
BUSINESS_TOOL_MARKERS = EVIDENCE_TOOL_MARKERS + ("book_test_drive", "get_dealer_info")


def _safe_json(s):
    if not isinstance(s, str):
        return s
    try:
        return json.loads(s)
    except Exception:
        return None


def _get_attr(span: dict, key: str):
    return (span.get("attributes") or {}).get(key)


def _iter_span_events(span: dict):
    for e in (span.get("span_events") or []):
        body = e.get("body") or {}
        yield body


# ---------------------------------------------------------------------------
# 新版托管镜像的 span 格式（2026-08 实测）：事件在 span["events"]，
# 每个事件 {timeUnixNano, name, attributes}，关键事件名：
#   gen_ai.system.message                      attributes.content = system prompt
#   gen_ai.HarnessConversationRole.user.message attributes.content = 用户消息
#     （invoke_agent span 里是干净原话；chat span 里带 <user_context> 记忆前缀）
#   gen_ai.choice                              attributes.message + finish_reason
#     （end_turn = 最终回复；tool_use = 工具调用请求）
#   gen_ai.tool.message                        attributes.content = 工具入参 JSON
# ---------------------------------------------------------------------------
def _iter_new_events(span: dict):
    for e in (span.get("events") or []):
        if isinstance(e, dict) and e.get("name"):
            yield e


def _text_blocks(raw) -> str:
    """解析 '[{"text": "..."}]' 形式的内容为纯文本；纯文本原样返回。"""
    if not isinstance(raw, str):
        return ""
    parsed = _safe_json(raw)
    if isinstance(parsed, list):
        parts = [b.get("text", "") for b in parsed if isinstance(b, dict) and b.get("text")]
        return " ".join(parts).strip()
    if isinstance(parsed, dict) and parsed.get("text"):
        return str(parsed["text"]).strip()
    return raw.strip()


def _strip_user_context(txt: str) -> str:
    """剥离 Memory 注入的 <user_context>...</user_context> / 前缀 JSON 段。"""
    if not txt.startswith("<user_context>"):
        return txt
    end = txt.find("</user_context>")
    if end >= 0:
        return txt[end + len("</user_context>"):].strip()
    # 无闭合标签：JSON 段后第一个换行起是记忆摘要+原话，取最后一行兜底
    nl = txt.find("\n")
    if nl >= 0:
        rest = txt[nl + 1:].strip()
        return rest.split("\n")[-1].strip() or rest
    return txt


def _msg_text(m, prefer="content"):
    if isinstance(m, str):
        return m
    if not isinstance(m, dict):
        return ""
    c = m.get("content")
    if isinstance(c, str):
        return c
    if isinstance(c, dict):
        if prefer == "message":
            return c.get("message") or c.get("text") or c.get("content") or ""
        return c.get("content") or c.get("text") or c.get("message") or ""
    return m.get("text") or m.get("message") or ""


def _matched_tool(span: dict) -> str:
    """span 是业务工具调用则返回工具名，否则返回空串。"""
    name = span.get("name") or ""
    tool = _get_attr(span, "gen_ai.tool.name") or ""
    blob = f"{name} {tool}".lower()
    for marker in BUSINESS_TOOL_MARKERS:
        if marker in blob:
            return marker
    return ""


def _deep_extract_payload(message_str: str) -> str:
    """从三层嵌套的 tool output message 里抽出有效载荷文本。

    结构：'[{"text": "{\"statusCode\":200,\"body\":\"{...}\"}"}]'
    有 answer 字段返回 answer；否则返回整个 body 的 JSON 文本（截断）。
    """
    outer = _safe_json(message_str)
    text_blob = None
    if isinstance(outer, list) and outer and isinstance(outer[0], dict):
        text_blob = outer[0].get("text")
    elif isinstance(outer, dict):
        text_blob = outer.get("text") or outer.get("body")
    if text_blob is None:
        text_blob = message_str

    lvl2 = _safe_json(text_blob)
    body = lvl2.get("body", lvl2) if isinstance(lvl2, dict) else text_blob

    lvl3 = _safe_json(body) if isinstance(body, str) else body
    if isinstance(lvl3, dict):
        if "answer" in lvl3:
            return str(lvl3["answer"])
        return json.dumps(lvl3, ensure_ascii=False)[:6000]

    # 兜底：正则抠 answer
    m = re.search(r'\\*"answer\\*"\s*:\s*\\*"(.+?)\\*"', message_str, re.S)
    if m:
        return m.group(1).encode().decode("unicode_escape", errors="replace")
    return str(body)[:6000] if body else ""


def _filter_trace(session_spans: list, target_trace_id) -> list:
    spans = [s for s in session_spans if isinstance(s, dict)]
    if target_trace_id:
        filtered = [
            s for s in spans
            if s.get("trace_id") == target_trace_id or s.get("traceId") == target_trace_id
        ]
        if filtered:
            return filtered
    return spans


def extract_tool_calls(spans: list) -> list[dict]:
    """[{name, input(dict), output(str)}] —— 业务工具的 execute_tool span。

    兼容两种格式：旧版 span_events[].body.{input,output}.messages，
    新版 events[]（gen_ai.tool.message = 入参；gen_ai.choice.message = 输出）。
    """
    calls = []
    for s in spans:
        tool = _matched_tool(s)
        if not tool:
            continue
        # "mcp tools/call X" 与 "execute_tool X" 是同一次调用的两层 span，
        # 只收 execute_tool 层避免重复计数
        if (s.get("name") or "").startswith("mcp tools/call"):
            continue
        tool_input, tool_output = {}, ""

        # --- 新格式 ---
        for e in _iter_new_events(s):
            attrs = e.get("attributes") or {}
            if e["name"] == "gen_ai.tool.message":
                parsed = _safe_json(attrs.get("content"))
                if isinstance(parsed, dict):
                    tool_input = parsed
            elif e["name"] == "gen_ai.choice":
                msg = attrs.get("message")
                if msg:
                    tool_output = _deep_extract_payload(msg)

        # --- 旧格式 ---
        if not tool_input and not tool_output:
            for body in _iter_span_events(s):
                if not isinstance(body, dict):
                    continue
                inp_obj = body.get("input")
                inp = inp_obj.get("messages") or [] if isinstance(inp_obj, dict) else []
                for m in inp:
                    parsed = _safe_json(_msg_text(m))
                    if isinstance(parsed, dict):
                        tool_input = parsed
                out_obj = body.get("output")
                out = out_obj.get("messages") or [] if isinstance(out_obj, dict) else []
                for m in out:
                    msg = _msg_text(m, prefer="message")
                    if msg:
                        tool_output = _deep_extract_payload(msg)
        calls.append({"name": tool, "input": tool_input, "output": tool_output})
    return calls


# ---------------------------------------------------------------------------
# Agent 回复 / 用户输入抽取（继承 workshop 的判定逻辑）
# ---------------------------------------------------------------------------
def _looks_like_tool_payload(txt: str) -> bool:
    if not isinstance(txt, str):
        return True
    head = txt.lstrip()[:80]
    markers = ('"toolResult"', '"toolUse"', '"statusCode"', '\\"answer\\"',
               '"answer":', 'tooluse_', '"toolUseId"')
    return any(mk in txt[:200] for mk in markers) or head.startswith('[{"tool')


def _strip_if_tool_payload(txt: str) -> str:
    return "" if _looks_like_tool_payload(txt) else txt


def _plain_text_for_role(m, role: str) -> str:
    """从一条 message 取指定 role 的纯文本；工具消息返回空。

    assistant 回复实测在 output.messages[i].content.message，可能是纯文本
    也可能是 '[{"text": "..."}]' JSON 串——统一用 _any_message_text 解析。
    """
    if isinstance(m, dict):
        m_role = m.get("role")
        if role == "assistant" and m_role not in (None, "assistant"):
            return ""
        if role == "user" and m_role not in (None, "user"):
            return ""
    elif not isinstance(m, str):
        return ""
    return _strip_if_tool_payload(_any_message_text(m))


def _is_chat_span(s: dict) -> bool:
    name = (s.get("name") or "").lower()
    scope = (s.get("scope") or {}).get("name", "").lower()
    return (
        "chat" in name or "llm" in name or "invoke_model" in name or "strands" in scope
    )


def extract_agent_response(spans: list) -> str:
    """agent 的最终自然语言回复（按时间取最后一个 assistant 纯文本）。"""
    candidates = []
    for s in spans:
        if not _is_chat_span(s) and "invoke_agent" not in (s.get("name") or ""):
            continue
        st = str(s.get("start_time") or s.get("startTimeUnixNano") or "")

        # --- 新格式：events[] 里 finish_reason=end_turn 的 gen_ai.choice ---
        for e in _iter_new_events(s):
            attrs = e.get("attributes") or {}
            if e["name"] == "gen_ai.choice" and attrs.get("finish_reason") == "end_turn":
                txt = _text_blocks(attrs.get("message", ""))
                txt = _strip_if_tool_payload(txt)
                if txt:
                    candidates.append((st, txt))

        # --- 旧格式 ---
        for body in _iter_span_events(s):
            if not isinstance(body, dict):
                continue
            out = body.get("output")
            if not isinstance(out, dict):
                continue
            for m in out.get("messages") or []:
                txt = _plain_text_for_role(m, "assistant")
                if txt:
                    candidates.append((st, txt))
    for s in spans:
        ch = _get_attr(s, "gen_ai.choice")
        if isinstance(ch, str):
            t = _strip_if_tool_payload(ch)
            if t:
                candidates.append((str(s.get("start_time") or ""), t))
    if not candidates:
        return ""
    candidates.sort(key=lambda x: x[0])
    return candidates[-1][1]


# system prompt 的特征串（input.messages[0] 是 system prompt，需排除）
SYSTEM_PROMPT_MARKERS = (
    "## Role & Scope",
    "official online sales consultant",
    "You are the official",
)


def _looks_like_system_prompt(txt: str) -> bool:
    if not isinstance(txt, str):
        return True
    head = txt[:600]
    return any(mk in head for mk in SYSTEM_PROMPT_MARKERS)


def _any_message_text(m) -> str:
    """从一条 message 取文本，不依赖 role 字段（实测 input.messages 常无 role）。

    实测结构（strands.telemetry.tracer event body）：
      input.messages[i].content            = str（system prompt 或用户输入）
      input.messages[i].content.content    = '[{"text": "..."}]'
      output.messages[i].content.message   = 回复文本 或 '[{"text": "..."}]'
    """
    if isinstance(m, str):
        raw = m
    elif isinstance(m, dict):
        c = m.get("content")
        if isinstance(c, str):
            raw = c
        elif isinstance(c, dict):
            if "toolUse" in c or "toolResult" in c:
                return ""
            raw = c.get("content") or c.get("text") or c.get("message") or ""
        elif isinstance(c, list):
            parts = []
            for blk in c:
                if isinstance(blk, dict):
                    if "toolUse" in blk or "toolResult" in blk:
                        continue
                    if blk.get("text"):
                        parts.append(blk["text"])
                elif isinstance(blk, str):
                    parts.append(blk)
            raw = " ".join(parts)
        else:
            raw = m.get("text") or m.get("message") or ""
    else:
        return ""

    if not isinstance(raw, str) or not raw.strip():
        return ""

    # content 可能是 '[{"text": "..."}]' 形式的 JSON 串，再剥一层
    parsed = _safe_json(raw)
    if isinstance(parsed, list):
        parts = [b.get("text", "") for b in parsed if isinstance(b, dict) and b.get("text")]
        if parts:
            raw = " ".join(parts)
    elif isinstance(parsed, dict) and parsed.get("text"):
        raw = parsed["text"]

    return raw.strip()


def extract_user_query(spans: list) -> str:
    """本 trace 的用户输入。

    实测：chat / invoke_agent span 的 event body 里 input.messages[0] 是 system
    prompt（且常无 role 字段），用户输入在其后。因此不按 role 过滤，而是
    收集全部 message 文本 → 排除 system prompt / 工具载荷 → 取最后一条。
    兜底用工具 query 入参。
    """
    # --- 新格式优先：gen_ai.HarnessConversationRole.user.message 是权威用户消息。
    # invoke_agent span 里是干净原话；chat span 里带 <user_context> 记忆前缀需剥离。
    new_candidates = []  # (priority, start_time, text) —— invoke_agent 优先
    for s in spans:
        name = s.get("name") or ""
        st = str(s.get("start_time") or s.get("startTimeUnixNano") or "")
        for e in _iter_new_events(s):
            if e["name"] != "gen_ai.HarnessConversationRole.user.message":
                continue
            txt = _strip_user_context(_text_blocks((e.get("attributes") or {}).get("content", "")))
            if txt and not _looks_like_system_prompt(txt) and not _looks_like_tool_payload(txt):
                prio = 0 if "invoke_agent" in name else 1
                new_candidates.append((prio, st, txt))
    if new_candidates:
        new_candidates.sort()
        return new_candidates[0][2]

    best = None  # (start_time, index_in_messages, text)
    for s in spans:
        if not _is_chat_span(s):
            continue
        st = str(s.get("start_time") or s.get("startTimeUnixNano") or "")
        for body in _iter_span_events(s):
            if not isinstance(body, dict):
                continue
            inp = body.get("input")
            if not isinstance(inp, dict):
                continue
            msgs = inp.get("messages") or []
            for idx, m in enumerate(msgs):
                role = m.get("role") if isinstance(m, dict) else None
                # 实测 input.messages 只有 system / tool / assistant 角色，
                # tool 消息是工具入参/结果 JSON，绝不能当用户文本
                if role in ("assistant", "tool", "system"):
                    continue
                txt = _any_message_text(m)
                if not txt:
                    continue
                if _looks_like_system_prompt(txt) or _looks_like_tool_payload(txt):
                    continue
                cand = (st, idx, txt)
                # 同一 span 内取最后一条用户消息；跨 span 取最早的 span（本轮输入）
                if best is None or (cand[0] < best[0]) or (cand[0] == best[0] and cand[1] > best[1]):
                    best = cand
    if best:
        return best[2]

    # 兜底：从工具入参合成伪问题（trace 无用户文本时的最优近似——直接用入参
    # 会破坏 judge 语义：车名不是问题、dealer 入参是 JSON。合成后语义完整）
    return synthesize_query_from_tools(extract_tool_calls(spans))


def synthesize_query_from_tools(tool_calls: list) -> str:
    """按工具类型把入参还原成语义完整的伪问题。"""
    for c in tool_calls:
        name, inp = c["name"], c["input"]
        if name == "retrieve_tank500_info" and inp.get("query"):
            return str(inp["query"])
        if name == "compare_competitor" and inp.get("competitor_name"):
            return f"How does the Tank 500 compare with the {inp['competitor_name']}?"
        if name == "web_search" and inp.get("query"):
            return str(inp["query"])
        if name == "get_dealer_info":
            where = ", ".join(str(v) for v in (inp.get("city"), inp.get("country")) if v)
            return f"Where can I find a GWM dealer in {where}?" if where else \
                "Where can I find a GWM dealer?"
        if name == "book_test_drive":
            return "I want to book a test drive for the Tank 500."
    return ""


# ---------------------------------------------------------------------------
# 对外主接口
# ---------------------------------------------------------------------------
def extract_trace_view(session_spans: list, target_trace_id) -> dict:
    """TRACE 级视图：query / tool_calls / evidence / response。"""
    spans = _filter_trace(session_spans, target_trace_id)
    tool_calls = extract_tool_calls(spans)
    evidence_parts = [
        c["output"] for c in tool_calls
        if c["name"] in EVIDENCE_TOOL_MARKERS and c["output"]
    ]
    return {
        "query": extract_user_query(spans),
        "tool_calls": tool_calls,
        "evidence": "\n\n".join(evidence_parts),
        "response": extract_agent_response(spans),
    }


def count_user_turns(session_spans: list) -> int:
    """session 内用户轮次数 ≈ 含 chat span 的不同 trace 数。"""
    trace_ids = set()
    for s in session_spans:
        if isinstance(s, dict) and _is_chat_span(s):
            tid = s.get("trace_id") or s.get("traceId")
            if tid:
                trace_ids.add(tid)
    return max(len(trace_ids), 1)


def session_tool_names(session_spans: list) -> set:
    """session 内（跨全部 trace）出现过的业务工具名集合。"""
    spans = [s for s in session_spans if isinstance(s, dict)]
    return {c["name"] for c in extract_tool_calls(spans)}


def all_user_queries(session_spans: list) -> list[str]:
    """session 内全部用户输入，按 trace 分组后各取一条（多轮意图分类用）。"""
    spans = [s for s in session_spans if isinstance(s, dict)]
    by_trace = {}
    for s in spans:
        tid = s.get("trace_id") or s.get("traceId") or "_"
        by_trace.setdefault(tid, []).append(s)
    queries = []
    for tid, group in by_trace.items():
        q = extract_user_query(group)
        if q:
            queries.append(q)
    return queries
