#!/usr/bin/env python3
"""tank500-agent 本地聊天页代理（docs/design.md §2.5）。

仅两个路由：
  GET  /      → 返回 index.html
  POST /chat  → {message, session_id, actor_id} → Agent 回复

实现说明：不直接用 boto3 调 InvokeAgentRuntime——runtime 的 payload JSON 契约
由 agentcore CLI 内部定义（版本间可能变化），猜 schema 有兼容风险。这里子进程
调用 `npx agentcore invoke`，与 05-test-conversation.sh 走完全相同的路径，
行为保证一致。代价是每次请求多 1-2 秒 node 启动时间，对本地 demo 可接受。

安全边界：仅绑定 127.0.0.1、无鉴权，定位是本机演示工具。
不要部署到公网或改绑 0.0.0.0。

用法：
  python3 chat-ui/server.py [--port 8080] [--workdir ~/workshop/tank500assistant]
"""

import argparse
import json
import os
import re
import subprocess
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

HERE = Path(__file__).parent
NOISE_PATTERNS = [
    re.compile(r"PythonDeprecationWarning"),
    re.compile(r"warnings\.warn"),
    re.compile(r"boto3 will no longer"),
    re.compile(r"upgrade to Python"),
    re.compile(r"More information can"),
    re.compile(r"^npm "),
    re.compile(r"^\s*$"),
]


def clean_output(text: str) -> str:
    lines = [
        l for l in text.splitlines()
        if not any(p.search(l) for p in NOISE_PATTERNS)
    ]
    return "\n".join(lines).strip()


class Handler(BaseHTTPRequestHandler):
    workdir = None  # set in main()

    def _send(self, code, body, ctype="application/json; charset=utf-8"):
        data = body if isinstance(body, bytes) else body.encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", ctype)
        self.send_header("Content-Length", str(len(data)))
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if self.path in ("/", "/index.html"):
            html = (HERE / "index.html").read_bytes()
            self._send(200, html, "text/html; charset=utf-8")
        else:
            self._send(404, json.dumps({"error": "not found"}))

    def do_POST(self):
        if self.path != "/chat":
            self._send(404, json.dumps({"error": "not found"}))
            return
        try:
            length = int(self.headers.get("Content-Length", 0))
            req = json.loads(self.rfile.read(length).decode("utf-8"))
            message = str(req.get("message", "")).strip()
            session_id = str(req.get("session_id", "")).strip() or "chat-ui-default"
            actor_id = str(req.get("actor_id", "")).strip() or "demo-user-001"
            if not message:
                self._send(400, json.dumps({"error": "message is required"}))
                return
            self._stream_invoke(message, session_id, actor_id)
        except Exception as e:
            try:
                self._send(500, json.dumps({"error": str(e)}))
            except Exception:
                pass

    def _stream_invoke(self, message, session_id, actor_id):
        """流式转发 agentcore invoke --stream 的输出（逐行过滤噪音与页脚）。

        不带 Content-Length，用连接关闭标记结束 —— 浏览器 fetch 的
        ReadableStream 可以边到边读。行级过滤策略：一行确认不是噪音/页脚
        前缀后立即透传（长于 24 字符且不匹配任何已知前缀时提前放行，
        保证 token 级流畅度）。
        """
        NOISE_PREFIX = ("npm ", "Session:", "To resume:", "Log:")

        self.send_response(200)
        self.send_header("Content-Type", "text/plain; charset=utf-8")
        self.send_header("Cache-Control", "no-cache")
        # 无 Content-Length 的流式响应必须显式关闭连接来标记结束，
        # 否则客户端会一直等（keep-alive 挂住）
        self.send_header("Connection", "close")
        self.close_connection = True
        self.end_headers()

        proc = subprocess.Popen(
            ["npx", "agentcore", "invoke",
             "--session-id", session_id,
             "--actor-id", actor_id,
             "--stream", message],
            cwd=self.workdir,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            stdin=subprocess.DEVNULL, text=True, bufsize=0,
        )
        linebuf = ""
        passthrough = False   # 当前行已判定为正文，逐字符透传
        footer = False        # 进入页脚（Session:/To resume:/Log:）后全部丢弃
        try:
            while True:
                ch = proc.stdout.read(1)
                if ch == "":
                    break
                if footer:
                    continue
                if passthrough:
                    self.wfile.write(ch.encode("utf-8"))
                    self.wfile.flush()
                    if ch == "\n":
                        passthrough = False
                        linebuf = ""
                    continue
                linebuf += ch
                if ch == "\n":
                    line = linebuf
                    linebuf = ""
                    if line.startswith(("Session:", "To resume:", "Log:")):
                        footer = True
                        continue
                    if any(p.search(line) for p in NOISE_PATTERNS[:5]) or line.startswith("npm "):
                        continue
                    self.wfile.write(line.encode("utf-8"))
                    self.wfile.flush()
                elif len(linebuf) > 24 and not any(
                    pref.startswith(linebuf[:len(pref)]) or linebuf.startswith(pref)
                    for pref in NOISE_PREFIX
                ):
                    # 足够长且不可能是噪音/页脚前缀 → 提前放行剩余部分
                    self.wfile.write(linebuf.encode("utf-8"))
                    self.wfile.flush()
                    passthrough = True
            proc.wait(timeout=10)
        except BrokenPipeError:
            proc.kill()
        finally:
            try:
                proc.kill()
            except Exception:
                pass

    def log_message(self, fmt, *args):
        print(f"  [chat-ui] {fmt % args}")


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--port", type=int, default=8080)
    parser.add_argument(
        "--workdir",
        default=os.path.expanduser("~/workshop/tank500assistant"),
        help="agentcore Harness 项目目录（默认 ~/workshop/tank500assistant）",
    )
    args = parser.parse_args()

    workdir = os.path.expanduser(args.workdir)
    if not os.path.isdir(workdir):
        print(f"❌ Harness 项目目录不存在: {workdir}")
        print("   请先运行 03-deploy.sh，或用 --workdir 指定。")
        raise SystemExit(1)

    Handler.workdir = workdir
    server = HTTPServer(("127.0.0.1", args.port), Handler)  # 仅本机，勿改绑 0.0.0.0
    print("=========================================")
    print("Tank 500 Chat UI (local demo)")
    print(f"  URL:     http://127.0.0.1:{args.port}")
    print(f"  Workdir: {workdir}")
    print("  Ctrl+C to stop")
    print("=========================================")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nbye")


if __name__ == "__main__":
    main()
