"""accuracy_eval — 回答准确率评估器（TRACE 级，改造自 THELMA）。

docs/design.md §4.1：
  保留对"准确"最关键的两个维度——
    GR  (Groundedness)            回复中每个事实句是否有 evidence 支撑（防幻觉）
    RQC (Response Query Coverage) 是否完整回答了用户所问
  判分 value = min(GR, RQC)，Pass 阈值 0.7（ACC_THRESHOLD 可调）。
  SP1/SP2/SQC/SD 等检索诊断分数写入 explanation 供诊断，不参与判分。
  拒答类 trace（无证据工具调用）返回 Skipped——仅评估器侧防御；
  聚合口径以黄金集为权威（业务题上 Skipped/Error 由批量脚本计 Fail）。
"""
import os
import sys

# 让 evaluators.thelma / shared 可导入（包根就是本文件所在目录）
sys.path.insert(0, os.path.dirname(__file__))

from bedrock_agentcore.evaluation.custom_code_based_evaluators import (
    custom_code_based_evaluator,
    EvaluatorInput,
    EvaluatorOutput,
)

from shared.llm_client import LLMClient
from shared.embedding_client import EmbeddingClient
from evaluators.thelma.metrics import evaluate_turn_detailed
from evaluators.thelma.interplay import diagnose
from span_adapter import extract_turns_for_trace

REGION = os.environ.get("ACC_REGION") or os.environ.get("AWS_REGION", "us-west-2")
JUDGE_MODEL = os.environ.get("ACC_MODEL", "us.amazon.nova-2-lite-v1:0")
EMBED_MODEL = os.environ.get("ACC_EMBED_MODEL", "amazon.titan-embed-text-v2:0")
PASS_THRESHOLD = float(os.environ.get("ACC_THRESHOLD", "0.7"))

_llm = None
_embed = None


def _clients():
    global _llm, _embed
    if _llm is None:
        _llm = LLMClient(model_id=JUDGE_MODEL, region=REGION)
        _embed = EmbeddingClient(model_id=EMBED_MODEL, region=REGION)
    return _llm, _embed


@custom_code_based_evaluator()
def handler(input: EvaluatorInput, context) -> EvaluatorOutput:
    turns = extract_turns_for_trace(input.session_spans, input.target_trace_id)
    # 只评有证据来源的轮次（KB / 竞品档案 / 搜索结果）
    rag_turns = [t for t in turns if t.get("sources") and t.get("query")]
    if not rag_turns:
        return EvaluatorOutput(
            value=None, label="Skipped",
            explanation="该 trace 无证据类工具调用（拒答/纯留资轮次），accuracy_eval 跳过。"
                        "注意：若这是黄金集业务题，批量脚本会将 Skipped 计为 Fail。",
        )

    t = rag_turns[0]
    try:
        llm, embed = _clients()
        scores, evidence = evaluate_turn_detailed(
            query=t["query"], sources=t["sources"], response=t["response"],
            llm=llm, embed_fn=embed.embed, skip_sp2=False,
            # SP2（事实级检索精度）用于诊断：手册的 OCR 噪音与 WARNING 碎块
            # 会在这里现形（块看着相关、块内事实一半是噪音）。
        )
    except Exception as e:
        import traceback
        print("[ACCURACY] EXCEPTION:", traceback.format_exc())
        return EvaluatorOutput(
            value=None, label="Error",
            errorCode="ACCURACY_EVAL_FAILED", errorMessage=str(e)[:500],
        )

    gr = round(scores.groundedness, 3)
    rqc = round(scores.response_query_coverage, 3)
    value = min(gr, rqc)
    label = "Pass" if value >= PASS_THRESHOLD else "Fail"

    diags = diagnose(scores)
    diag_txt = "; ".join(f"{d.pattern}->{d.component_to_improve}" for d in diags) if diags else "无"

    explanation = (
        f"accuracy=min(GR,RQC)={value:.3f} (query: {t['query'][:40]}): "
        f"GR(接地/防幻觉)={gr} | RQC(响应覆盖)={rqc} | "
        f"诊断分[不判分]: SP1(块级检索精度)={scores.source_precision_chunk:.2f} "
        f"SP2(事实级检索精度)={scores.source_precision_fact:.2f} "
        f"SQC(源覆盖)={scores.source_query_coverage:.2f} "
        f"RP(响应精度)={scores.response_precision:.2f} "
        f"SD(去重)={scores.response_self_distinctness:.2f}. "
        f"诊断: {diag_txt}"
    )
    return EvaluatorOutput(value=value, label=label, explanation=explanation[:2000])
