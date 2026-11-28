import json, sys
# Minimal stdio MCP server for tests: "echo", a failing tool, a picture, and an A2UI card (layout resource + data).
reads = 0
CARD = [{"version": "1.0", "createSurface": {"surfaceId": "card", "catalogId": "https://a2ui.org/specification/v1_0/catalogs/basic/catalog.json"}},
        {"version": "1.0", "updateComponents": {"surfaceId": "card", "components": [{"id": "root", "component": "Text", "text": {"@path": "/title"}}]}}]
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
            result = {"tools": [{"name": "echo", "description": "Echo text", "inputSchema": {"type": "object", "properties": {"text": {"type": "string"}}}, "annotations": {"readOnlyHint": True}}], "nextCursor": "p2"}
        else:
            result = {"tools": [{"name": "boom.fail", "description": "Always fails", "inputSchema": {"type": "object"}},
                                {"name": "shot", "description": "A picture", "inputSchema": {"type": "object"}},
                                {"name": "card", "description": "A card", "inputSchema": {"type": "object"},
                                 "_meta": {"ui": {"resourceUri": "a2ui://card", "mimeType": "application/a2ui+json"}}}]}
    elif method == "resources/read":
        reads += 1
        result = {"contents": [{"uri": msg["params"]["uri"], "mimeType": "application/a2ui+json", "text": json.dumps(CARD)}]}
    elif method == "tools/call":
        name = msg["params"]["name"]
        if name == "echo":
            # ask the client something first, like real servers sometimes do
            print(json.dumps({"jsonrpc": "2.0", "id": 99, "method": "ping"}), flush=True)
            result = {"content": [{"type": "text", "text": "echo: " + msg["params"]["arguments"].get("text", "")}]}
        elif name == "shot":
            # 1x1 PNG plus a caption, like Playwright's browser_take_screenshot
            png = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mNk+M9QDwADhgGAWjR9awAAAABJRU5ErkJggg=="
            result = {"content": [{"type": "text", "text": "Took a screenshot"}, {"type": "image", "data": png, "mimeType": "image/png"}]}
        elif name == "card":
            data = {"version": "1.0", "updateDataModel": {"surfaceId": "card", "path": "/title", "value": "Disk 41%% (read %d)" % reads}}
            result = {"content": [{"type": "text", "text": "Disk is at 41%"},
                                  {"type": "resource", "resource": {"uri": "a2ui://card/data", "mimeType": "application/a2ui+json", "text": json.dumps(data)}}]}
        else:
            result = {"content": [{"type": "text", "text": "it broke"}], "isError": True}
    else:
        print(json.dumps({"jsonrpc": "2.0", "id": mid, "error": {"code": -32601, "message": "nope"}}), flush=True)
        continue
    print(json.dumps({"jsonrpc": "2.0", "id": mid, "result": result}), flush=True)
