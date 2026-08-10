#!/usr/bin/env python3
"""tank500-agent 本地评估控制台代理（docs/design.md §2.6）。

路由：
  GET  /          → index.html
  GET  /golden    → 黄金集元信息（类别/题目列表，供选择评估范围）
  POST /run       → {subset} 启动 08-run-eval.sh（后台子进程，同时只允许一个）
  GET  /status    → {running, elapsed, subset, returncode, log_tail, progress}
  GET  /results   → 解析 /tmp/tank500-eval-results.jsonl → 记分卡 + 混淆矩阵 + 明细

评估逻辑完全复用 08-run-eval.sh（本代理只是启动器 + 结果读取器），
记分卡口径与脚本 Phase D 一致（分母固定、Skipped/Error/NoTrace 计 Fail、
accuracy 分母 = 知识型题）。

安全边界：仅绑定 127.0.0.1、无鉴权，本机演示工具，勿改绑 0.0.0.0。

用法：
  python3 eval-ui/server.py [--port 8081]
"""

import argparse
import json
import os
import re
import subprocess
import threading
import time
from collections import defaultdict
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HERE = Path(__file__).parent
PROJECT = HERE.parent
GOLDEN_FILE = PROJECT / "eval-dataset" / "golden_questions.json"
# 结果文件在工程目录（与 08-run-eval.sh 一致；/tmp 会被系统清理）
EVAL_OUT = PROJECT / "eval-results"
EVAL_OUT.mkdir(exist_ok=True)
RESULTS_FILE = str(EVAL_OUT / "results.jsonl")
SESSIONS_FILE = str(EVAL_OUT / "sessions.jsonl")
LOG_FILE = str(EVAL_OUT / "eval-ui.log")

# 口径常量（与 08-run-eval.sh Phase D 保持一致；三指标目标线统一 90%）
ACC_CATS = {"vehicle_info", "comparison", "web_info"}
TARGETS = {"accuracy": 0.90, "intent": 0.90, "compliance": 0.90}
HISTORY_DIR = EVAL_OUT / "history"
HISTORY_DIR.mkdir(exist_ok=True)

# 黄金集编辑的校验枚举（与 docs/design.md §4.2 映射表一致）
VALID_CATS = ["vehicle_info", "comparison", "web_info", "test_drive", "dealer", "redline"]
VALID_INTENTS = ["vehicle_info", "comparison", "web_info", "test_drive", "dealer", "off_topic"]
VALID_LANGS = ["en", "de", "it", "zh"]
BEHAVIOR_MAP = {
    "vehicle_info": ["retrieve_tank500_info"],
    "comparison": ["compare_competitor"],
    "web_info": ["web_search"],
    "test_drive": ["book_test_drive"],
    "dealer": ["get_dealer_info"],
    "off_topic": [],
}


def save_golden(questions):
    """校验并保存黄金集：备份原文件 → 派生 expected_behavior → 重算 _meta。"""
    errors = []
    seen_ids = set()
    cleaned = []
    for i, q in enumerate(questions):
        tag = q.get("id") or f"#{i + 1}"
        qid = str(q.get("id", "")).strip()
        if not qid or " " in qid:
            errors.append(f"{tag}: id 不能为空或含空格")
            continue
        if qid in seen_ids:
            errors.append(f"{tag}: id 重复")
            continue
        seen_ids.add(qid)
        if q.get("category") not in VALID_CATS:
            errors.append(f"{tag}: category 必须是 {VALID_CATS}")
            continue
        if q.get("language") not in VALID_LANGS:
            errors.append(f"{tag}: language 必须是 {VALID_LANGS}")
            continue
        if q.get("expected_intent") not in VALID_INTENTS:
            errors.append(f"{tag}: expected_intent 必须是 {VALID_INTENTS}")
            continue
        if not str(q.get("question", "")).strip():
            errors.append(f"{tag}: question 不能为空")
            continue
        q = dict(q)
        q["id"] = qid
        q["question"] = str(q["question"]).strip()
        # expected_behavior 由 intent 自动派生（保持与评估器映射一致）
        q["expected_behavior"] = BEHAVIOR_MAP[q["expected_intent"]]
        # 多轮题：turns 为非空字符串列表，自动补 eval_turn
        turns = q.get("turns")
        if turns:
            turns = [str(t).strip() for t in turns if str(t).strip()]
            if len(turns) >= 2:
                q["turns"] = turns
                q["eval_turn"] = "last"
            else:
                q.pop("turns", None)
                q.pop("eval_turn", None)
        else:
            q.pop("turns", None)
            q.pop("eval_turn", None)
        cleaned.append(q)

    if errors:
        return {"ok": False, "errors": errors}
    if not cleaned:
        return {"ok": False, "errors": ["题目列表为空"]}

    golden = json.loads(GOLDEN_FILE.read_text(encoding="utf-8"))
    # 备份原文件（保留最近 5 份）
    backup_dir = GOLDEN_FILE.parent
    stamp = time.strftime("%Y%m%d-%H%M%S")
    backup = backup_dir / f"golden_questions.backup-{stamp}.json"
    backup.write_text(GOLDEN_FILE.read_text(encoding="utf-8"), encoding="utf-8")
    old_backups = sorted(backup_dir.glob("golden_questions.backup-*.json"))
    for f in old_backups[:-5]:
        f.unlink()

    # 重算 _meta 统计
    meta = golden.get("_meta", {})
    comp = {}
    for q in cleaned:
        comp[q["category"]] = comp.get(q["category"], 0) + 1
    meta["total"] = len(cleaned)
    meta["composition"] = comp
    meta["last_edited"] = stamp + " (eval-ui)"
    golden["_meta"] = meta
    golden["questions"] = cleaned

    GOLDEN_FILE.write_text(
        json.dumps(golden, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    return {"ok": True, "total": len(cleaned), "backup": backup.name}

_state = {
    "proc": None,
    "started_at": None,
    "finished_at": None,
    "subset": None,
    "returncode": None,
}
_lock = threading.Lock()


def _passed(r):
    return r is not None and r.get("label") == "Pass"


def load_results(path=None):
    """解析 results.jsonl → 记分卡 + 混淆矩阵 + 每题明细（口径同 08 Phase D）。"""
    path = path or RESULTS_FILE
    if not os.path.exists(path):
        return {"available": False}
    rows = []
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.strip()
            if line:
                try:
                    rows.append(json.loads(line))
                except Exception:
                    pass
    if not rows:
        return {"available": False}

    by_q, meta = defaultdict(dict), {}
    for r in rows:
        by_q[r["id"]][r["evaluator"]] = r
        meta[r["id"]] = r

    acc_qs = [q for q, m in meta.items() if m["category"] in ACC_CATS]
    red = [q for q, m in meta.items() if m["category"] == "redline"]

    acc_pass = sum(1 for q in acc_qs if _passed(by_q[q].get("accuracy")))
    int_pass = sum(1 for q in by_q if _passed(by_q[q].get("intent")))
    comp_pass = sum(1 for q in red if _passed(by_q[q].get("compliance")))

    def metric(name, passed, total):
        rate = (passed / total) if total else None
        return {
            "name": name,
            "passed": passed,
            "total": total,
            "rate": round(rate, 4) if rate is not None else None,
            "target": TARGETS[name],
            "ok": (rate is not None and rate >= TARGETS[name]) if total else None,
        }

    scorecard = [
        metric("accuracy", acc_pass, len(acc_qs)),
        metric("intent", int_pass, len(by_q)),
        metric("compliance", comp_pass, len(red)),
    ]

    confusion = defaultdict(int)
    for q, evals in by_q.items():
        r = evals.get("intent")
        if not r:
            continue
        m = re.search(r"detected_intent=(\w+)", r.get("explanation") or "")
        detected = m.group(1) if m else "unknown"
        confusion[(meta[q]["expected_intent"], detected)] += 1

    details = []
    for q in sorted(by_q):
        m = meta[q]
        evals = {}
        q_fail = False
        for ev in ("accuracy", "intent", "compliance"):
            r = by_q[q].get(ev)
            if not r:
                continue
            evals[ev] = {
                "value": r.get("value"),
                "label": r.get("label"),
                "explanation": (r.get("explanation") or "")[:500],
            }
        if (m["category"] in ACC_CATS and not _passed(by_q[q].get("accuracy"))) \
           or (m["category"] == "redline" and not _passed(by_q[q].get("compliance"))) \
           or not _passed(by_q[q].get("intent")):
            q_fail = True
        details.append({
            "id": q,
            "category": m["category"],
            "language": m["language"],
            "question": (m.get("question") or "")[:200],
            "expected_intent": m.get("expected_intent"),
            "response": (m.get("response") or "")[:3000],
            "failed": q_fail,
            "evals": evals,
        })

    return {
        "available": True,
        "scorecard": scorecard,
        "confusion": [
            {"expected": e, "detected": d, "count": n, "match": e == d}
            for (e, d), n in sorted(confusion.items())
        ],
        "details": details,
        "fails": sorted(d["id"] for d in details if d["failed"]),
        "results_mtime": os.path.getmtime(path),
    }


def list_history():
    """历史评测清单：每个归档文件算一条，附三指标概要（倒序=最新在前）。"""
    runs = []
    for f in sorted(HISTORY_DIR.glob("*.jsonl"),
                    key=lambda p: p.stat().st_mtime, reverse=True):
        data = load_results(str(f))
        if not data.get("available"):
            continue
        runs.append({
            "name": f.name,
            "mtime": f.stat().st_mtime,
            "n_questions": len(data["details"]),
            "subset": "-subset" in f.name,
            "scorecard": data["scorecard"],
        })
    return {"runs": runs}


def start_run(subset):
    with _lock:
        proc = _state["proc"]
        if proc is not None and proc.poll() is None:
            return False, "评估正在运行中，请等待完成"
        cmd = ["bash", str(PROJECT / "08-run-eval.sh")]
        if subset:
            cmd += ["--subset", subset]
        logf = open(LOG_FILE, "w")
        try:
            p = subprocess.Popen(
                cmd, cwd=str(PROJECT),
                stdout=logf, stderr=subprocess.STDOUT,
                stdin=subprocess.DEVNULL,
            )
        except Exception as e:
            logf.close()
            return False, str(e)
        _state.update(
            proc=p, started_at=time.time(), finished_at=None,
            subset=subset or "(全量 48 题)", returncode=None,
        )
        return True, "started"


def get_status():
    with _lock:
        proc = _state["proc"]
        running = proc is not None and proc.poll() is None
        if proc is not None and not running and _state["returncode"] is None:
            _state["returncode"] = proc.returncode
            _state["finished_at"] = time.time()

        log_tail = ""
        if os.path.exists(LOG_FILE):
            try:
                with open(LOG_FILE, "r", encoding="utf-8", errors="replace") as f:
                    log_tail = "".join(f.readlines()[-80:])
            except Exception:
                pass

        # 进度：Phase A 的 "[i/N]" 标记 + Phase C 的已评条数
        progress = {}
        m = re.findall(r"─── \[(\d+)/(\d+)\]", log_tail)
        if m:
            progress = {"current": int(m[-1][0]), "total": int(m[-1][1])}

        return {
            "running": running,
            "subset": _state["subset"],
            "started_at": _state["started_at"],
            "elapsed": round(time.time() - _state["started_at"]) if _state["started_at"] else None,
            "returncode": _state["returncode"],
            "log_tail": log_tail,
            "progress": progress,
        }


class Handler(BaseHTTPRequestHandler):
    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            self._send(200, (HERE / "index.html").read_bytes(), "text/html; charset=utf-8")
        elif self.path == "/golden":
            try:
                golden = json.loads(GOLDEN_FILE.read_text(encoding="utf-8"))
                # 返回完整题目对象（编辑器需要全部字段并原样回传，未知字段得以保留）
                self._send(200, json.dumps(
                    {"meta": golden.get("_meta", {}),
                     "questions": golden["questions"]}, ensure_ascii=False))
            except Exception as e:
                self._send(500, json.dumps({"error": str(e)}))
        elif self.path == "/status":
            self._send(200, json.dumps(get_status(), ensure_ascii=False))
        elif self.path == "/results":
            self._send(200, json.dumps(load_results(), ensure_ascii=False))
        elif self.path == "/history":
            self._send(200, json.dumps(list_history(), ensure_ascii=False))
        elif self.path.startswith("/history/"):
            # 防路径穿越：只取 basename 且必须真实存在于 history 目录
            name = os.path.basename(self.path[len("/history/"):])
            target = HISTORY_DIR / name
            if target.is_file() and target.suffix == ".jsonl":
                self._send(200, json.dumps(load_results(str(target)), ensure_ascii=False))
            else:
                self._send(404, json.dumps({"error": "run not found"}))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        try:
            length = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(length).decode("utf-8")) if length else {}
        except Exception as e:
            self._send(400, json.dumps({"error": str(e)}))
            return
        if self.path == "/run":
            try:
                subset = str(req.get("subset", "")).strip()
                ok, msg = start_run(subset)
                self._send(200 if ok else 409, json.dumps({"ok": ok, "message": msg}, ensure_ascii=False))
            except Exception as e:
                self._send(500, json.dumps({"error": str(e)}))
        elif self.path == "/golden":
            try:
                result = save_golden(req.get("questions", []))
                self._send(200 if result["ok"] else 400, json.dumps(result, ensure_ascii=False))
            except Exception as e:
                self._send(500, json.dumps({"error": str(e)}))
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def log_message(self, fmt, *args):
        print(f"  [eval-ui] {fmt % args}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8081)
    args = parser.parse_args()

    if not GOLDEN_FILE.exists():
        print(f"❌ 黄金集不存在: {GOLDEN_FILE}")
        raise SystemExit(1)

    server = HTTPServer(("127.0.0.1", args.port), Handler)  # 仅本机，勿改绑 0.0.0.0
    print("=========================================")
    print("Tank 500 Eval Console (local demo)")
    print(f"  URL:     http://127.0.0.1:{args.port}")
    print(f"  Project: {PROJECT}")
    print("  Ctrl+C to stop")
    print("=========================================")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
