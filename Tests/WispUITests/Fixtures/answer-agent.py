#!/usr/bin/env python3
import json
import pathlib
import sys
import time

root = pathlib.Path(__file__).parent
if 'agent' not in sys.argv:
    sys.exit(0)
partial = (root / 'partial.txt').read_text()
answer = (root / 'answer.txt').read_text()


def send(value):
    print(json.dumps({'jsonrpc': '2.0', **value}), flush=True)


def update(kind, text):
    send({'method': 'session/update', 'params': {'sessionId': 'ui-answer', 'update': {
        'sessionUpdate': kind, 'content': {'type': 'text', 'text': text}}}})


for line in sys.stdin:
    message = json.loads(line)
    method = message.get('method')
    result = {}
    if method == 'initialize':
        result = {'protocolVersion': 1}
    elif method == 'session/new':
        (root / '.grok/sessions/ui/ui-answer').mkdir(parents=True, exist_ok=True)
        result = {'sessionId': 'ui-answer'}
    elif method == 'session/prompt':
        update('agent_message_chunk', partial)
        deadline = time.monotonic() + 30
        while not (root / 'finish').exists() and time.monotonic() < deadline:
            time.sleep(0.05)
        update('agent_message_chunk', answer[len(partial):])
        result = {'stopReason': 'end_turn'}
    elif method == 'session/load':
        update('user_message_chunk', 'Explain policy entropy')
        update('agent_message_chunk', answer)
    if 'id' in message:
        send({'id': message['id'], 'result': result})
