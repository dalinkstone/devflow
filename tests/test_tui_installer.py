"""Run the real native-helper install function against local release fixtures."""
import hashlib
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

ROOT = Path(__file__).resolve().parents[1]
INSTALLER = (ROOT / 'install.sh').read_text()
FUNCTION = INSTALLER[INSTALLER.index('install_tui() {'):INSTALLER.index('\nif install_tui;')]


class Installer(unittest.TestCase):
    def run_install(self, checksum):
        with tempfile.TemporaryDirectory(prefix='dv-tui-install-') as temp:
            root = Path(temp)
            target = root / 'target'
            target.mkdir()
            (target / 'devflow').write_text('DEVFLOW_VERSION="0.11.0"\n')
            (target / 'devflow-tui').write_text('previous working binary')
            source = root / 'release'
            source.mkdir()
            binary = b'fixture binary, not executed'
            (source / 'devflow-tui-linux-arm64').write_bytes(binary)
            (source / 'checksums.txt').write_text(checksum(hashlib.sha256(binary).hexdigest()))
            fake = root / 'curl'
            fake.write_text('#!/bin/sh\ncp "$FIXTURE/${2##*/}" "$4"\n')
            fake.chmod(0o700)
            script = root / 'check.sh'
            script.write_text('''set -u
have() { command -v "$1" >/dev/null 2>&1; }
REPO=dalinkstone/devflow
OS=linux
ARCH=arm64
''' + FUNCTION + '\ninstall_tui\n')
            result = subprocess.run(['bash', str(script)], env=dict(os.environ,
                PATH=str(root) + ':' + os.environ['PATH'], FIXTURE=str(source),
                SCRIPT_DIR=str(root), INSTALL_DIR=str(target)), capture_output=True)
            return result.returncode, (target / 'devflow-tui').read_bytes()

    def test_matching_checksum_installs(self):
        rc, content = self.run_install(lambda sha: sha + '  devflow-tui-linux-arm64\n')
        self.assertEqual(rc, 0)
        self.assertEqual(content, b'fixture binary, not executed')

    def test_wrong_checksum_keeps_previous_helper(self):
        rc, content = self.run_install(lambda sha: '0' * 64 + '  devflow-tui-linux-arm64\n')
        self.assertNotEqual(rc, 0)
        self.assertEqual(content, b'previous working binary')

    def test_wrong_platform_keeps_previous_helper(self):
        rc, content = self.run_install(lambda sha: sha + '  devflow-tui-darwin-arm64\n')
        self.assertNotEqual(rc, 0)
        self.assertEqual(content, b'previous working binary')


if __name__ == '__main__':
    unittest.main()
