"""Embedded desktop and Harbor orchestration tests; no cloud/model credentials."""
import base64
import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import Mock, patch
import zipfile

ROOT = Path(__file__).resolve().parents[1]
PAYLOAD = subprocess.check_output([str(ROOT / 'bin/devflow'), '__demo-driver'], text=True)


def sheet(path, valid=True):
    labels = ('Item', 'Units', 'Price', 'Total', 'Notebooks', 'Pens', 'Folders', 'Grand total')
    cells = ''.join('<table:table-cell><text:p>' + s + '</text:p></table:table-cell>' for s in labels)
    cells += ''.join('<table:table-cell table:formula="of:=1" office:value="86"/>' for _ in range(4 if valid else 0))
    xml = ('<office:document-content xmlns:office="urn:oasis:names:tc:opendocument:xmlns:office:1.0" '
           'xmlns:table="urn:oasis:names:tc:opendocument:xmlns:table:1.0" '
           'xmlns:text="urn:oasis:names:tc:opendocument:xmlns:text:1.0">' + cells + '</office:document-content>')
    with zipfile.ZipFile(path, 'w') as archive:
        archive.writestr('content.xml', xml)


class DemoTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory()
        path = Path(cls.temp.name) / 'driver.py'
        path.write_text(PAYLOAD)
        spec = importlib.util.spec_from_file_location('demo_driver', path)
        cls.driver = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.driver)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.temp_run = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp_run.cleanup)
        self.folder = Path(self.temp_run.name)
        self.args = SimpleNamespace(mode='desktop', cli='/devflow', view='none', domain='devflow.sh', keep='0')
        self.client = Mock()
        self.sb = self.client.get.return_value
        self.sb.computer_use.display.get_windows.return_value = 'LibreOffice Calc - Notepad - Program Manager - Run'
        self.sb.computer_use.screenshot.take_full_screen.return_value = SimpleNamespace(screenshot=base64.b64encode(b'png').decode())
        self.sb.computer_use.recording.start.return_value = SimpleNamespace(id='recording-1')
        self.sb.create_signed_preview_url.return_value = SimpleNamespace(url='https://preview.example/?token=private')
        self.sb.fs.download_file.side_effect = lambda remote, local: sheet(local)
        self.ctl = self.driver.Desktop(self.args, self.client, self.folder)
        self.calls = []

        def run(args, **kwargs):
            self.calls.append(args)
            return SimpleNamespace(returncode=0, stdout='', stderr='')
        self.patches = [patch.object(self.driver.subprocess, 'run', side_effect=run),
                        patch.object(self.driver.time, 'sleep'), patch.object(self.driver, 'note')]
        for p in self.patches:
            p.start()
            self.addCleanup(p.stop)

    def test_gui_recording_precedes_keyboard_and_download_precedes_delete(self):
        self.ctl.run()
        self.ctl.finalize()
        calls = [str(c) for c in self.sb.mock_calls]
        self.assertLess(next(i for i, s in enumerate(calls) if 'recording.start' in s),
                        next(i for i, s in enumerate(calls) if 'keyboard.hotkey' in s))
        self.assertTrue(self.ctl.finished)
        self.sb.computer_use.recording.download.assert_called_once()
        self.assertIn(['daytona', 'delete', self.ctl.name], self.calls)
        remote_calls = [c for c in self.calls if '__demo-exec' in c]
        self.assertTrue(remote_calls)
        self.assertTrue(all('\n' not in c[3] for c in remote_calls))
        self.assertTrue((self.folder / 'spreadsheet.ods').exists())
        self.assertEqual((self.folder / 'steps.json').stat().st_mode & 0o777, 0o600)

    def test_windows_has_no_linux_shell_commands(self):
        self.args.mode = 'windows'
        self.ctl.run()
        self.ctl.finalize()
        self.assertIn('--snapshot=windows-small', self.calls[0])
        self.assertFalse(any('__demo-exec' in c for c in self.calls))
        self.sb.computer_use.keyboard.type.assert_any_call('notepad', request_timeout=30)
        self.sb.computer_use.keyboard.press.assert_any_call('enter', request_timeout=30)
        self.assertTrue(all('+' in c.args[0] for c in self.sb.computer_use.keyboard.hotkey.call_args_list))
        self.sb.computer_use.recording.start.assert_not_called()
        self.assertTrue((self.folder / 'desktop.png').exists())

    def test_main_accepts_sync_sdk_without_close(self):
        client = SimpleNamespace(get=self.client.get)
        module = SimpleNamespace(Daytona=lambda config: client, DaytonaConfig=lambda **kwargs: kwargs)
        argv = ['driver', 'desktop', '--cli=/devflow', '--output=' + str(self.folder), '--view=none', '--yes=1']
        with patch.dict(sys.modules, daytona=module), patch.object(sys, 'argv', argv):
            self.assertEqual(self.driver.main(), 0)
        self.assertTrue(any('delete' in c for c in self.calls))

    def test_native_preview_is_default_and_token_is_not_logged(self):
        self.args.domain = ''
        self.ctl.sandbox = self.sb
        url = self.ctl.preview_url()
        self.assertIn('/vnc.html?token=private&autoconnect=true&resize=scale', url)
        self.sb.create_signed_preview_url.assert_called_once_with(6080, expires_in_seconds=900, request_timeout=30)
        path = self.folder / 'preview-url.txt'
        self.assertEqual(path.read_text().strip(), url)
        self.assertEqual(path.stat().st_mode & 0o777, 0o600)
        self.assertNotIn('token=private', str(self.driver.note.call_args_list))

    def test_explicit_proxy_does_not_mint_signed_link(self):
        self.ctl.sandbox = self.sb
        self.assertIn('--6080.devflow.sh/vnc.html', self.ctl.preview_url())
        self.sb.create_signed_preview_url.assert_not_called()

    def test_preview_failure_has_dashboard_fallback(self):
        self.args.domain = ''
        self.ctl.sandbox = self.sb
        self.sb.create_signed_preview_url.side_effect = OSError('private-token-details')
        self.assertIsNone(self.ctl.preview_url())
        self.assertNotIn('private-token-details', str(self.driver.note.call_args_list))

    def test_windows_waits_for_shell_before_keyboard(self):
        self.args.mode = 'windows'
        self.sb.computer_use.display.get_windows.side_effect = ['', 'Program Manager', 'Run', 'Notepad']
        self.ctl.run()
        calls = [str(c) for c in self.sb.mock_calls]
        first_key = next(i for i, c in enumerate(calls) if 'keyboard.' in c)
        self.assertEqual(sum('display.get_windows' in c for c in calls[:first_key]), 2)

    def test_failed_recording_download_preserves_only_own_sandbox(self):
        self.ctl.run()
        self.sb.computer_use.recording.download.side_effect = OSError('network')
        with self.assertRaisesRegex(RuntimeError, 'not downloaded'):
            self.ctl.finalize()
        self.assertFalse(any('delete' in c for c in self.calls))

    def test_failed_actions_still_save_partial_recording_and_delete(self):
        self.sb.computer_use.keyboard.hotkey.side_effect = RuntimeError('bad key')
        with self.assertRaisesRegex(RuntimeError, 'bad key'):
            self.ctl.run()
        self.args.keep = '1'
        self.ctl.finalize()
        self.sb.computer_use.recording.download.assert_called_once()
        self.assertIn(['daytona', 'delete', self.ctl.name], self.calls)

    def test_keep_requires_success(self):
        self.args.keep = '1'
        self.ctl.run()
        self.ctl.finalize()
        self.assertFalse(any('delete' in c for c in self.calls))

    def test_sheet_requires_real_calculated_formulas(self):
        path = self.folder / 'bad.ods'
        sheet(path, valid=False)
        with self.assertRaisesRegex(RuntimeError, 'formulas'):
            self.driver.verify_sheet(path)

    def test_eval_task_contains_truthful_verifier_and_oracle(self):
        task = self.driver.make_eval_task(self.folder)
        self.assertIn('86', (task / 'solution/solve.sh').read_text())
        test = (task / 'tests/test.sh').read_text()
        self.assertIn('/logs/verifier/reward.txt', test)
        self.assertIn("printf '0", test)
        self.assertIn("printf '1", test)
        self.assertNotIn('API_KEY', '\n'.join(p.read_text() for p in task.rglob('*') if p.is_file()))

    def test_eval_results_never_fabricate_rewards(self):
        result = self.folder / 'result.json'
        result.write_text(json.dumps({'verifier_result': {'rewards': {'reward': 0}}}))
        self.assertEqual(self.driver.eval_rewards(self.folder), 0)
        result.write_text(json.dumps({'verifier_result': None, 'exception_info': {'error': 'failed'}}))
        with self.assertRaisesRegex(RuntimeError, 'trial failed'):
            self.driver.eval_rewards(self.folder)
        result.unlink()
        with self.assertRaisesRegex(RuntimeError, 'found 0'):
            self.driver.eval_rewards(self.folder)

    def test_create_failure_still_attempts_cleanup(self):
        def failed(args, **kwargs):
            if 'info' in args:
                return SimpleNamespace(returncode=0, stdout=json.dumps({'labels': {'devflow.demo.run': self.ctl.run_id}}))
            return SimpleNamespace(returncode=1, stdout='', stderr='quota')
        self.driver.subprocess.run.side_effect = failed
        with self.assertRaisesRegex(RuntimeError, 'create failed'):
            self.ctl.run()
        with self.assertRaisesRegex(RuntimeError, 'Cleanup failed'):
            self.ctl.finalize()

    def test_create_collision_cannot_delete_existing_sandbox(self):
        self.ctl.created = True
        self.driver.subprocess.run.return_value = SimpleNamespace(returncode=0, stdout='{"labels":{}}')
        self.driver.subprocess.run.side_effect = None
        with self.assertRaisesRegex(RuntimeError, 'unowned sandbox'):
            self.ctl.finalize()
        self.assertFalse(any('delete' in call.args[0] for call in self.driver.subprocess.run.call_args_list))


if __name__ == '__main__':
    unittest.main()
