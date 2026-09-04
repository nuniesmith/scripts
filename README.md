# scripts

## ChatGPT / Codex session on Ubuntu

`scripts/utils/chatgpt.sh` is the Codex counterpart to `claude.sh`. It runs on
the machine where you invoke it: to work on Oryx, SSH into Oryx first. It does
not connect to another machine merely because you use the same account.

Install `tmux` and the [official Codex CLI](https://learn.chatgpt.com/docs/cli),
and make sure `codex --version` works in your login shell. The wrapper does not
install/update packages, edit shell configuration, or touch FKS services.

From this repository:

```bash
# Start Codex in a development checkout, or reattach to the existing session.
bash scripts/utils/chatgpt.sh /path/to/fks-development-checkout

# Enable experimental app remote access as well, if supported by your CLI.
bash scripts/utils/chatgpt.sh --remote /path/to/fks-development-checkout

# Run separately to enable remote access and display a private pairing code.
bash scripts/utils/chatgpt.sh --pair
```

The default tmux session is `chatgpt`. Detach with **Ctrl-b, then d**, and run
the script again to return. Inside tmux it switches clients instead of nesting.
Detaching/disconnecting leaves Codex running; rebooting does not. Exiting Codex
ends its pane/session (unless your tmux configuration preserves dead panes).
An existing session retains its original directory, model, and permissions;
the wrapper does not restart it. Use another session name for another checkout:

```bash
CHATGPT_SESSION=chatgpt-review bash scripts/utils/chatgpt.sh /path/to/review-checkout
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
