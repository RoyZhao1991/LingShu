#!/usr/bin/env python3
"""最小 MCP stdio server(测试用):JSON-RPC over stdio(newline-delimited)。
支持 initialize / tools/list / tools/call。每次**进程启动**向 $MOCK_MCP_SPAWN_FILE 追加一行,
供测试断言『持久连接=进程只起一次』。"""
import sys, json, os

spawn_file = os.environ.get("MOCK_MCP_SPAWN_FILE")
if spawn_file:
    try:
        with open(spawn_file, "a") as f:
            f.write("start\n")
    except Exception:
        pass

for line in sys.stdin:
    line = line.strip()
    if not line:
        continue
    try:
        req = json.loads(line)
    except Exception:
        continue
    method = req.get("method")
    rid = req.get("id")
    if isinstance(method, str) and method.startswith("notifications/"):
        continue  # 通知无响应
    if method == "initialize":
        resp = {"jsonrpc": "2.0", "id": rid, "result": {
            "protocolVersion": "2024-11-05", "capabilities": {"tools": {}},
            "serverInfo": {"name": "mock-stdio", "version": "1"}}}
    elif method == "tools/list":
        resp = {"jsonrpc": "2.0", "id": rid, "result": {
            "tools": [{"name": "echo_stdio", "description": "回声(stdio)"}]}}
    elif method == "tools/call":
        resp = {"jsonrpc": "2.0", "id": rid, "result": {
            "content": [{"type": "text", "text": "stdio-ok"}], "isError": False}}
    else:
        resp = {"jsonrpc": "2.0", "id": rid, "error": {"code": -32601, "message": "unknown"}}
    sys.stdout.write(json.dumps(resp) + "\n")
    sys.stdout.flush()
