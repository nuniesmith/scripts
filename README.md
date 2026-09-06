# scripts

## Generate server secrets

Download the raw script and run it as root:

```bash
curl -fL https://raw.githubusercontent.com/nuniesmith/scripts/main/src/setup/generate-secrets.sh \
  -o generate-secrets.sh &&
bash -n generate-secrets.sh &&
sudo bash generate-secrets.sh
```

If the `actions` user is missing, the script automatically downloads
`setup-prod-server.sh` and its `setup-ubuntu.sh` library, checks their shell
syntax, and runs production setup without confirmation prompts. This runs the
installer's default system updates, Docker, SSH, firewall, and Tailscale setup.
It requires `curl` and Bash; OpenSSL is checked after setup can install it.

The installer skips secrets generation and Tailscale HTTPS configuration during
this automatic run. Once setup succeeds and the `actions` user exists, the
original script continues generating secrets. Complete Tailscale sign-in and
HTTPS configuration using the setup summary's instructions. Downloads are
removed on success or failure; any download or setup failure stops generation.
When `actions` already exists, server setup is skipped.

Secrets default to the `PROD_` prefix. Use `--env dev` or `--env staging` for
another prefix. For automation, use `--no-confirm` to preserve an existing SSH
key without prompting; secret values stay in a private temporary credentials
file and its path is printed. `--ci-output` is a legacy option that prints the
private key and application secrets for manual copying: do not use it in GitHub
Actions logs. These options affect secrets; the automatic server installer is
always `setup-prod-server.sh`.

The shared actions use `PROD_SSH_KEY`, `PROD_SSH_PORT`, `PROD_TAILSCALE_IP`, and
`PROD_SSH_USER` (`actions`). The old `PROD_HOST` and `PROD_USER` names are legacy
aliases; new workflows should use the names above. Change the prefix for other
environments. Tailscale must be connected before copying its IP into GitHub.
The generator does not upload repository secrets. Tailscale OAuth credentials
and registry credentials must come from those services; generated application
secrets should be selected to match the application's actual configuration.

Run the isolated setup tests (no server provisioning or real secrets):

```bash
python3 -m unittest discover -s tests -p 'test_generate_secrets*.py' -v
python3 -m unittest discover -s tests -p 'test_setup_ubuntu.py' -v
```

## ChatGPT / Codex session on Ubuntu

`src/utils/chatgpt.sh` is the Codex counterpart to `claude.sh`. It runs on
the machine where you invoke it: to work on Oryx, SSH into Oryx first. It does
not connect to another machine merely because you use the same account.

Install `tmux` and `curl` if needed (`sudo apt install tmux curl`). The wrapper
can install a **missing** [official Codex CLI](https://learn.chatgpt.com/docs/cli)
when explicitly given `--install`; otherwise it makes no installation attempt.
Run the wrapper as your normal user, **not with sudo**. No npm is required.

From this repository:

```bash
# First run: install Codex if missing, then log in and start the terminal.
bash src/utils/chatgpt.sh --install --device-auth /path/to/fks-development-checkout

# Start Codex in a development checkout, or reattach to the existing session.
bash src/utils/chatgpt.sh /path/to/fks-development-checkout

# Enable experimental app remote access as well, if supported by your CLI.
bash src/utils/chatgpt.sh --remote /path/to/fks-development-checkout

# Run separately to enable remote access and display a private pairing code.
bash src/utils/chatgpt.sh --pair
```

`--install` downloads the installer from `https://chatgpt.com/codex/install.sh`
over HTTPS into a private temporary file, checks download completion and shell
syntax, then runs it without sudo. It uses the upstream noninteractive option
so installation cannot auto-launch Codex before the wrapper applies its launch
settings. This is a syntax check, not independent cryptographic verification of
the installer; release verification is delegated to OpenAI's installer.

The standalone CLI goes into `$HOME/.local/bin`, or `CODEX_INSTALL_DIR` if you
set an absolute custom directory. The wrapper discovers that location even
when it is not yet on your shell's `PATH`, and makes it available to the tmux
session. For direct `codex` commands in your current shell, use
`export PATH="${CODEX_INSTALL_DIR:-$HOME/.local/bin}:$PATH"`. The wrapper itself
does not edit shell profiles or install Ubuntu packages. Existing Codex
installations and running sessions are left alone: `--install` is **not an
upgrade command**. Install/download failures stop before login or remote start.
No FKS service is installed, restarted, or changed.

The default tmux session is `chatgpt`. Detach with **Ctrl-b, then d**, and run
the script again to return. Inside tmux it switches clients instead of nesting.
Detaching/disconnecting leaves Codex running; rebooting does not. Exiting Codex
ends its pane/session (unless your tmux configuration preserves dead panes).
An existing session retains its original directory, model, and permissions;
the wrapper does not restart it. Use another session name for another checkout:

```bash
CHATGPT_SESSION=chatgpt-review bash src/utils/chatgpt.sh /path/to/review-checkout
```

The launcher uses your configured model and reasoning effort. New terminal
sessions explicitly use `workspace-write` and `on-request` approvals. It unsets
API-key/access-token environment overrides, requires ChatGPT account login, and
refuses an existing non-ChatGPT login rather than silently replacing it. A
missing login starts the normal login flow; SSH automatically selects device
login, which you can also request with `--device-auth`. Device login may need
enabling in your account/workspace. See [authentication](https://learn.chatgpt.com/docs/auth).

### Remote access caveats

Normal tmux mode works over SSH without app pairing. `--remote` and `--pair`
use the **experimental** `codex remote-control` commands, capability-checked at
runtime. They were inspected in CLI `0.153.0-alpha.5`; a successful help check
does not prove account/device compatibility. Pairing codes must not be pasted
into a repository, chat, or log. This launcher does not prove phone pairing on
Linux: the [public remote-access guide](https://learn.chatgpt.com/docs/remote-connections)
currently documents Mac/Windows mobile hosts and desktop SSH projects.

Remote control is **host-wide**, not limited to the named tmux session, and the
daemon can remain enabled after detaching or exiting. It can also be shared
with other Codex clients; the terminal's sandbox settings do not automatically
constrain other remote chats. Review host/app permissions before pairing. To
disable remote control, deliberately run `codex remote-control stop`; it stops
the shared app-server daemon and may interrupt other Codex work. The wrapper
never stops it automatically or exposes a public listening port.

Use a private network/VPN for SSH. Keep Claude and Codex changes in separate
development checkouts/worktrees, with no trading credentials or production
Docker socket access. Approval prompts are not a substitute for OS-level
isolation. Neither tool should restart trading connectors, deploy, or change
live orders without explicit authorization.

Run the isolated launcher tests (no real Codex, login, network, or tmux server):

```bash
python3 -m unittest discover -s tests -p 'test_chatgpt.py' -v
```

Optionally set `CHATGPT_TEST_TMUX` to an absolute tmux executable path to also
exercise real session creation using a private temporary socket and fake Codex.
That test stops only its own private server and does not attach a real terminal
client or contact OpenAI.
