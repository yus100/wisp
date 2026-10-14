#!/usr/bin/env python3
"""A stand-in for `grok agent --always-approve stdio` that speaks just enough ACP for GrokAgentTests.

Prompt text selects a scenario:
  "hello"   streams two chunks and a tool call, then ends the turn
  "permit"  asks the client for permission first and echoes the chosen option
  "permit-always-only"  offers only an always-allow option, which the client must decline
  "fs"      sends a request the client does not support and echoes the error code
  "crash"   exits with status 3 mid-turn
FAKE_AGENT_HANG=1 makes it never answer `initialize`.
"""
import json
import os
import sys


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


def update(session_id, payload):
    send({"jsonrpc": "2.0", "method": "session/update", "params": {"sessionId": session_id, "update": payload}})


def chunk(session_id, text):
    update(session_id, {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": text}})


def read_reply():
    return json.loads(sys.stdin.readline())


def options(model):
    efforts = ["minimal", "low", "medium", "high", "xhigh"] if model.startswith("claude") else ["low", "high"]
    return [
        {"id": "model", "currentValue": model, "options": [{"value": "grok-test"}, {"value": "claude-test"}]},
        {"id": "reasoning_effort", "currentValue": "low", "options": [{"value": e} for e in efforts]},
        {"id": "some_flag", "currentValue": True, "options": []},
    ]


model = "grok-test"
for line in sys.stdin:
    message = json.loads(line)
    method, params, request_id = message.get("method"), message.get("params", {}), message.get("id")
    if method == "initialize" and os.environ.get("FAKE_AGENT_HANG"):
        continue
    if method == "initialize":
        send({"jsonrpc": "2.0", "id": request_id, "result": {"protocolVersion": 1, "_meta": {"modelState": {
            "currentModelId": "grok-test",
            "availableModels": [
                {"modelId": "grok-test", "name": "Grok Test",
                 "_meta": {"reasoningEffort": "high", "reasoningEfforts": [{"value": "low"}, {"value": "high"}]}},
                {"modelId": "claude-test", "name": "Claude Test", "_meta": {"reasoningEffort": "high", "reasoningEfforts": []}},
            ]}}}})
    elif method == "session/new":
        assert params["_meta"]["yoloMode"] is True
        send({"jsonrpc": "2.0", "id": request_id, "result": {"sessionId": "session-1", "configOptions": options(model)}})
    elif method == "session/set_config_option":
        if params["configId"] == "model":
            model = params["value"]
        send({"jsonrpc": "2.0", "id": request_id, "result": {"configOptions": options(model)}})
    elif method == "session/prompt":
        session_id = params["sessionId"]
        text = params["prompt"][0]["text"]
        if text == "crash":
            sys.exit(3)
        if text == "permit-always-only":
            send({"jsonrpc": "2.0", "id": "perm-2", "method": "session/request_permission", "params": {
                "sessionId": session_id, "options": [{"optionId": "always", "kind": "allow_always"}]}})
            chunk(session_id, "outcome:" + read_reply()["result"]["outcome"]["outcome"])
        elif text == "permit":
            send({"jsonrpc": "2.0", "id": "perm-1", "method": "session/request_permission", "params": {
                "sessionId": session_id, "options": [
                    {"optionId": "reject", "kind": "reject_once"},
                    {"optionId": "always", "kind": "allow_always"},
                    {"optionId": "once", "kind": "allow_once"}]}})
            chunk(session_id, "approved:" + read_reply()["result"]["outcome"]["optionId"])
        elif text == "fs":
            send({"jsonrpc": "2.0", "id": 99, "method": "fs/read_text_file", "params": {"path": "/etc/hosts"}})
            chunk(session_id, "error:" + str(read_reply()["error"]["code"]))
        else:
            chunk(session_id, "Hello ")
            update(session_id, {"sessionUpdate": "tool_call", "toolCallId": "t1", "title": "run_terminal_command",
                                "status": "pending", "rawInput": {"command": "ls ~", "timeout": 30}})
            update(session_id, {"sessionUpdate": "tool_call_update", "toolCallId": "t1", "status": "completed"})
            update(session_id, {"sessionUpdate": "plan", "entries": []})
            chunk(session_id, "world")
        send({"jsonrpc": "2.0", "id": request_id, "result": {"stopReason": "end_turn", "_meta": {"modelId": model}}})
    elif method == "session/load":
        send({"jsonrpc": "2.0", "id": request_id, "result": {}})
        chunk(params["sessionId"], "(replayed history)")
    elif method == "session/close":
        send({"jsonrpc": "2.0", "id": request_id, "result": None})
    elif method == "session/cancel":
        pass
    elif request_id is not None:
        send({"jsonrpc": "2.0", "id": request_id, "error": {"code": -32601, "message": "unknown method", "data": method}})
