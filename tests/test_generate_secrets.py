"""Run the real script with fake setup/downloads; stop before writing secrets."""

import json
import os
from pathlib import Path
import shutil
import subprocess
import tempfile
import unittest


SCRIPT = Path(__file__).resolve().parents[1] / "scripts/setup/generate-secrets.sh"
FAKE = r'''#!/usr/bin/python3
import json
import os
from pathlib import Path
import sys

root = Path(os.environ["SECRETS_TEST_ROOT"])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
with (root / "calls").open("a") as out:
    out.write(json.dumps({"tool": name, "args": args}) + "\n")

if name == "id":
    if args == ["-u"]:
        print(os.environ.get("FAKE_UID", "0"))
        sys.exit(0)
    sys.exit(0 if (root / "actions").exists() else 1)
if name == "curl":
    url = args[1]
    assert args[0] == "-fsSL"
    assert url.startswith("https://raw.githubusercontent.com/nuniesmith/scripts/main/scripts/setup/")
    output = Path(args[args.index("-o") + 1])
    payload = ': # fake base library\n'
    if url.endswith("/setup-prod-server.sh"):
        payload = """#!/usr/bin/env bash
set -euo pipefail
. "${BASH_SOURCE[0]%/*}/setup-ubuntu.sh"
exec "$SECRETS_TEST_ROOT/bin/setup-fixture" "$@"
"""
    if url.endswith(os.environ.get("BAD_FILE", "never")):
        payload = os.environ.get("BAD_CONTENT", "<!DOCTYPE html>\n")
    output.write_text(payload)
    # A failed transfer can still leave a runnable partial script behind.
    sys.exit(22 if url.endswith(os.environ.get("FAIL_FILE", "never")) else 0)
if name == "setup-fixture":
    if os.environ.get("FAIL_SETUP"):
        sys.exit(9)
    if not os.environ.get("NO_ACTIONS"):
        (root / "actions").touch()
    if os.environ.get("INSTALL_OPENSSL"):
        target = root / "bin/openssl"
        target.write_text(Path(__file__).read_text())
        target.chmod(0o755)
    sys.exit(0)
if name == "hostname":
    print("192.0.2.1" if args else "rasp-test")
    sys.exit(0)
if name == "grep":
    sys.exit(1)
if name == "sudo":
    # Stop at the first command after preflight, before any host mutation.
    sys.exit(77)
sys.exit(99)
'''


class GenerateSecretsTests(unittest.TestCase):
    def setUp(self):
        temp = tempfile.TemporaryDirectory(prefix="generate-secrets-test-")
        self.addCleanup(temp.cleanup)
        self.root = Path(temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        (self.root / "tmp").mkdir()
        for name in ("id", "curl", "setup-fixture", "openssl", "hostname", "grep", "sudo"):
            target = self.bin / name
            target.write_text(FAKE)
            target.chmod(0o755)
        # Only harmless utilities and test doubles are reachable through PATH.
        for name in ("bash", "mktemp", "rm", "awk"):
            (self.bin / name).symlink_to(shutil.which(name))
        self.env = {k: v for k, v in os.environ.items()
                    if k not in ("BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS")
                    and not k.startswith("BASH_FUNC_")}
        self.env.update(PATH=str(self.bin), SECRETS_TEST_ROOT=str(self.root),
                        TMPDIR=str(self.root / "tmp"))

    def run_script(self, *args, shell="/bin/sh", **env):
        result = subprocess.run([shell, str(SCRIPT), *args],
                                env={**self.env, **env}, cwd=self.root,
                                capture_output=True, text=True, timeout=10)
        self.assertEqual(list((self.root / "tmp").iterdir()), [], result.stderr)
        return result

    def calls(self, tool):
        return [call["args"] for call in map(json.loads, (self.root / "calls").read_text().splitlines())
                if call["tool"] == tool]

    def test_missing_user_runs_setup_then_continues(self):
        result = self.run_script("--env", "staging", "--ci-output")
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
        self.assertIn("STAGING Environment", result.stdout)
        self.assertEqual(len(self.calls("curl")), 2)
        self.assertEqual(self.calls("setup-fixture"), [["--actions-user", "actions",
                         "--skip-secrets", "--skip-tailscale-serve", "--no-confirm"]])
        self.assertTrue(self.calls("sudo"))

    def test_bash_invocation(self):
        result = self.run_script(shell=shutil.which("bash"))
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)

    def test_existing_user_skips_setup_and_download_dependencies(self):
        (self.root / "actions").touch()
        (self.bin / "curl").unlink()
        (self.bin / "bash").unlink()
        result = self.run_script()
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)
        self.assertEqual(self.calls("setup-fixture"), [])

    def test_setup_can_install_missing_openssl(self):
        (self.bin / "openssl").unlink()
        result = self.run_script(INSTALL_OPENSSL="1")
        self.assertEqual(result.returncode, 77, result.stdout + result.stderr)

    def test_download_failures_never_execute_setup(self):
        for filename in ("setup-prod-server.sh", "setup-ubuntu.sh"):
            with self.subTest(filename=filename):
                result = self.run_script(FAIL_FILE=filename)
                self.assertEqual(result.returncode, 1)
                self.assertIn("Failed to download", result.stdout)
                self.assertEqual(self.calls("setup-fixture"), [])
                self.assertEqual(self.calls("sudo"), [])

    def test_empty_or_html_downloads_never_execute_setup(self):
        for filename in ("setup-prod-server.sh", "setup-ubuntu.sh"):
            for content in ("", "<!DOCTYPE html>\n"):
                with self.subTest(filename=filename, content=content):
                    result = self.run_script(BAD_FILE=filename, BAD_CONTENT=content)
                    self.assertEqual(result.returncode, 1)
                    self.assertIn("empty or has invalid shell syntax", result.stdout)
                    self.assertEqual(self.calls("setup-fixture"), [])

    def test_setup_failure_stops_generation(self):
        result = self.run_script(FAIL_SETUP="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Production server setup failed", result.stdout)
        self.assertEqual(self.calls("sudo"), [])

    def test_setup_must_actually_create_actions_user(self):
        result = self.run_script(NO_ACTIONS="1")
        self.assertEqual(result.returncode, 1)
        self.assertIn("user 'actions' is still missing", result.stdout)
        self.assertEqual(self.calls("sudo"), [])

    def test_missing_dependencies_fail_before_download(self):
        for dependency in ("curl", "bash"):
            with self.subTest(dependency=dependency):
                target = self.bin / dependency
                target.rename(self.bin / "hidden-dependency")
                result = self.run_script()
                (self.bin / "hidden-dependency").rename(target)
                self.assertEqual(result.returncode, 1)
                self.assertIn(f"{dependency} is required", result.stdout)
                self.assertEqual(self.calls("curl"), [])

    def test_nonroot_never_starts_setup(self):
        result = self.run_script(FAKE_UID="1000")
        self.assertEqual(result.returncode, 1)
        self.assertIn("Please run this script with sudo", result.stdout)
        self.assertEqual(self.calls("curl"), [])


if __name__ == "__main__":
    unittest.main()
