#!/usr/bin/env python3
"""Characterize installed Magpie with disposable, synthetic loopback sources.

No vendor account is read or called. Magpie uses a temporary XDG profile with
account discovery disabled, separate loopback ports and no real provider keys.
Existing providers and agent choices stay with their owners.
"""
import http.cookiejar
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
import argparse
import collections
import json
import os
from pathlib import Path
import secrets
import socket
import subprocess
import tempfile
import threading
import time
import urllib.error
import urllib.request
import uuid


KEY_A = "loongpass-synthetic-account-a"
KEY_B = "loongpass-synthetic-account-b"
SHARED = "pool-probe-chat"
MESSAGES = "pool-probe-messages"


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--magpie", default="/Applications/magpie.app/Contents/MacOS/magpie")
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--automatic-api", action="store_true", help="Use native per-protocol catalog discovery without model API overrides")
    parser.add_argument("--claude", help="Also verify single-send failures with this Claude Code executable")
    args = parser.parse_args()
    provider = "loongpass-pool-probe-" + uuid.uuid4().hex[:10]
    events = []
    state = {"case": "normal"}
    lock = threading.Lock()
    profile = tempfile.TemporaryDirectory(prefix="loongpass-magpie-pool-")
    environment = os.environ.copy()
    for kind in ("CONFIG", "DATA", "STATE"):
        environment[f"XDG_{kind}_HOME"] = str(Path(profile.name) / kind.lower())
    environment["MAGPIE_NO_ACCOUNTS"] = "1"
    environment["MAGPIE_WEB_KEY"] = secrets.token_urlsafe(24)
    def free_port():
        with socket.socket() as listener:
            listener.bind(("127.0.0.1", 0))
            return listener.getsockname()[1]
    gateway = "http://127.0.0.1:" + str(free_port())
    web = "http://127.0.0.1:" + str(free_port())
    environment["MAGPIE_ADDR"] = gateway.removeprefix("http://")
    process = None
    process_log = tempfile.TemporaryFile()

    def cli(*words):
        result = subprocess.run([args.magpie, *words], env=environment, capture_output=True, text=True, timeout=30)
        if result.returncode:
            # stderr may include proxy settings: keep diagnostics bounded to the
            # CLI's last error, never retain a configuration dump.
            errors = [line for line in result.stderr.splitlines() if line.startswith("magpie:")]
            raise RuntimeError("CLI " + " ".join(words[:2]) + " failed: " + (errors[-1] if errors else str(result.returncode)))
        return result.stdout

    class Handler(BaseHTTPRequestHandler):
        protocol_version = "HTTP/1.1"

        def log_message(self, *_):
            pass

        def reply(self, status, value, content_type="application/json"):
            raw = json.dumps(value, ensure_ascii=False).encode() if not isinstance(value, bytes) else value
            self.send_response(status)
            self.send_header("Content-Type", content_type)
            self.send_header("Content-Length", str(len(raw)))
            self.send_header("x-should-retry", "false")
            self.end_headers()
            self.wfile.write(raw)

        def key(self):
            bearer = self.headers.get("Authorization", "")
            key = bearer[7:] if bearer.startswith("Bearer ") else self.headers.get("x-api-key", "")
            return key if key in (KEY_A, KEY_B) else None

        def do_GET(self):
            key = self.key()
            if not key:
                return self.reply(401, {"error": {"message": "synthetic key required"}})
            if self.path not in ("/chat/v1/models", "/anthropic/v1/models", "/anthropic/models"):
                return self.reply(404, {"error": {"message": "no synthetic endpoint"}})
            ids = [MESSAGES] if self.path.startswith("/anthropic") else [SHARED, "pool-probe-only-" + ("a" if key == KEY_A else "b")]
            with lock:
                events.append({"operation": "models", "key": "a" if key == KEY_A else "b", "path": self.path})
            self.reply(200, {"object": "list", "data": [{"id": model, "object": "model", "owned_by": "synthetic", "supported_endpoints": ["/messages" if model == MESSAGES else "/chat/completions"], "native_endpoints": ["/messages" if model == MESSAGES else "/chat/completions"]} for model in ids]})

        def do_POST(self):
            key = self.key()
            if not key:
                return self.reply(401, {"error": {"message": "synthetic key required"}})
            body = json.loads(self.rfile.read(int(self.headers.get("Content-Length", "0"))))
            with lock:
                case = state["case"]
                events.append({"operation": "call", "case": case, "key": "a" if key == KEY_A else "b", "model": body.get("model"), "path": self.path, "stream": body.get("stream"), "tool_count": len(body.get("tools", []))})
            if case == "http-error":
                return self.reply(502, {"type": "error", "error": {"type": "api_error", "message": "synthetic uncertain response"}})
            anthropic = self.path.startswith("/anthropic/")
            model = body.get("model")
            expected_path = "/anthropic/v1/messages" if anthropic else "/chat/v1/chat/completions"
            if self.path.split("?")[0] != expected_path:
                return self.reply(400, {"error": {"message": "wrong native protocol path"}})
            if model == "pool-probe-only-a" and key != KEY_A or model == "pool-probe-only-b" and key != KEY_B:
                return self.reply(400, {"error": {"message": "account model isolation broken"}})
            text = "synthetic " + ("a" if key == KEY_A else "b")
            if body.get("stream"):
                self.send_response(200)
                self.send_header("Content-Type", "text/event-stream")
                self.send_header("Connection", "close")
                self.send_header("x-should-retry", "false")
                self.end_headers()
                if anthropic:
                    chunks = [
                        ("message_start", {"type": "message_start", "message": {"id": "msg_synthetic", "type": "message", "role": "assistant", "model": model, "content": [], "stop_reason": None, "usage": {"input_tokens": 7, "output_tokens": 0}}}),
                        ("content_block_start", {"type": "content_block_start", "index": 0, "content_block": {"type": "text", "text": ""}}),
                        ("content_block_delta", {"type": "content_block_delta", "index": 0, "delta": {"type": "text_delta", "text": text}}),
                    ]
                    for event, value in chunks:
                        self.wfile.write(("event: " + event + "\ndata: " + json.dumps(value) + "\n\n").encode())
                    self.wfile.flush()
                    if case != "cut-stream":
                        for event, value in [
                            ("content_block_stop", {"type": "content_block_stop", "index": 0}),
                            ("message_delta", {"type": "message_delta", "delta": {"stop_reason": "end_turn", "stop_sequence": None}, "usage": {"output_tokens": 3}}),
                            ("message_stop", {"type": "message_stop"}),
                        ]:
                            self.wfile.write(("event: " + event + "\ndata: " + json.dumps(value) + "\n\n").encode())
                else:
                    delta = {"role": "assistant", "content": text}
                    if case == "tool":
                        if not any(t.get("function", {}).get("name") == "echo_probe" for t in body.get("tools", [])):
                            raise AssertionError("tool declaration was not converted to Chat")
                        delta = {"role": "assistant", "tool_calls": [{"index": 0, "id": "call_synthetic", "type": "function", "function": {"name": "echo_probe", "arguments": '{"value":"中文"}'}}]}
                    chunk = {"id": "chatcmpl_synthetic", "object": "chat.completion.chunk", "created": 1, "model": model, "choices": [{"index": 0, "delta": delta, "finish_reason": None}]}
                    self.wfile.write(("data: " + json.dumps(chunk) + "\n\n").encode())
                    self.wfile.flush()
                    if case != "cut-stream":
                        chunk["choices"] = [{"index": 0, "delta": {}, "finish_reason": "tool_calls" if case == "tool" else "stop"}]
                        chunk["usage"] = {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10}
                        self.wfile.write(("data: " + json.dumps(chunk) + "\n\ndata: [DONE]\n\n").encode())
                self.wfile.flush()
                self.close_connection = True
                return
            if anthropic:
                return self.reply(200, {"id": "msg_synthetic", "type": "message", "role": "assistant", "model": model, "content": [{"type": "text", "text": text}], "stop_reason": "end_turn", "stop_sequence": None, "usage": {"input_tokens": 7, "output_tokens": 3}})
            message = {"role": "assistant", "content": text}
            finish = "stop"
            if case == "tool":
                message = {"role": "assistant", "content": None, "tool_calls": [{"id": "call_synthetic", "type": "function", "function": {"name": "echo_probe", "arguments": '{"value":"中文"}'}}]}
                finish = "tool_calls"
            self.reply(200, {"id": "chatcmpl_synthetic", "object": "chat.completion", "created": 1, "model": model, "choices": [{"index": 0, "message": message, "finish_reason": finish}], "usage": {"prompt_tokens": 7, "completion_tokens": 3, "total_tokens": 10}})

    server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    base = "http://127.0.0.1:" + str(server.server_port)
    created = False
    result = {"provider": provider, "synthetic": True, "vendor_calls": 0, "checks": {}}
    try:
        version = cli("--version").strip()
        result["magpie"] = version
        cli("provider", "add", provider, "id=" + provider, "url=" + base + "/chat/v1", "anthropic=" + base + "/anthropic", "key=" + KEY_A,
            "models=" + ",".join([SHARED, MESSAGES, "pool-probe-only-a", "pool-probe-only-b"]), "routing=rotate", "errors=pass", "patience=off")
        created = True
        process = subprocess.Popen([args.magpie, "serve", "--web=" + web.removeprefix("http://")], env=environment, stdout=process_log, stderr=process_log)
        control = urllib.request.build_opener(urllib.request.ProxyHandler({}), urllib.request.HTTPCookieProcessor(http.cookiejar.CookieJar()))
        ready = False
        for _ in range(100):
            if process.poll() is not None:
                raise RuntimeError("isolated Magpie exited before readiness")
            try:
                with control.open(web + "/?k=" + environment["MAGPIE_WEB_KEY"], timeout=1) as response:
                    ready = response.status == 200
                if ready:
                    break
            except (OSError, urllib.error.URLError):
                time.sleep(0.1)
        if not ready:
            raise RuntimeError("isolated Magpie web did not become ready")
        request = urllib.request.Request(web + "/api/keys/add", data=json.dumps({"id": provider, "name": "synthetic b", "key": KEY_B}).encode(), headers={"Content-Type": "application/json", "Origin": web})
        with control.open(request, timeout=10) as response:
            if response.status != 200:
                raise RuntimeError("native key-add API refused the synthetic key")
        cli("provider", "refresh", provider)
        if not args.automatic_api:
            for model, api in [(SHARED, "chat"), (MESSAGES, "anthropic"), ("pool-probe-only-a", "chat"), ("pool-probe-only-b", "chat")]:
                cli("model", "api", provider + "/" + model, api)
        result["automatic_protocol_discovery"] = args.automatic_api
        # Issued keys are scoped at creation and expire. Removing this unique
        # provider makes the key unable to name any source after cleanup.
        issued = json.loads(cli("gateway-key", "issue", "--ttl", "5m", "--name", provider, "--models", provider + "/*", "--json"))
        caller = issued.get("key") or issued.get("secret")
        if not caller:
            raise RuntimeError("scoped test caller key was not returned")
        opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))

        def ask(model, *, stream=False, tools=False, case="normal"):
            with lock:
                state["case"] = case
            body = {"model": provider + "/" + model, "max_tokens": 128, "stream": stream,
                    "messages": [{"role": "user", "content": "Synthetic probe " + uuid.uuid4().hex}]}
            if tools:
                body["tools"] = [{"name": "echo_probe", "description": "Echo a synthetic value", "input_schema": {"type": "object", "properties": {"value": {"type": "string"}}, "required": ["value"]}}]
            request = urllib.request.Request(gateway + "/v1/messages", data=json.dumps(body).encode(), headers={"Content-Type": "application/json", "x-api-key": caller, "anthropic-version": "2023-06-01", "User-Agent": "loongpass-synthetic-probe"})
            try:
                response = opener.open(request, timeout=20)
            except urllib.error.HTTPError as error:
                response = error
            with response:
                return response.status, response.read().decode()

        for model in [SHARED, MESSAGES]:
            status, raw = ask(model)
            reply = json.loads(raw)
            assert status == 200 and reply.get("type") == "message", (model, status)
            assert reply["content"][0]["text"] in ("synthetic a", "synthetic b"), model
            result["checks"][model + "-text"] = "passed"
        for model in [SHARED, MESSAGES]:
            status, raw = ask(model, stream=True)
            assert status == 200 and "content_block_delta" in raw and "message_stop" in raw, model
            result["checks"][model + "-stream"] = "passed"
        with lock:
            before = len(events)
        for _ in range(6):
            status, _ = ask(SHARED)
            assert status == 200, status
        with lock:
            calls = [e for e in events[before:] if e["operation"] == "call"]
        counts = collections.Counter(e["key"] for e in calls)
        assert set(counts) == {"a", "b"} and len(calls) == 6, dict(counts)
        result["checks"]["rotation"] = dict(counts)
        for name, expected in [("pool-probe-only-a", "a"), ("pool-probe-only-b", "b")]:
            with lock:
                before = len(events)
            status, raw = ask(name)
            with lock:
                calls = [e for e in events[before:] if e["operation"] == "call"]
            assert status == 200 and len(calls) == 1 and calls[0]["key"] == expected, name
        result["checks"]["per-key-models"] = "passed"
        status, raw = ask(SHARED, tools=True, case="tool")
        reply = json.loads(raw)
        tools = [c for c in reply.get("content", []) if c.get("type") == "tool_use"]
        assert len(tools) == 1, {"status": status, "reply": reply}
        tool = tools[0]
        assert status == 200 and tool["name"] == "echo_probe" and tool["input"] == {"value": "中文"}
        result["checks"]["chat-tool-conversion"] = "passed"
        for case, stream in [("http-error", False), ("cut-stream", True)]:
            with lock:
                before = len(events)
            status, raw = ask(SHARED, stream=stream, case=case)
            with lock:
                calls = [e for e in events[before:] if e["operation"] == "call"]
            assert len(calls) == 1, (case, len(calls))
            if not stream:
                assert status == 502, (case, status)
            result["checks"][case + "-single-send"] = "passed"
        if args.claude:
            child_env = {k: v for k, v in environment.items() if not k.startswith(("ANTHROPIC_", "CLAUDE_CODE_"))}
            child_env.update(ANTHROPIC_BASE_URL=gateway, ANTHROPIC_API_KEY=caller,
                             CLAUDE_CONFIG_DIR=str(Path(profile.name) / "claude"),
                             CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC="1", DISABLE_TELEMETRY="1",
                             CLAUDE_CODE_MAX_RETRIES="0")
            child_env["CLAUDE_CODE_DISABLE_NONSTREAMING_FALLBACK"] = "1"
            for case in ("http-error", "cut-stream"):
                with lock:
                    state["case"] = case
                    before = len(events)
                command = [args.claude, "--bare", "-p", "--no-session-persistence", "--setting-sources", "",
                           "--strict-mcp-config", "--mcp-config", '{"mcpServers":{}}', "--tools", "",
                           "--model", provider + "/" + MESSAGES, "--max-turns", "1",
                           "--system-prompt", "You are a synthetic protocol test.", "--output-format", "json", "Reply with synthetic marker."]
                try:
                    completed = subprocess.run(command, env=child_env, cwd=profile.name, capture_output=True, text=True, timeout=30)
                    result["checks"]["claude-" + case + "-exit"] = completed.returncode
                except subprocess.TimeoutExpired:
                    result["checks"]["claude-" + case + "-exit"] = "timeout"
                with lock:
                    calls = [e for e in events[before:] if e["operation"] == "call"]
                result["checks"]["claude-" + case + "-sends"] = len(calls)
                assert len(calls) == 1, (case, len(calls))
        result["status"] = "passed"
        print(json.dumps({"phase": "verified", "checks": result["checks"]}), flush=True)
    finally:
        if process is not None:
            process.terminate()
            try:
                process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                process.kill()
                process.wait(timeout=5)
        if created:
            cli("provider", "rm", provider)
            result["temporary_provider_removed"] = True
        server.shutdown()
        server.server_close()
        thread.join(timeout=5)
        process_log.close()
        profile.cleanup()
        result["temporary_profile_removed"] = True
        result["synthetic_calls"] = [event for event in events if event["operation"] == "call"]
        args.output.parent.mkdir(parents=True, exist_ok=True)
        args.output.write_text(json.dumps(result, ensure_ascii=False, indent=2) + "\n")
        print("Synthetic probe cleaned up; report: " + str(args.output), flush=True)


if __name__ == "__main__":
    main()
