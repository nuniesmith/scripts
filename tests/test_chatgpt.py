"""Exercise the real Bash launcher with fake Codex/tmux, never live services."""

import json
import os
from pathlib import Path
import subprocess
import tempfile
import time
import unittest


LAUNCHER = Path(__file__).resolve().parents[1] / "scripts/utils/chatgpt.sh"
FAKE = r'''#!/usr/bin/python3
import json
import os
from pathlib import Path
import subprocess
import sys

root = Path(os.environ["LAUNCHER_TEST_ROOT"])
name = Path(sys.argv[0]).name
args = sys.argv[1:]
keys = ("OPENAI_API_KEY", "CODEX_API_KEY", "CODEX_ACCESS_TOKEN")
with (root / "calls").open("a") as out:
    out.write(json.dumps({"tool": name, "args": args, "cwd": os.getcwd(),
                          "api_env": any(k in os.environ for k in keys),
                          "codex_home": os.environ.get("CODEX_HOME")}) + "\n")

if name == "codex":
    while args[:1] == ["-c"]:
        args = args[2:]
    if args == ["remote-control", "--help"]:
        if os.environ.get("FAKE_UNSUPPORTED"):
            # An old CLI might show generic help with exit status zero.
            print("Usage: codex [OPTIONS] [PROMPT]")
        else:
            print("Usage: codex remote-control [OPTIONS] [COMMAND]")
    elif args == ["login", "status"]:
        state = (root / "auth").read_text() if (root / "auth").exists() else "ok"
        if state == "none":
            sys.exit(1)
        print("Logged in using ChatGPT" if state == "ok" else "Logged in using an API key")
    elif args[:1] == ["login"]:
        if os.environ.get("FAKE_LOGIN_FAIL"):
            sys.exit(1)
        (root / "auth").write_text(os.environ.get("FAKE_LOGIN_RESULT", "ok"))
    elif args == ["remote-control", "start"]:
        sys.exit(int(os.environ.get("FAKE_REMOTE_FAIL", "0")))
    elif args == ["remote-control", "pair"]:
        print("FAKE-PAIRING-CODE")
        sys.exit(int(os.environ.get("FAKE_PAIR_FAIL", "0")))
    elif os.environ.get("LAUNCHER_TEST_REAL_TMUX"):
        # Keep the fake interactive client alive until the private server stops.
        sys.stdin.readline()
    sys.exit(0)

target = args[args.index("-t") + 1] if "-t" in args else ""
session_file = root / "session"
if args[0] == "has-session":
    expected = "=" + session_file.read_text() if session_file.exists() else ""
    sys.exit(0 if target == expected and expected else 1)
if args[0] == "new-session":
    session = args[args.index("-s") + 1]
    if os.environ.get("FAKE_CREATE_FAIL"):
        sys.exit(1)
    session_file.write_text(session)
    if os.environ.get("FAKE_CREATE_RACE"):
        sys.exit(1)
    start = args.index("/usr/bin/env")
    env = os.environ.copy()
    # Simulate credentials cached in an older tmux server environment.
    for key in keys:
        env[key] = "fake-server-secret"
    for i, value in enumerate(args[:start]):
        if value == "-e":
            key, data = args[i + 1].split("=", 1)
            env[key] = data
    subprocess.run(args[start:], env=env, cwd=args[args.index("-c") + 1], check=True)
    sys.exit(0)
if args[0] in ("attach-session", "switch-client"):
    sys.exit(int(os.environ.get("FAKE_ATTACH_FAIL", "0")))
sys.exit(2)
'''


class LauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="chatgpt-launcher-test-")
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.bin = self.root / "bin"
        self.bin.mkdir()
        for name in ("codex", "tmux"):
            path = self.bin / name
            path.write_text(FAKE)
            path.chmod(0o755)
        # Only controlled executables on PATH: missing dependencies cannot fall
        # through to the user's real Codex or tmux installation.
        (self.bin / "cat").symlink_to("/usr/bin/cat")
        self.env = {k: v for k, v in os.environ.items()
                    if k not in ("TMUX", "SSH_CONNECTION", "SSH_TTY", "CHATGPT_SESSION",
                                 "BASH_ENV", "ENV", "SHELLOPTS", "BASHOPTS")
                    and not k.startswith("BASH_FUNC_")}
        self.env.update(PATH=str(self.bin), LAUNCHER_TEST_ROOT=str(self.root),
                        CODEX_HOME=str(self.root / "codex-home"),
                        OPENAI_API_KEY="fake-client-secret",
                        CODEX_API_KEY="fake-client-secret",
                        CODEX_ACCESS_TOKEN="fake-client-secret")

    def run_launcher(self, *args, expected=0, **env):
        result = subprocess.run(["/bin/bash", str(LAUNCHER), *map(str, args)],
                                env=self.env | env, cwd=self.root, text=True,
                                capture_output=True, timeout=10)
        self.assertEqual(result.returncode, expected, result.stdout + result.stderr)
        self.assertNotIn("fake-client-secret", result.stdout + result.stderr)
        self.assertNotIn("fake-server-secret", result.stdout + result.stderr)
        return result

    def calls(self, tool=None):
        path = self.root / "calls"
        calls = [json.loads(line) for line in path.read_text().splitlines()] if path.exists() else []
        return [c for c in calls if tool is None or c["tool"] == tool]

    def existing(self, name="chatgpt"):
        (self.root / "session").write_text(name)

    def test_new_session_and_sanitized_child(self):
        self.run_launcher(self.root)
        launch = self.calls("codex")[-1]
        self.assertEqual(launch["cwd"], str(self.root))
        self.assertIn('forced_login_method="chatgpt"', launch["args"])
        self.assertEqual(launch["args"][-4:],
                         ["--sandbox", "workspace-write", "--ask-for-approval", "on-request"])
        self.assertNotIn("--model", launch["args"])
        self.assertEqual(launch["codex_home"], self.env["CODEX_HOME"])
        self.assertFalse(any(c["api_env"] for c in self.calls("codex")))
        self.assertEqual(self.calls()[-1]["args"], ["attach-session", "-t", "=chatgpt"])
        self.assertFalse(any("remote-control" in c["args"] for c in self.calls()))

    def test_existing_attaches_without_codex_or_login(self):
        self.existing()
        (self.bin / "codex").unlink()
        self.run_launcher("/nonexistent/directory/is/ignored")
        self.assertEqual(len(self.calls()), 2)
        self.assertEqual(self.calls()[-1]["args"][0], "attach-session")

    def test_existing_inside_tmux_switches(self):
        self.existing()
        self.run_launcher(TMUX="fake-current-client")
        self.assertEqual(self.calls()[-1]["args"], ["switch-client", "-t", "=chatgpt"])

    def test_session_matching_is_exact(self):
        self.existing("chatgpt-other")
        self.run_launcher(self.root)
        self.assertTrue(any(c["args"][0] == "new-session" for c in self.calls("tmux")))

    def test_custom_session(self):
        self.run_launcher(self.root, CHATGPT_SESSION="chatgpt-review")
        self.assertEqual(self.calls()[-1]["args"][-1], "=chatgpt-review")

    def test_default_directory_is_home(self):
        self.run_launcher()
        self.assertEqual(self.calls("codex")[-1]["cwd"], str(Path(self.env["HOME"]).resolve()))

    def test_paths_with_spaces_metacharacters_and_leading_dash(self):
        directory = self.root / "-repo with 'quotes'; $(touch PWNED)"
        directory.mkdir()
        self.run_launcher("--", directory.name)
        self.assertEqual(self.calls("codex")[-1]["cwd"], str(directory))
        self.assertFalse((self.root / "PWNED").exists())

    def test_invalid_inputs_do_not_start_anything(self):
        for args in (("--bad",), ("one", "two"), ("--", "one", "two"),
                     ("/does-not-exist",), ("--pair", str(self.root))):
            with self.subTest(args=args):
                self.run_launcher(*args, expected=1)
                self.assertFalse(self.calls("codex"))
        self.run_launcher(expected=1, CHATGPT_SESSION="bad:session")

    def test_help_needs_no_dependencies(self):
        (self.bin / "codex").unlink()
        (self.bin / "tmux").unlink()
        self.assertIn("Usage:", self.run_launcher("--help").stdout)
        self.assertFalse(self.calls())

    def test_missing_dependencies(self):
        for name in ("codex", "tmux"):
            with self.subTest(name=name):
                path = self.bin / name
                path.rename(self.bin / (name + ".saved"))
                result = self.run_launcher(self.root, expected=1)
                self.assertIn("missing", result.stderr)
                (self.bin / (name + ".saved")).rename(path)

    def test_login_modes(self):
        for options, environment, expected in (
            ([], {}, ["login"]),
            (["--device-auth"], {}, ["login", "--device-auth"]),
            ([], {"SSH_CONNECTION": "fake SSH connection"}, ["login", "--device-auth"]),
            ([], {"SSH_TTY": "/dev/pts/fake"}, ["login", "--device-auth"]),
        ):
            with self.subTest(options=options, environment=environment):
                (self.root / "auth").write_text("none")
                (self.root / "session").unlink(missing_ok=True)
                self.run_launcher(*options, self.root, **environment)
                logins = [c for c in self.calls("codex") if c["args"][0] == "login"
                          and c["args"] != ["login", "status"]]
                self.assertEqual(logins[-1]["args"], expected)

    def test_failed_login_does_not_launch(self):
        (self.root / "auth").write_text("none")
        self.run_launcher(self.root, expected=1, FAKE_LOGIN_FAIL="1")
        self.assertFalse(any(c["args"][0] == "new-session" for c in self.calls("tmux")))

    def test_non_chatgpt_auth_is_refused_not_overwritten(self):
        (self.root / "auth").write_text("api")
        self.run_launcher(self.root, expected=1)
        self.assertEqual([c["args"] for c in self.calls("codex")], [["login", "status"]])
        self.assertEqual((self.root / "auth").read_text(), "api")

    def test_login_success_must_be_verified(self):
        (self.root / "auth").write_text("none")
        self.run_launcher(self.root, expected=1, FAKE_LOGIN_RESULT="api")
        self.assertFalse((self.root / "session").exists())

    def test_remote_explicitly_starts_before_launch(self):
        self.run_launcher("--remote", self.root)
        calls = self.calls()
        start = next(i for i, c in enumerate(calls) if c["args"][-2:] == ["remote-control", "start"])
        new = next(i for i, c in enumerate(calls) if c["args"][0] == "new-session")
        self.assertLess(start, new)
        self.assertFalse(any("pair" in c["args"] for c in calls))

    def test_remote_can_be_enabled_for_existing_session(self):
        self.existing()
        self.run_launcher("--remote", "/nonexistent/directory/is/ignored")
        self.assertFalse(any(c["args"][0] == "new-session" for c in self.calls("tmux")))
        self.assertTrue(any(c["args"][-2:] == ["remote-control", "start"] for c in self.calls()))

    def test_pair_only_does_not_need_tmux(self):
        (self.bin / "tmux").unlink()
        result = self.run_launcher("--pair")
        self.assertIn("FAKE-PAIRING-CODE", result.stdout)
        self.assertFalse(self.calls("tmux"))

    def test_unsupported_remote_fails_before_login(self):
        self.run_launcher("--remote", self.root, expected=1, FAKE_UNSUPPORTED="1")
        self.assertEqual(len(self.calls("codex")), 1)
        self.assertFalse((self.root / "session").exists())

    def test_remote_start_and_pair_failure_propagate(self):
        self.run_launcher("--remote", self.root, expected=1, FAKE_REMOTE_FAIL="1")
        self.assertFalse((self.root / "session").exists())
        self.run_launcher("--pair", expected=7, FAKE_PAIR_FAIL="7")

    def test_concurrent_creation_attaches_without_replacing(self):
        self.run_launcher(self.root, FAKE_CREATE_RACE="1")
        self.assertEqual(self.calls()[-1]["args"][0], "attach-session")

    def test_create_failure_does_not_attach(self):
        self.run_launcher(self.root, expected=1, FAKE_CREATE_FAIL="1")
        self.assertFalse(any(c["args"][0] == "attach-session" for c in self.calls("tmux")))

    def test_attach_failure_propagates(self):
        self.existing()
        self.run_launcher(expected=9, FAKE_ATTACH_FAIL="9")

    @unittest.skipUnless(os.environ.get("CHATGPT_TEST_TMUX"), "optional real tmux binary not supplied")
    def test_real_tmux_launch_with_private_socket(self):
        binary = str(Path(os.environ["CHATGPT_TEST_TMUX"]).resolve())
        socket = str(self.root / "private-tmux.sock")
        command = [binary, "-S", socket, "-f", "/dev/null"]
        env = self.env | {"LAUNCHER_TEST_REAL_TMUX": "1"}
        # Pre-existing server with fake API keys, but no access to user tmux.
        subprocess.run(command + ["new-session", "-d", "-s", "keeper", "-c", str(self.root),
                                   "/usr/bin/python3", "-c", "import signal; signal.pause()"],
                       env=env, check=True, capture_output=True, timeout=10)
        try:
            # Route every tmux call to the private socket. Noninteractive attach
            # is replaced with a real target existence check; unit tests above
            # cover attach vs switch-client selection.
            wrapper = '#!/usr/bin/python3\nimport os, sys\n'
            wrapper += 'args = sys.argv[1:]\n'
            wrapper += 'if args[0] == "attach-session": args[0] = "has-session"\n'
            wrapper += f'os.execv({binary!r}, {command!r} + args)\n'
            (self.bin / "tmux").write_text(wrapper)
            directory = self.root / "real tmux 'quotes' $(touch PWNED)"
            directory.mkdir()
            self.run_launcher(directory, LAUNCHER_TEST_REAL_TMUX="1")
            deadline = time.monotonic() + 5
            while time.monotonic() < deadline:
                launches = [c for c in self.calls("codex") if "--sandbox" in c["args"]]
                if launches:
                    break
                time.sleep(0.05)
            self.assertEqual(len(launches), 1)
            self.assertEqual(launches[0]["cwd"], str(directory))
            self.assertFalse(launches[0]["api_env"])
            self.assertEqual(launches[0]["codex_home"], self.env["CODEX_HOME"])
            self.assertFalse((self.root / "PWNED").exists())
            self.run_launcher("/ignored/nonexistent/path", LAUNCHER_TEST_REAL_TMUX="1")
            self.assertEqual(len([c for c in self.calls("codex") if "--sandbox" in c["args"]]), 1)
        finally:
            subprocess.run(command + ["kill-server"], env=env, capture_output=True, timeout=10)


if __name__ == "__main__":
    unittest.main()
