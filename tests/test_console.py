"""Interactive demo navigation and interrupt cleanup with fake cloud commands."""
import errno
import fcntl
import os
from pathlib import Path
import pty
import select
import shutil
import signal
import struct
import subprocess
import tempfile
import termios
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]


class DemoConsoleTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="devflow-console-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.state = self.root / "state"
        self.state.mkdir()
        self.home = self.root / "home"
        self.home.mkdir()
        self.master, slave = pty.openpty()
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack("HHHH", 30, 100, 0, 0))
        self.output = b""
        env = dict(os.environ, HOME=str(self.home), DEVFLOW_CONFIG_DIR=str(self.root / "config"),
                   PATH=str(ROOT / "tests/fakebin") + os.pathsep + os.environ["PATH"],
                   FAKE_STATE_DIR=str(self.state), FAKE_LOG=str(self.root / "log"),
                   DAYTONA_API_KEY="dtn_FAKE", FAKE_EXEC_STYLE="argv", TERM="xterm", NO_COLOR="1")
        env.pop("DEVFLOW_SNAPSHOT", None)
        env.pop("DEVFLOW_TARGET", None)
        args = [str(ROOT / "bin/devflow"), "demo", "linked"]
        if self._testMethodName == "test_demo_chooser_exit":
            args.pop()
        if self._testMethodName != "test_gum_walkthrough":
            args.append("--plain")
        self.process = subprocess.Popen(args,
                                        stdin=slave, stdout=slave, stderr=slave, env=env,
                                        start_new_session=True,
                                        preexec_fn=lambda: fcntl.ioctl(0, termios.TIOCSCTTY, 0))
        os.close(slave)
        self.addCleanup(self.close)

    def close(self):
        os.close(self.master)
        if self.process.poll() is None:
            try:
                self.process.wait(timeout=2)
            except subprocess.TimeoutExpired:
                os.killpg(self.process.pid, signal.SIGTERM)
                self.process.wait(timeout=10)

    def finish(self):
        # Drain the terminal before waiting: PTY children can still have output
        # (including signal/terminal teardown) pending as they exit.
        deadline = time.monotonic() + 10
        while time.monotonic() < deadline:
            ready, _, _ = select.select([self.master], [], [], 0.1)
            if not ready:
                if self.process.poll() is not None:
                    break
                continue
            try:
                chunk = os.read(self.master, 65536)
            except OSError as exc:
                if exc.errno == errno.EIO:
                    break
                raise
            if not chunk:
                break
            self.output += chunk
        return self.process.wait(timeout=5)

    def until(self, text, timeout=20):
        deadline = time.monotonic() + timeout
        while text.encode() not in self.output:
            if time.monotonic() >= deadline:
                self.fail("console timeout: " + self.output.decode(errors="replace"))
            ready, _, _ = select.select([self.master], [], [], 0.1)
            if ready:
                try:
                    chunk = os.read(self.master, 65536)
                except OSError as exc:
                    if exc.errno == errno.EIO:
                        self.fail("console closed: " + self.output.decode(errors="replace"))
                    raise
                self.output += chunk
        result = self.output.decode(errors="replace")
        self.output = b""
        return result

    def test_walkthrough_and_another_job(self):
        self.until("1) Create sandboxes")
        os.write(self.master, b"1\n")
        output = self.until("4) Finish")
        self.assertIn("same path, different contents", output)
        self.assertIn("Job #1 complete", output)
        os.write(self.master, b"1\n")
        self.until("Text to analyze:")
        os.write(self.master, b"a second interactive job\n")
        self.until("4) Finish")
        os.write(self.master, b"4\n")
        self.until("demo sandboxes deleted")
        self.assertEqual(self.finish(), 0)
        self.assertEqual(list(self.state.glob("*.json")), [])

    def test_cancel_before_creation(self):
        self.until("2) Cancel")
        os.write(self.master, b"2\n")
        self.assertEqual(self.finish(), 0)
        self.assertEqual(list(self.state.glob("*.json")), [])

    def test_demo_chooser_exit(self):
        output = self.until("6) Exit")
        self.assertIn("LibreOffice", output)
        self.assertIn("Harbor", output)
        self.assertIn("Tier 3+", output)
        self.assertIn("Fix a broken app", output)
        os.write(self.master, b"6\n")
        self.assertEqual(self.finish(), 0)
        self.assertEqual(list(self.state.glob("*.json")), [])

    @unittest.skipUnless(shutil.which("gum"), "optional Charm Gum is not installed")
    def test_gum_walkthrough(self):
        self.until("Create sandboxes")
        os.write(self.master, b"\r")
        self.until("Run another job")
        os.write(self.master, b"jjj")
        time.sleep(0.1)
        os.write(self.master, b"\r")
        self.until("demo sandboxes deleted")
        self.assertEqual(self.finish(), 0)
        self.assertEqual(list(self.state.glob("*.json")), [])

    def test_interrupt_removes_only_demo_resources(self):
        unrelated = self.state / "unrelated.json"
        unrelated.write_text('{"id":"id-unrelated","name":"unrelated","state":"started","labels":{}}')
        self.until("1) Create sandboxes")
        os.write(self.master, b"1\n")
        self.until("4) Finish")
        os.killpg(self.process.pid, signal.SIGINT)
        self.finish()
        self.assertEqual(sorted(p.name for p in self.state.glob("*.json")), ["unrelated.json"])


if __name__ == "__main__":
    unittest.main()
