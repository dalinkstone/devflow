"""Durability/transport/provider contract tests; real-agent results documented separately."""
import asyncio
import base64
import importlib.util
import json
import os
from pathlib import Path
import signal
import subprocess
import tempfile
import time
import unittest
import dataclasses
import sys
import types
from unittest.mock import patch

REPO = Path(__file__).resolve().parents[1]
CLI = REPO / 'bin/devflow'
PAYLOAD = subprocess.check_output([str(CLI), '__session-runtime'], text=True)


class Sessions(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='dv-sessions-')
        self.addCleanup(self.temp.cleanup)
        self.home = Path(self.temp.name)
        self.root = self.home / '.devflow/session'
        self.root.mkdir(parents=True)
        self.script = self.root / 'runtime.py'
        self.script.write_text(PAYLOAD)
        spec = importlib.util.spec_from_file_location('dv_sessions', self.script)
        self.runtime = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.runtime)
        self.runtime.ROOT = self.root
        self.bin = self.home / 'bin'
        self.bin.mkdir()
        fake = self.bin / 'codex'
        fake.write_text((REPO / 'tests/fake_session_provider.py').read_text())
        fake.chmod(0o700)
        self.cwd = self.home / 'work'
        self.cwd.mkdir()
        store = self.runtime.Store(self.root)
        store.save(id='test', sandbox_id='sandbox-test', provider='codex', repo='owner/repo',
                   branch='devflow/test', base_branch='main', cwd=str(self.cwd), status='idle',
                   pending={}, thread_id='fixture-thread', created_at=self.runtime.now())
        store.db.close()
        self.env = {k: v for k, v in os.environ.items() if k not in ('OPENAI_API_KEY', 'ANTHROPIC_API_KEY')}
        self.env.update(HOME=str(self.home), PATH=str(self.bin) + ':' + os.environ['PATH'])
        self.process = None
        self.addCleanup(self.stop)

    def start(self):
        self.process = subprocess.Popen(['python3', str(self.script), 'serve'], env=self.env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, start_new_session=True)
        self.wait(lambda s: s['state'].get('status') == 'idle')

    def stop(self):
        if self.process:
            with self.assertLogsIfNeeded():
                try:
                    os.killpg(self.process.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                self.process.wait(timeout=5)
                self.process.stderr.close()
            self.process = None

    def assertLogsIfNeeded(self):
        import contextlib
        return contextlib.nullcontext()

    def read(self, after=0):
        return self.runtime.rpc({'op': 'read', 'after': after})

    def action(self, op, ident=None, **args):
        return self.runtime.rpc(dict(id=ident or str(time.time_ns()), op=op, **args))

    def pending_id(self):
        return next(iter(self.read()['state']['pending']))

    def wait(self, predicate):
        deadline = time.monotonic() + 8
        last = None
        while time.monotonic() < deadline:
            try:
                last = self.read()
                if predicate(last):
                    return last
            except (RuntimeError, FileNotFoundError):
                pass
            time.sleep(.03)
        self.fail('timed out: ' + str(last))

    def test_replay_after_detach_and_followup_same_thread(self):
        self.start()
        self.action('prompt', text='long task')
        cursor = self.read()['cursor']
        time.sleep(.6)  # No attached client; provider still completes.
        self.assertEqual((self.cwd / 'remote-result.txt').read_text(), 'fixture remote execution')
        replay = self.read(cursor)
        self.assertTrue(any('finished while detached' in str(e) for e in replay['events']))
        self.assertFalse(self.read(replay['cursor'])['events'])
        self.action('prompt', text='followup')
        self.wait(lambda s: s['state']['status'] == 'completed')
        self.assertEqual(self.read()['state']['thread_id'], 'fixture-thread')
        self.assertEqual((self.cwd / 'turns.log').read_text().splitlines(), ['long task', 'followup'])

    def test_dropped_ack_retries_do_not_duplicate_prompt(self):
        self.start()
        first = self.action('prompt', ident='fixed', text='one')
        self.assertEqual(first, self.action('prompt', ident='fixed', text='one'))
        self.assertIn('error', self.action('prompt', ident='fixed', text='different'))
        self.wait(lambda s: s['state']['status'] == 'completed')
        self.assertEqual((self.cwd / 'turns.log').read_text(), 'one\n')

    def test_followup_is_durably_queued_while_waiting(self):
        self.start()
        self.action('prompt', text='approve')
        self.wait(lambda s: bool(s['state']['pending']))
        self.action('prompt', text='next task')
        self.assertEqual(self.read()['state']['queued'][0]['text'], 'next task')
        self.action('answer', interaction=self.pending_id(), reply={'allow': True})
        self.wait(lambda s: s['state']['status'] == 'completed' and not s['state']['queued'])
        self.assertEqual((self.cwd / 'turns.log').read_text().splitlines(), ['approve', 'next task'])

    def test_approval_persists_without_client_and_denies_explicitly(self):
        self.start()
        self.action('prompt', text='approve')
        self.wait(lambda s: bool(s['state']['pending']))
        time.sleep(.2)
        self.assertEqual(self.read()['state']['status'], 'waiting')
        disk = self.runtime.Store(self.root)
        self.assertIn(self.pending_id(), disk.meta['pending'])
        disk.db.close()
        self.assertFalse((self.cwd / 'answer.json').exists())
        self.action('answer', interaction=self.pending_id(), reply={'allow': False})
        self.wait(lambda s: s['state']['status'] == 'completed')
        self.assertEqual(json.loads((self.cwd / 'answer.json').read_text())['result'], {'decision': 'decline'})

    def test_question_freeform_validation_and_answer(self):
        self.start()
        self.action('prompt', text='question')
        self.wait(lambda s: bool(s['state']['pending']))
        self.assertIn('error', self.action('answer', interaction=self.pending_id(), reply={'answers': {}}))
        self.action('answer', interaction=self.pending_id(), reply={'answers': {'transport': 'custom answer'}})
        self.wait(lambda s: s['state']['status'] == 'completed')
        self.assertEqual(json.loads((self.cwd / 'answer.json').read_text())['result'],
                         {'answers': {'transport': {'answers': ['custom answer']}}})

    def test_second_supervisor_cannot_start(self):
        self.start()
        second = subprocess.run(['python3', str(self.script), 'serve'], env=self.env, timeout=3)
        self.assertEqual(second.returncode, 0)
        self.assertEqual(self.read()['state']['pid'], self.process.pid)

    def test_provider_crash_explicit_recovery_preserves_thread(self):
        self.start()
        self.action('prompt', text='crash')
        self.wait(lambda s: s['state']['status'] == 'failed')
        self.assertIn('error', self.action('prompt', text='must not auto restart'))
        self.action('recover')
        self.wait(lambda s: s['state']['status'] == 'idle')
        self.action('prompt', text='recovered')
        self.wait(lambda s: s['state']['status'] == 'completed')
        self.assertEqual(self.read()['state']['thread_id'], 'fixture-thread')

    def test_stop_restart_does_not_replay_previous_prompt(self):
        self.start()
        self.action('prompt', text='approve')
        self.wait(lambda s: bool(s['state']['pending']))
        cursor = self.read()['cursor']
        self.stop()
        self.assertEqual(self.read()['state']['status'], 'unavailable')
        self.start()
        self.assertFalse(self.read()['state']['pending'])
        self.assertEqual((self.cwd / 'turns.log').read_text(), 'approve\n')
        self.assertGreater(self.read()['cursor'], cursor)

    def test_interrupt_is_not_detach(self):
        self.start()
        self.action('prompt', text='approve')
        self.wait(lambda s: bool(s['state']['pending']))
        self.action('interrupt')
        self.wait(lambda s: s['state']['status'] == 'interrupted')
        self.assertIsNone(self.process.poll())

    def test_stale_reply_cannot_approve_reused_provider_request_id(self):
        self.start()
        self.action('prompt', text='approve')
        self.wait(lambda s: bool(s['state']['pending']))
        old = self.pending_id()
        self.action('interrupt')
        self.wait(lambda s: s['state']['status'] == 'interrupted')
        self.action('prompt', text='approve')
        self.wait(lambda s: bool(s['state']['pending']))
        self.assertNotEqual(old, self.pending_id())
        self.assertIn('error', self.action('answer', interaction=old, reply={'allow': True}))
        self.assertFalse((self.cwd / 'answer.json').exists())

    def test_unknown_approval_cannot_grant_permissions(self):
        async def run():
            supervisor = self.runtime.Supervisor(self.root, None)
            supervisor.pending('99', {'provider_id': 99, 'method': 'unknown/approval', 'params': {}})
            provider = self.runtime.Codex(supervisor)
            sent = []
            async def write(value):
                sent.append(value)
            provider.write = write
            await provider.answer('99', {'allow': True})
            self.assertIn('error', sent[0])
            supervisor.store.db.close()
        asyncio.run(run())

    def test_terminal_escape_sanitization(self):
        self.assertEqual(self.runtime.clean('hello\x1b]52;c;secret\x07\x1b[2J\x00world'), 'helloworld')

    def test_known_secrets_are_redacted_in_events_and_reads(self):
        secret = 'never-log-this-fake-api-key'
        with patch.dict(os.environ, OPENAI_API_KEY=secret):
            store = self.runtime.Store(self.root)
            store.event('output', {'nested': [secret]})
            store.save(error='failure: ' + secret)
            result = store.read()
            self.assertNotIn(secret, json.dumps(result))
            self.assertIn('[redacted]', json.dumps(result))
            store.db.close()

    def test_claude_adapter_permissions_resume_and_errors(self):
        @dataclasses.dataclass
        class SystemMessage:
            subtype: str
            data: dict
        @dataclasses.dataclass
        class ResultMessage:
            session_id: str = 'claude-thread'
            is_error: bool = False
            result: str = ''
        class Options:
            def __init__(self, **kw):
                self.values = kw
        class Allow:
            def __init__(self, **kw):
                self.values = kw
        class Deny(Allow):
            pass
        class SDKClient:
            def __init__(self, options):
                self.options = options
                self.error = False
            async def connect(self):
                pass
            async def query(self, text):
                self.prompt = text
            async def receive_response(self):
                yield SystemMessage('init', {'session_id': 'claude-thread'})
                yield ResultMessage(is_error=self.error, result='expired credential' if self.error else '')
            async def disconnect(self):
                pass
            async def interrupt(self):
                pass
        sdk = types.SimpleNamespace(ClaudeSDKClient=SDKClient, ClaudeAgentOptions=Options,
                                    PermissionResultAllow=Allow, PermissionResultDeny=Deny,
                                    ResultMessage=ResultMessage, SystemMessage=SystemMessage)
        async def run():
            s = self.runtime.Supervisor(self.root, None)
            s.store.save(provider='claude', thread_id='claude-thread')
            p = self.runtime.Claude(s)
            s.provider = p
            await p.start()
            self.assertEqual(p.client.options.values['resume'], 'claude-thread')
            self.assertEqual(p.client.options.values['permission_mode'], 'default')
            self.assertEqual(p.client.options.values['setting_sources'], [])
            pending = asyncio.create_task(p.permission('Bash', {'command': 'test'}, None))
            await asyncio.sleep(0)
            ident = next(iter(s.store.meta['pending']))
            self.assertFalse(pending.done())
            await p.answer(ident, {'allow': False})
            self.assertIsInstance(await pending, Deny)
            pending = asyncio.create_task(p.permission('AskUserQuestion', {'questions': [{'question': 'Which?'}]}, None))
            await asyncio.sleep(0)
            ident = next(iter(s.store.meta['pending']))
            await p.answer(ident, {'answers': {'Which?': 'custom reply'}})
            self.assertEqual((await pending).values['updated_input']['answers'], {'Which?': 'custom reply'})
            await p.prompt('first prompt')
            await p.task
            self.assertEqual(s.store.meta['status'], 'completed')
            p.client.error = True
            await p.prompt('second prompt')
            await p.task
            self.assertEqual(s.store.meta['status'], 'failed')
            self.assertEqual(s.store.meta['error'], 'expired credential')
            await p.close()
            s.store.db.close()
        with patch.dict(sys.modules, claude_agent_sdk=sdk):
            asyncio.run(run())

    def test_real_git_branch_commit_push_and_draft_pr_contract(self):
        def git(*args, cwd=None):
            return subprocess.check_output(['git', *args], cwd=cwd, stderr=subprocess.DEVNULL, text=True)
        bare = self.home / 'origin.git'
        seed = self.home / 'seed'
        git('init', '--bare', str(bare))
        git('init', str(seed))
        git('config', 'user.name', 'Devflow Test', cwd=seed)
        git('config', 'user.email', 'test@example.invalid', cwd=seed)
        (seed / 'README').write_text('baseline')
        git('add', '.', cwd=seed)
        git('commit', '-m', 'baseline', cwd=seed)
        git('remote', 'add', 'origin', str(bare), cwd=seed)
        git('push', 'origin', 'HEAD:main', cwd=seed)
        git('symbolic-ref', 'HEAD', 'refs/heads/main', cwd=bare)
        git('clone', str(bare), str(self.cwd))
        git('config', 'user.name', 'Devflow Test', cwd=self.cwd)
        git('config', 'user.email', 'test@example.invalid', cwd=self.cwd)
        fakegh = self.bin / 'gh'
        fakegh.write_text('#!/usr/bin/env python3\nimport json,sys\nfrom pathlib import Path\n'
                          'with (Path(__file__).parent.parent/"gh-calls.log").open("a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\n'
                          'print("[]" if sys.argv[2] == "list" else "https://github.com/owner/repo/pull/7")\n')
        fakegh.chmod(0o700)
        async def run():
            s = self.runtime.Supervisor(self.root, None)
            await s.workspace()
            self.assertEqual(s.store.meta['base_branch'], 'main')
            self.assertEqual(git('branch', '--show-current', cwd=self.cwd).strip(), 'devflow/test')
            (self.cwd / 'change.txt').write_text('edited in workspace')
            await s.perform({'op': 'pr', 'text': 'Test change'})
            self.assertEqual(s.store.meta['pr'], 'https://github.com/owner/repo/pull/7')
            self.assertEqual(git('show', 'refs/heads/devflow/test:change.txt', cwd=bare), 'edited in workspace')
            calls = [json.loads(line) for line in (self.home / 'gh-calls.log').read_text().splitlines()]
            self.assertIn('--draft', calls[-1])
            git('checkout', 'main', cwd=self.cwd)
            with self.assertRaises(ValueError):
                await s.perform({'op': 'pr', 'text': 'must not publish main'})
            s.store.db.close()
        with patch.dict(os.environ, PATH=str(self.bin) + ':' + os.environ['PATH']):
            asyncio.run(run())

    def test_outbox_survives_client_restart(self):
        client = self.runtime.Client(str(CLI), self.home / 'config', 'sandbox')
        request = client.enqueue('prompt', text='retry me')
        restored = self.runtime.Client(str(CLI), self.home / 'config', 'sandbox')
        path = restored.outbox / (request['id'] + '.json')
        self.assertEqual(json.loads(path.read_text()), request)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)

    def test_status_does_not_execute_locally(self):
        client = self.runtime.Client(str(CLI), self.home / 'config', 'sandbox')
        with patch.object(self.runtime.subprocess, 'run') as run:
            run.return_value = subprocess.CompletedProcess([], 0, '{"state":{}}', '')
            client.call({'op': 'prompt', 'text': '$(touch SHOULD_NOT_EXIST)'})
            argv = run.call_args.args[0]
            self.assertEqual(argv[:3], [str(CLI), '__session-rpc', 'sandbox'])
            self.assertNotIn('shell', run.call_args.kwargs)
            self.assertEqual(json.loads(base64.b64decode(argv[3]))['text'], '$(touch SHOULD_NOT_EXIST)')


if __name__ == '__main__':
    unittest.main()
