#!/usr/bin/env python3
"""ACP stand-in for the composer live test.

initialize lists one model. The next line is the full catalog, including a third-party model,
then an empty update that must not erase it.
"""
import json
import sys


def send(message):
    sys.stdout.write(json.dumps(message) + "\n")
    sys.stdout.flush()


for line in sys.stdin:
    message = json.loads(line)
    method, request_id = message.get("method"), message.get("id")
    result = {}
    if method == "initialize":
        result = {"protocolVersion": 1, "_meta": {"modelState": {
            "currentModelId": "grok-4.7",
            "availableModels": [
                {"modelId": "grok-4.7", "name": "Grok 4.7", "_meta": {
                    "supportsReasoningEffort": True, "reasoningEffort": "high",
                    "reasoningEfforts": [{"value": "low", "label": "Low"}, {"value": "high", "label": "High"}]}},
            ]}}}
    elif method == "session/new":
        result = {"sessionId": "ui-1", "configOptions": [
            {"id": "model", "currentValue": "grok-4.7", "options": [{"value": "grok-4.7", "name": "Grok 4.7"}]},
            {"id": "reasoning_effort", "currentValue": "low", "options": [{"value": "low", "name": "Low"}]},
        ]}
    elif method == "session/prompt":
        send({"jsonrpc": "2.0", "method": "session/update", "params": {
            "sessionId": message["params"]["sessionId"],
            "update": {"sessionUpdate": "agent_message_chunk", "content": {"type": "text", "text": "ok"}}}})
        result = {"stopReason": "end_turn", "_meta": {"modelId": "grok-4.7"}}
    elif method == "session/set_config_option":
        result = {"configOptions": []}
    if request_id is not None:
        send({"jsonrpc": "2.0", "id": request_id, "result": result})
    if method == "initialize":
        send({"jsonrpc": "2.0", "method": "_x.ai/models/update", "params": {
            "currentModelId": "grok-4.7",
            "availableModels": [
                {"modelId": "grok-4.7", "name": "Grok 4.7", "_meta": {
                    "group": "Grok", "supportsReasoningEffort": True, "reasoningEffort": "high",
                    "reasoningEfforts": [{"value": "low", "label": "Low"}, {"value": "high", "label": "High"}]}},
                {"name": "malformed"},
                {"modelId": "claude-opus-5-5", "name": "Claude Opus 5.5", "_meta": {
                    "group": "Anthropic", "supportsReasoningEffort": True, "reasoningEffort": "medium",
                    "reasoningEfforts": [{"value": "medium", "label": "Medium"}, {"value": "max", "label": "Max"}]}},
                {"modelId": "gemini-4-argon", "name": "Gemini 4 Argon", "_meta": {"vendor": {"displayName": "Google"}}},
            ]}})
        send({"jsonrpc": "2.0", "method": "_x.ai/models/update", "params": {"availableModels": []}})
