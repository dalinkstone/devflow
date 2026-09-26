"""Real fixture/patch checks, with fake model and inbox APIs; no cloud calls."""
import importlib.util
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest
from unittest.mock import Mock, patch

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = subprocess.check_output([str(ROOT / 'bin/devflow'), '__bugfix-demo'], text=True)


class BugfixTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        folder = Path(self.temp.name)
        source = folder / 'demo.py'
        source.write_text(PAYLOAD)
        spec = importlib.util.spec_from_file_location('bugfix', source)
        self.demo = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.demo)
        self.demo.ROOT = folder / 'app'
        self.demo.STATE = folder / 'state'
        self.env = patch.dict(os.environ, GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_NOSYSTEM='1')
        self.env.start()
        self.addCleanup(self.env.stop)
        self.demo.seed()

    def fixed_patch(self):
        app = self.demo.ROOT / 'app.py'
        app.write_text(self.demo.APP.replace('item["qty"] for', 'item["qty"] * item["price_cents"] for'))
        change = self.demo.git('diff', (self.demo.STATE / 'base').read_text(), '--', 'app.py')
        app.write_text(self.demo.APP)
        return change

    def inbox(self, change):
        module = Mock()
        module.request.side_effect = lambda c, endpoint, data=None: (
            [{'id': 1, 'sender': 'leader', 'body': change}] if endpoint == '/inbox' else {'id': 1})
        return module

    def test_broken_fixture_really_fails_three_tests(self):
        result = self.demo.evaluate()
        self.assertEqual((result['passed'], result['total']), (2, 5))
        self.assertEqual(result['tests'][0]['actual'], 20)

    def test_private_handoff_applies_real_patch_and_returns_five_passes(self):
        module = self.inbox(self.fixed_patch())
        with patch.object(self.demo, 'bus', return_value=(module, {})):
            self.demo.verify()
        result = json.loads((self.demo.STATE / 'result.json').read_text())
        self.assertEqual(result['passed'], 5)
        self.assertEqual(module.request.call_args_list[-1].args[1], '/ack')
        self.assertEqual(module.request.call_args_list[-2].args[2]['to'], 'leader')

    def test_incorrect_patch_is_not_reported_as_success(self):
        change = self.fixed_patch().replace('+    return sum(item["qty"] * item["price_cents"] for item in items)', '+    return 0')
        with patch.object(self.demo, 'bus', return_value=(self.inbox(change), {})):
            self.demo.verify()
        self.assertLess(json.loads((self.demo.STATE / 'result.json').read_text())['passed'], 5)

    def test_no_patch_cannot_pass(self):
        with self.assertRaises(ValueError):
            self.demo.package()

    def test_rejects_extra_paths_symlinks_and_binary(self):
        good = self.fixed_patch()
        for bad in ('', good * 2, good.replace('a/app.py', 'a/tests.py'),
                    good.replace('\nindex ', '\nold mode 100644\nnew mode 120000\nindex '),
                    'GIT binary patch', good + 'x' * 32000):
            with self.subTest(patch=bad[:60]), self.assertRaises(ValueError):
                self.demo.validate_patch(bad)

    def test_verifier_requires_fixer_sender_and_single_patch(self):
        module = Mock()
        for messages in ([], [{'id': 1, 'sender': 'other', 'body': self.fixed_patch()}],
                         [{'id': i, 'sender': 'leader', 'body': self.fixed_patch()} for i in (1, 2)]):
            module.request.return_value = messages
            with patch.object(self.demo, 'bus', return_value=(module, {})), self.assertRaises(ValueError):
                self.demo.verify()

    def test_agent_timeout_kills_process_group_and_records_failure(self):
        child = Mock(pid=1234)
        child.wait.side_effect = [subprocess.TimeoutExpired('codex', 30), -9]
        with patch.object(self.demo.subprocess, 'Popen', return_value=child), patch.object(self.demo.os, 'killpg') as kill:
            self.demo.agent('codex', 30)
        kill.assert_called_once_with(1234, self.demo.signal.SIGKILL)
        self.assertEqual(json.loads((self.demo.STATE / 'status.json').read_text())['state'], 'timeout')

    def test_agent_nonzero_exit_is_failure(self):
        child = Mock()
        child.wait.return_value = 7
        with patch.object(self.demo.subprocess, 'Popen', return_value=child) as launch:
            self.demo.agent('claude', 30)
        self.assertIn('-p', launch.call_args.args[0])
        self.assertEqual(json.loads((self.demo.STATE / 'status.json').read_text())['state'], 'failed')


if __name__ == '__main__':
    unittest.main()
