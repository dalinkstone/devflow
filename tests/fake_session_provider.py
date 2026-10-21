#!/usr/bin/env python3
"""Protocol fixture, NOT a substitute for a real-agent acceptance test."""
import json
from pathlib import Path
import sys
import threading
import time

lock = threading.Lock()
turn = 0
pending = None


def send(value):
    with lock:
        print(json.dumps(value), flush=True)


def event(method, **params):
    send(dict(method=method, params=params))


def finish(ident):
    event('turn/completed', turn=dict(id=ident, status='completed'))


def delayed(ident):
    time.sleep(.3)
    Path('remote-result.txt').write_text('fixture remote execution')
    event('item/agentMessage/delta', delta='finished while detached')
    finish(ident)


for line in sys.stdin:
    message = json.loads(line)
    method, params = message.get('method'), message.get('params', {})
    ident = message.get('id')
    if method == 'initialize':
        assert params['clientInfo']['name'] == 'devflow'
        send(dict(id=ident, result={}))
    elif method in ('thread/start', 'thread/resume'):
        assert params['approvalPolicy'] == 'untrusted'
        assert params['sandbox'] == 'workspace-write'
        thread = params.get('threadId', 'fixture-thread')
        send(dict(id=ident, result={'thread': {'id': thread}}))
    elif method == 'turn/start':
        assert params['threadId'] == 'fixture-thread'
        turn += 1
        tid = 'turn-' + str(turn)
        with Path('turns.log').open('a') as out:
            out.write(params['input'][0]['text'] + '\n')
        send(dict(id=ident, result={'turn': {'id': tid}}))
        event('turn/started', turn=dict(id=tid))
        text = params['input'][0]['text']
        if text == 'crash':
            sys.exit(42)
        elif text == 'approve':
            pending = tid
            send(dict(id=17, method='item/commandExecution/requestApproval', params={'command': 'test command'}))
        elif text == 'question':
            pending = tid
            send(dict(id=18, method='item/tool/requestUserInput', params={'questions': [
                {'id': 'transport', 'question': 'Which transport?', 'options': [{'label': 'Polling'}, {'label': 'SSE'}]}]}))
        else:
            threading.Thread(target=delayed, args=(tid,), daemon=True).start()
    elif method == 'turn/interrupt':
        send(dict(id=ident, result={}))
        event('turn/completed', turn=dict(id=params['turnId'], status='interrupted'))
    elif method is None and ident in (17, 18):
        Path('answer.json').write_text(json.dumps(message))
        event('serverRequest/resolved', requestId=ident)
        finish(pending)
