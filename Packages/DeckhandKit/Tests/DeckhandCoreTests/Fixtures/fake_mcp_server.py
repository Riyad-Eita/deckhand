import json, sys
# Minimal stdio MCP server for tests: one "echo" tool and one failing tool.
for line in sys.stdin:
    msg = json.loads(line)
    mid, method = msg.get("id"), msg.get("method")
    if mid is None:
        continue
    if method == "initialize":
        result = {"protocolVersion": msg["params"]["protocolVersion"], "capabilities": {"tools": {}},
                  "serverInfo": {"name": "fake", "version": "1"}, "instructions": "Use echo."}
    elif method == "tools/list":
        if msg.get("params", {}).get("cursor") is None:
            result = {"tools": [{"name": "echo", "description": "Echo text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}}], "nextCursor": "p2"}
        else:
            result = {"tools": [{"name": "boom.fail", "description": "Always fails", "inputSchema": {"type": "object"}}]}
    elif method == "tools/call":
        name = msg["params"]["name"]
        if name == "echo":
            # ask the client something first, like real servers sometimes do
            print(json.dumps({"jsonrpc": "2.0", "id": 99, "method": "ping"}), flush=True)
            result = {"content": [{"type": "text", "text": "echo: " + msg["params"]["arguments"].get("text", "")}]}
        else:
            result = {"content": [{"type": "text", "text": "it broke"}], "isError": True}
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}}), flush=True)
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}), flush=True)
