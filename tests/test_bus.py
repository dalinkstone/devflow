"""Exercise the actual embedded inbox service over HTTP, without Daytona."""
import importlib.util
import json
import os
from pathlib import Path
import socket
import subprocess
import tempfile
import time
import unittest
from urllib.error import HTTPError
from urllib.request import Request, urlopen

ROOT = Path(__file__).resolve().parents[1]


class BusTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.temp = tempfile.TemporaryDirectory(prefix="devflow-bus-test-")
        cls.root = Path(cls.temp.name)
        cls.script = cls.root / "bus.py"
        cls.script.write_bytes(subprocess.check_output([str(ROOT / "bin/devflow"), "__bus-script"]))
        spec = importlib.util.spec_from_file_location("devflow_bus", cls.script)
        cls.bus = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cls.bus)

    @classmethod
    def tearDownClass(cls):
        cls.temp.cleanup()

    def setUp(self):
        self.work = Path(tempfile.mkdtemp(dir=self.root))
        with socket.socket() as sock:
            sock.bind(("127.0.0.1", 0))
            port = sock.getsockname()[1]
        self.url = "http://127.0.0.1:" + str(port)
        self.config = self.work / "config.json"
        self.config.write_text(json.dumps({
            "team": "test", "role": "leader", "url": self.url,
            "bind": "127.0.0.1", "token": "leader-token",
            "peers": {"leader": {"token": "leader-token"}, "worker": {"token": "worker-token"}},
        }))
        self.env = dict(os.environ, DEVFLOW_BUS_CONFIG=str(self.config))
        self.process = subprocess.Popen([os.sys.executable, str(self.script), "serve"], env=self.env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        self.addCleanup(self.stop_server)
        for _ in range(100):
            try:
                self.api("/health")
                break
            except OSError:
                if self.process.poll() is not None:
                    self.fail(self.process.stderr.read().decode())
                time.sleep(0.02)
        else:
            self.fail("bus did not become ready")

    def stop_server(self):
        self.process.terminate()
        self.process.wait(timeout=5)
        self.process.stderr.close()

    def api(self, path, data=None, token="leader-token"):
        req = Request(self.url + path, data=None if data is None else json.dumps(data).encode(),
                      headers={"Authorization": "Bearer " + token})
        with urlopen(req, timeout=3) as result:
            return json.load(result)

    def cli(self, *args, config=None, extra_env=None):
        env = dict(self.env, **(extra_env or {}))
        if config:
            env["DEVFLOW_BUS_CONFIG"] = str(config)
        return subprocess.run([os.sys.executable, str(self.script)] + list(args), env=env,
                              capture_output=True, text=True, timeout=5)

    def test_authentication_required(self):
        for token in ("", "wrong-token"):
            with self.assertRaises(HTTPError) as error:
                self.api("/health", token=token)
            self.assertEqual(error.exception.code, 401)

    def test_role_identity_and_private_inbox(self):
        sent = self.api("/send", {"to": "worker", "body": "review", "from": "worker"})
        self.assertEqual(sent["from"], "leader")
        self.assertEqual(self.api("/inbox"), [])
        inbox = self.api("/inbox", token="worker-token")
        self.assertEqual(inbox[0]["body"], "review")
        self.assertEqual(inbox, self.api("/inbox", token="worker-token"))
        with self.assertRaises(HTTPError):
            self.api("/ack", {"id": sent["id"]})
        self.api("/ack", {"id": sent["id"]}, token="worker-token")
        self.assertEqual(self.api("/inbox", token="worker-token"), [])
        self.assertEqual(len(self.api("/events")), 1)

    def test_input_validation(self):
        for data in ({"to": "unknown", "body": "x"}, {"to": "worker", "body": ""},
                     {"to": "worker", "body": "x" * 48001}, [], {"to": [], "body": "x"}):
            with self.assertRaises(HTTPError) as error:
                self.api("/send", data)
            self.assertEqual(error.exception.code, 400)
        with self.assertRaises(HTTPError) as error:
            self.api("/send", {"to": "worker", "body": "x" * 70000})
        self.assertEqual(error.exception.code, 413)

    def test_message_is_literal_data(self):
        text = 'quotes " \' $(touch /tmp/devflow-should-not-exist) `exit`\nsecond line\x1b[2J'
        message = self.work / "message.txt"
        message.write_text(text)
        result = self.cli("send", "leader", "--file", str(message))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.api("/inbox")[0]["body"], text)
        result = self.cli("inbox")
        self.assertNotIn("\x1b", result.stdout)
        self.assertIn("\\u001b", result.stdout)

    def test_persistent_messages_and_permissions(self):
        self.api("/send", {"to": "worker", "body": "remember me"})
        self.stop_server()
        self.process = subprocess.Popen([os.sys.executable, str(self.script), "serve"], env=self.env,
                                        stdout=subprocess.DEVNULL, stderr=subprocess.PIPE)
        for _ in range(100):
            try:
                messages = self.api("/inbox", token="worker-token")
                break
            except OSError:
                time.sleep(0.02)
        self.assertEqual(messages[0]["body"], "remember me")
        self.assertEqual((self.work / "messages.db").stat().st_mode & 0o777, 0o600)

    def test_roster_update_without_service_restart(self):
        config = json.loads(self.config.read_text())
        config["peers"]["reviewer"] = {"token": "reviewer-token"}
        self.config.write_text(json.dumps(config))
        self.api("/send", {"to": "reviewer", "body": "new role"})
        self.assertEqual(self.api("/inbox", token="reviewer-token")[0]["body"], "new role")

    def test_real_demo_worker_round_trip(self):
        worker_dir = self.work / "worker"
        worker_dir.mkdir()
        config = worker_dir / "config.json"
        config.write_text(json.dumps({"url": self.url, "token": "worker-token", "role": "worker"}))
        worker = subprocess.Popen([os.sys.executable, str(self.script), "demo-worker"],
                                  env=dict(self.env, DEVFLOW_BUS_CONFIG=str(config)),
                                  stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        try:
            sent = self.api("/send", {"to": "worker", "body": "hello hello sandbox"})
            for _ in range(80):
                messages = self.api("/inbox")
                if any("complete." in m["body"] for m in messages):
                    break
                time.sleep(0.1)
            else:
                self.fail("no worker result")
            self.assertIn("3 words; 2 unique", messages[-1]["body"])
            self.assertIn("Job #{} complete".format(sent["id"]), messages[-1]["body"])
            self.assertTrue((worker_dir / "report.txt").exists())
            self.assertFalse((self.work / "report.txt").exists())
        finally:
            worker.terminate()
            worker.wait(timeout=5)

    def test_handoff_context_rejects_running_then_copies_finished(self):
        run = self.work / ".devflow/run"
        run.mkdir(parents=True)
        (run / "status").write_text("state=running\n")
        env = {"HOME": str(self.work)}
        result = self.cli("context", extra_env=env)
        self.assertNotEqual(result.returncode, 0)
        (run / "status").write_text("state=completed\n")
        (run / "task.txt").write_text("build the feature")
        (run / "last-message.txt").write_text("finished on branch feature")
        result = self.cli("context", extra_env=env)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("build the feature", result.stdout)
        self.assertIn("finished on branch feature", result.stdout)
        self.assertIn("files are not transferred", result.stdout)


if __name__ == "__main__":
    unittest.main()
