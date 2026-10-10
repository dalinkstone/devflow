"""Exercise the actual embedded API-agent launcher/auth and hidden setup input."""
import base64
import json
import os
from pathlib import Path
import pty
import select
import shlex
import subprocess
import tempfile
import time
import unittest

ROOT = Path(__file__).resolve().parents[1]
CLI = ROOT / "bin/devflow"
PAYLOAD = subprocess.check_output([str(CLI), "__provision-script"], text=True)


class AgentTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="devflow-agents-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.home = self.root / "home"
        self.home.mkdir()
        self.dv = self.home / ".devflow"
        (self.dv / "stage").mkdir(parents=True)
        self.bin = self.home / ".local/bin"
        self.bin.mkdir(parents=True)
        self.env = dict(os.environ, HOME=str(self.home), PATH=str(self.bin) + ":" + os.environ["PATH"])
        for key in list(self.env):
            if key.startswith(("DV_", "DEVFLOW_")) or key in ("ANTHROPIC_API_KEY", "OPENAI_API_KEY", "OPENROUTER_API_KEY"):
                self.env.pop(key)
        self.launcher = self.bin / "dv-agent"
        self.launcher.write_text(PAYLOAD.split("<<'DV_DVAGENT'\n", 1)[1].split("\nDV_DVAGENT", 1)[0])
        self.launcher.chmod(0o700)
        self.provision = self.root / "provision.sh"
        self.provision.write_text(PAYLOAD)
        (self.dv / "workdir").write_text(str(self.home))

    def fake_agent(self, name, rc=0):
        path = self.bin / name
        path.write_text('#!/usr/bin/env python3\nimport json,os,sys\nfrom pathlib import Path\n'
                        'Path(os.environ["HOME"], "receipt.json").write_text(json.dumps({"args":sys.argv[1:],'
                        '"key":os.environ.get("OPENROUTER_API_KEY")}))\n' + f'sys.exit({rc})\n')
        path.chmod(0o700)

    def test_interactive_launch_and_resume(self):
        for agent in ("opencode", "pi"):
            with self.subTest(agent=agent):
                self.fake_agent(agent)
                (self.dv / "env").write_text('export OPENROUTER_API_KEY=fake-key\nexport DEVFLOW_SESSION_MODEL=openrouter/vendor/model\n')
                prompt = '-answer this "quote"; $(touch NEVER)'
                (self.dv / "task").write_text(prompt)
                subprocess.run([str(self.launcher), agent], env=self.env, check=True)
                receipt = json.loads((self.home / "receipt.json").read_text())
                self.assertEqual(receipt["args"], ["--continue", "--model", "openrouter/vendor/model",
                                                   "--prompt" if agent == "opencode" else "--", prompt])
                self.assertEqual(receipt["key"], "fake-key")
                self.assertFalse((self.home / "NEVER").exists())
                self.assertFalse((self.dv / "task").exists())
                self.assertIn("state=completed", (self.dv / "run/status").read_text())
                self.assertEqual((self.dv / "run/status").stat().st_mode & 0o777, 0o600)
                subprocess.run([str(self.launcher), agent], env=self.env, check=True)
                self.assertEqual(json.loads((self.home / "receipt.json").read_text())["args"],
                                 ["--continue", "--model", "openrouter/vendor/model"])

    def test_agent_failure_is_recorded(self):
        self.fake_agent("pi", 23)
        result = subprocess.run([str(self.launcher), "pi"], env=self.env)
        self.assertEqual(result.returncode, 23)
        self.assertIn("state=failed", (self.dv / "run/status").read_text())

    def test_auth_private_and_refresh_removes_previous_provider(self):
        for contents in ('export OPENROUTER_API_KEY="fake-key"\n', ''):
            bundle = 'DV_PROVIDER_ENV_B64=' + base64.b64encode(contents.encode()).decode() + '\n'
            (self.dv / "stage/secrets.env").write_text(bundle)
            subprocess.run(['bash', str(self.provision)], env=dict(self.env, DV_PHASE="auth"), check=True,
                           stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            self.assertEqual((self.dv / "provider.env").read_text(), contents)
            self.assertEqual((self.dv / "provider.env").stat().st_mode & 0o777, 0o600)
            self.assertFalse((self.dv / "stage/secrets.env").exists())

    def test_setup_does_not_echo_or_execute_key(self):
        for agent, prefix in (("opencode", "DEVFLOW_OPENCODE"), ("pi", "DEVFLOW_PI")):
            with self.subTest(agent=agent):
                master, slave = pty.openpty()
                cfg = self.root / (agent + "-config")
                env = dict(self.env, TERM="dumb", DEVFLOW_CONFIG_DIR=str(cfg))
                process = subprocess.Popen([str(CLI), "setup", agent], stdin=slave, stdout=slave, stderr=slave, env=env)
                os.close(slave)
                output = b""

                def until(needle):
                    nonlocal output
                    end = time.monotonic() + 10
                    while needle.encode() not in output:
                        self.assertLess(time.monotonic(), end, output.decode(errors="replace"))
                        if select.select([master], [], [], .1)[0]:
                            output += os.read(master, 65536)

                secret = 'fake-secret-$(touch BAD)-"quote"'
                try:
                    until("4) Cancel")
                    os.write(master, b"3\n")
                    until("Model ID")
                    os.write(master, b"vendor/model\n")
                    until("API key (hidden")
                    time.sleep(.1)  # Wait until read -s disables echo.
                    os.write(master, secret.encode() + b"\n")
                    until("configured; key stored privately")
                    self.assertEqual(process.wait(timeout=5), 0)
                    self.assertNotIn(secret.encode(), output)
                    self.assertNotIn(secret, (cfg / "config").read_text())
                    self.assertEqual((cfg / "secrets").stat().st_mode & 0o777, 0o600)
                    recovered = subprocess.check_output(['bash', '-c',
                        '. ' + shlex.quote(str(cfg / 'secrets')) + '; printf "%s" "$' + prefix + '_API_KEY"'], text=True)
                    self.assertEqual(recovered, secret)
                    self.assertFalse((self.home / "BAD").exists())
                finally:
                    if process.poll() is None:
                        process.kill(); process.wait()
                    os.close(master)

    def test_github_setup_keeps_token_off_argv(self):
        master, slave = pty.openpty()
        log = self.root / "gh.log"
        env = dict(self.env, TERM="dumb", FAKE_LOG=str(log),
                   PATH=str(ROOT / "tests/fakebin") + ":" + self.env["PATH"],
                   DEVFLOW_CONFIG_DIR=str(self.root / "config"))
        process = subprocess.Popen([str(CLI), "setup", "github"], stdin=slave, stdout=slave, stderr=slave, env=env)
        os.close(slave)
        output = b""

        def until(needle):
            nonlocal output
            end = time.monotonic() + 10
            while needle.encode() not in output:
                self.assertLess(time.monotonic(), end, output.decode(errors="replace"))
                if select.select([master], [], [], .1)[0]:
                    output += os.read(master, 65536)

        try:
            until("4) Cancel")
            os.write(master, b"2\n")
            until("GitHub token (hidden)")
            time.sleep(.1)
            os.write(master, b"github-super-secret\n")
            until("GitHub ready")
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertNotIn(b"github-super-secret", output)
            self.assertNotIn("github-super-secret", log.read_text())
            self.assertIn("--with-token", log.read_text())
            self.assertIn("auth setup-git", log.read_text())
        finally:
            if process.poll() is None:
                process.kill(); process.wait()
            os.close(master)


if __name__ == "__main__":
    unittest.main()
