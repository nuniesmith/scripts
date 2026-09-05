"""Exercise complete generation using fake keys/secrets inside a temporary home."""

import os
from pathlib import Path
import shutil
import stat
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/setup/generate-secrets.sh"
PRIVATE_KEY = "-----BEGIN OPENSSH PRIVATE KEY-----\nTEST_ONLY_PRIVATE_KEY\n-----END OPENSSH PRIVATE KEY-----\n"
PUBLIC_KEY = "ssh-ed25519 TEST_ONLY_PUBLIC_KEY actions@test\n"
FAKE = r'''#!/usr/bin/python3
import os
from pathlib import Path
import sys

root = Path(os.environ["SECRETS_TEST_ROOT"])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
if name == "id":
    if args == ["-u"]:
        print("0")
    sys.exit(0)
if name == "hostname":
    print("192.0.2.1" if args else "rasp-test")
    sys.exit(0)
if name == "tailscale":
    print("100.64.0.10")
    sys.exit(0)
if name == "openssl":
    print("TEST_ONLY_SECRET_" * 8)
    sys.exit(0)
if name == "sudo":
    assert args[:2] == ["-u", "actions"], args
    args = args[2:]
    if args[:2] == ["mkdir", "-p"]:
        target = Path(args[2])
        assert target.is_relative_to(root)
        target.mkdir(parents=True, exist_ok=True)
    elif args[0] == "touch":
        target = Path(args[1])
        assert target.is_relative_to(root)
        target.touch()
    elif args[0] == "ssh-keygen":
        target = Path(args[args.index("-f") + 1])
        assert target.is_relative_to(root)
        target.write_text("-----BEGIN OPENSSH PRIVATE KEY-----\nTEST_ONLY_PRIVATE_KEY\n-----END OPENSSH PRIVATE KEY-----\n")
        Path(str(target) + ".pub").write_text("ssh-ed25519 TEST_ONLY_PUBLIC_KEY actions@test\n")
    else:
        raise AssertionError("Unexpected mutation: " + repr(args))
    sys.exit(0)
raise AssertionError("Unexpected tool: " + name)
'''


class GenerateSecretsOutputTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="generate-secrets-output-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        self.tmp = self.root / "tmp"
        self.tmp.mkdir()
        self.actions_home = self.root / "actions-home"
        self.ssh_dir = self.actions_home / ".ssh"
        self.config = self.root / "sshd_config"
        self.config.write_text("# Default SSH port\n")
        for name in ("id", "hostname", "tailscale", "openssl", "sudo"):
            target = self.bin / name
            target.write_text(FAKE)
            target.chmod(0o755)
        for name in ("mktemp", "grep", "awk", "chmod", "cat", "tr", "cut", "head", "date"):
            (self.bin / name).symlink_to(shutil.which(name))
        # Redirect only absolute host paths. Commands retain production logic.
        source = SCRIPT.read_text()
        self.assertEqual(source.count('ACTIONS_HOME="/home/actions"'), 1)
        source = source.replace('ACTIONS_HOME="/home/actions"',
                                f'ACTIONS_HOME="{self.actions_home}"')
        source = source.replace("/etc/ssh/sshd_config", str(self.config))
        self.script = self.root / "generate-secrets.sh"
        self.script.write_text(source)
        self.env = {k: v for k, v in os.environ.items()
                    if k not in ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS")
                    and not k.startswith("BASH_FUNC_")}
        self.env.update(PATH=str(self.bin), SECRETS_TEST_ROOT=str(self.root),
                        TMPDIR=str(self.tmp))

    def run_script(self, *args, shell="/bin/sh", pipefail=False):
        command = [shell]
        if pipefail:
            command.extend(["-o", "pipefail"])
        result = subprocess.run([*command, str(self.script), *args],
                                input="y\n", env=self.env, cwd=self.root,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def test_no_confirm_creates_protected_credentials_without_logging_secrets(self):
        result = self.run_script("--no-confirm", "--env", "staging")
        output = result.stdout + result.stderr
        self.assertNotIn("TEST_ONLY_PRIVATE_KEY", output)
        self.assertNotIn("TEST_ONLY_SECRET", output)
        self.assertNotIn("BEGIN OPENSSH PRIVATE KEY", output)
        self.assertIn("STAGING_TAILSCALE_IP", output)
        self.assertIn("STAGING_SSH_USER", output)
        credentials, = self.tmp.glob("server_credentials_*.txt")
        self.assertEqual(stat.S_IMODE(credentials.stat().st_mode), 0o600)
        contents = credentials.read_text()
        self.assertIn(PRIVATE_KEY, contents)
        self.assertIn("STAGING_SSH_KEY", contents)
        self.assertIn("STAGING_TAILSCALE_IP | 100.64.0.10", contents)
        self.assertIn("STAGING_SSH_USER     | actions", contents)
        self.assertIn(str(credentials), output)

    def test_no_confirm_reuses_key_and_adds_public_key_only_once(self):
        self.ssh_dir.mkdir(parents=True)
        (self.ssh_dir / "id_ed25519").write_text(PRIVATE_KEY)
        (self.ssh_dir / "id_ed25519.pub").write_text(PUBLIC_KEY)
        for _ in range(2):
            result = self.run_script("--no-confirm", "--env", "prod")
            self.assertIn("Using existing SSH key", result.stdout)
            self.assertNotIn("regenerate", result.stdout)
        self.assertEqual((self.ssh_dir / "id_ed25519").read_text(), PRIVATE_KEY)
        self.assertEqual((self.ssh_dir / "authorized_keys").read_text(), PUBLIC_KEY)
        self.assertEqual(len(list(self.tmp.glob("server_credentials_*.txt"))), 2)

    def test_default_port_survives_bash_pipefail(self):
        result = self.run_script("--no-confirm", shell=shutil.which("bash"), pipefail=True)
        self.assertIn("SSH Port: 22", result.stdout)

    def test_ci_copy_output_keeps_legacy_names_and_private_summary(self):
        self.config.write_text("Port 2222\n")
        result = self.run_script("--ci-output", "--env", "dev")
        self.assertIn("SSH Port: 2222", result.stdout)
        self.assertIn("=== DEV_TAILSCALE_IP ===\n100.64.0.10", result.stdout)
        self.assertIn("=== DEV_SSH_USER ===\nactions", result.stdout)
        self.assertIn("=== DEV_HOST ===\n100.64.0.10", result.stdout)
        self.assertIn("=== DEV_USER ===\nactions", result.stdout)
        summary, = self.tmp.glob("setup_summary_*.txt")
        self.assertEqual(stat.S_IMODE(summary.stat().st_mode), 0o600)
        self.assertIn("DEV_TAILSCALE_IP", summary.read_text())
        self.assertNotIn("TEST_ONLY_PRIVATE_KEY", summary.read_text())
        self.assertNotIn("TEST_ONLY_SECRET", summary.read_text())


if __name__ == "__main__":
    unittest.main()
