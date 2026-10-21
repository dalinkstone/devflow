"""Exercise the actual session TUI in a PTY without external credentials."""
import base64
import fcntl
import json
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class SessionConsole(unittest.TestCase):
    def test_question_keyboard_interrupt_disconnect_and_reconnect(self):
        with tempfile.TemporaryDirectory(prefix='dv-session-ui-') as folder:
            root = Path(folder)
            runtime = root / 'runtime.py'
            runtime.write_bytes(subprocess.check_output([str(ROOT / 'bin/devflow'), '__session-runtime']))
            fake = root / 'devflow'
            fake.write_text('''#!/usr/bin/env python3
import base64,json,sys
from pathlib import Path
root=Path(__file__).parent
request=json.loads(base64.b64decode(sys.argv[3]))
if (root/'offline').exists(): sys.exit(1)
with (root/'requests').open('a') as f: f.write(json.dumps(request)+'\\n')
if request['op']=='read':
    print(json.dumps({'state':{'sandbox_id':'ui-test','provider':'codex','status':'waiting','repo':'owner/repo','branch':'devflow/ui','pending':{'question-1':{'method':'item/tool/requestUserInput','params':{'questions':[{'id':'transport','question':'Which transport?','options':[{'label':'Polling'},{'label':'SSE'}]}]}}}},'events':[],'cursor':0}))
else: print(json.dumps({'accepted':request['id']}))
''')
            fake.chmod(0o700)
            master, slave = pty.openpty()
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 90, 0, 0))
            proc = subprocess.Popen(['python3', str(runtime), 'client', str(fake), str(root / 'config'), 'test', 'tui'],
                                    stdin=slave, stdout=slave, stderr=slave, env=dict(os.environ, TERM='xterm-256color'),
                                    start_new_session=True)
            os.close(slave)
            output = b''
            def until(predicate):
                nonlocal output
                end = time.monotonic() + 10
                while time.monotonic() < end:
                    if select.select([master], [], [], .05)[0]:
                        try:
                            output += os.read(master, 65536)
                        except OSError:
                            break
                    if predicate():
                        return
                self.fail(output.decode(errors='replace')[-5000:])
            def requests():
                path = root / 'requests'
                return [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
            try:
                until(lambda: b'question-1' in output)
                os.write(master, b'\t')
                until(lambda: b'Which transport?' in output)
                os.write(master, b'2\n')
                until(lambda: any(r['op'] == 'answer' for r in requests()))
                answer = next(r for r in requests() if r['op'] == 'answer')
                self.assertEqual(answer['reply'], {'answers': {'transport': 'SSE'}})
                os.write(master, b'\x03')
                until(lambda: any(r['op'] == 'interrupt' for r in requests()))
                self.assertIsNone(proc.poll())
                (root / 'offline').touch()
                until(lambda: b'retrying' in output)
                (root / 'offline').unlink()
                count = len(requests())
                until(lambda: len(requests()) > count)
                os.write(master, b'\x04')
                until(lambda: proc.poll() is not None)
                proc.wait(timeout=5)
                self.assertEqual(proc.returncode, 0)
                self.assertFalse(any(r['op'] in ('stop', 'delete') for r in requests()))
            finally:
                if proc.poll() is None:
                    os.killpg(proc.pid, signal.SIGKILL)
                    proc.wait(timeout=5)
                os.close(master)


if __name__ == '__main__':
    unittest.main()
