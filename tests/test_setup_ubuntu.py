"""Check the setup library under its callers' strict Bash options, without installs."""

import os
from pathlib import Path
import subprocess
import unittest


SETUP_DIR = Path(__file__).resolve().parents[1] / "scripts/setup"
LIBRARY = SETUP_DIR / "setup-ubuntu.sh"


class SetupUbuntuTests(unittest.TestCase):
    def run_bash(self, *args):
        env = os.environ.copy()
        env.pop("_SETUP_UBUNTU_LOADED", None)
        return subprocess.run(
            ["bash", *args], env=env, capture_output=True, text=True, timeout=10
        )

    def test_production_help_loads_library_under_strict_mode(self):
        result = self.run_bash(str(SETUP_DIR / "setup-prod-server.sh"), "--help")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("USAGE:", result.stdout)
        self.assertIn("--skip-secrets", result.stdout)

    def test_library_can_be_sourced_twice_under_strict_mode(self):
        result = self.run_bash(
            "-euo", "pipefail", "-c",
            '. "$1"; RED=already_loaded; . "$1"; '
            '[ "$RED" = already_loaded ]; printf "loaded twice\\n"',
            "test", str(LIBRARY),
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("loaded twice", result.stdout)

    def test_detection_succeeds_without_nvidia(self):
        # Stub hardware probes only; detection may read the host's os-release,
        # but no setup/install function is called and no system files are changed.
        program = r'''
. "$1"
DEV_USER=root
uname() { printf '%s\n' "$TEST_ARCH"; }
hostname() { printf 'test-server\n'; }
lspci() { return 1; }
ls() { return 2; }
grep() {
    case "$*" in
        *'/proc/version'*) return 1 ;;
        *'/proc/cpuinfo'*|*'/sys/firmware/devicetree/base/model'*)
            [ "$TEST_PI" = true ] ;;
        *) command grep "$@" ;;
    esac
}
TEST_ARCH="$2"
TEST_PI="$3"
lib_detect_system
[ "$ARCH" = "$TEST_ARCH" ]
[ "$IS_PI" = "$TEST_PI" ]
[ "$HAS_NVIDIA" = false ]
printf 'detection completed\n'
'''
        for architecture, is_pi in (("aarch64", "true"), ("x86_64", "false")):
            with self.subTest(architecture=architecture):
                result = self.run_bash(
                    "-euo", "pipefail", "-c", program, "test", str(LIBRARY),
                    architecture, is_pi,
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertIn("detection completed", result.stdout)


if __name__ == "__main__":
    unittest.main()
