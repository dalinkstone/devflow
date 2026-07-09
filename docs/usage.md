# Usage guide

Everything you can do with devflow, with exact commands. `dv` is an alias for
`devflow` everywhere.

## Install

```bash
# curl (macOS / Linux)
curl -fsSL https://raw.githubusercontent.com/dalinkstone/devflow/main/install.sh | bash

# Homebrew
brew tap dalinkstone/devflow https://github.com/dalinkstone/devflow
brew install dalinkstone/devflow/devflow
brew install daytonaio/cli/daytona     # the sandbox engine

# from a checkout
make install                            # → ~/.local/bin/devflow (+ dv)
```

Dependencies: `daytona`, `jq`, `git`, `gh` (required); `fzf` (optional, nicer
pickers). `install.sh` installs missing ones (brew when available, otherwise
static binaries into `~/.local/bin`).

## One-time setup

```bash
devflow setup     # guided: deps → daytona login → claude auth → codex auth → gh
devflow doctor    # read-only check of everything, with fix hints
```

What each account needs:

| Account | What setup does | Manual equivalent |
|---|---|---|
| Daytona | browser sign-in (new accounts get $200 free compute) | `daytona login` or `daytona login --api-key KEY` (keys: app.daytona.io/dashboard/keys) |
| Claude (Pro/Max) | detects local login; offers `devflow token` | `devflow token` runs `claude setup-token` (1-year subscription token, stored 0600 in `~/.config/devflow/secrets`) |
| Codex (ChatGPT) | detects `~/.codex/auth.json` | run `codex` locally once, pick "Sign in with ChatGPT" |
| GitHub | detects gh login | `gh auth login` |

No Anthropic/OpenAI API keys are used anywhere. If `ANTHROPIC_API_KEY` is set
in your environment, Claude Code would silently prefer it and bill API usage —
devflow never sets it and sandboxes never receive it.

## Core workflow

```bash
devflow up [REPO] [flags]      # create (or reattach to) a session
devflow attach [NAME]          # rejoin from anywhere; restarts stopped sandboxes
devflow peek [NAME] [-w WIN]   # view the agent's screen (or window: script)
devflow ls                     # list devflow sandboxes
devflow stop [NAME|--all]      # stop compute billing; disk preserved
devflow rm [NAME|--all] [-f]   # delete (unpushed work is lost)
```

`up` REPO forms: `owner/name`, a GitHub URL, or omitted — inside a git repo it
uses that repo's origin; outside one you get a picker of your GitHub repos
(fzf if installed). `up` on an existing sandbox just attaches (idempotent);
`--fresh` recreates it.

Sizes are Daytona's fixed classes (the API rejects raw cpu/memory/disk when a
snapshot is involved — and even the default image is a snapshot). The old
`--cpu/--memory/--disk` flags and `DEVFLOW_CPU/MEMORY/DISK` config keys are
deprecated: they still work but map to the smallest size that fits. A custom
`--snapshot` brings its own resources (set at `devflow snapshot build` time).

### `devflow up` flags

| Flag | Meaning | Default |
|---|---|---|
| `-a, --agent` | `claude` \| `codex` \| `both` \| `none` | `claude` |
| `-H, --harness` | `auto` \| `omc` \| `omx` \| `both` \| `core` \| `none` | `auto` (omc for claude, omx for codex) |
| `-m, --task "…"` | hand the agent a task immediately | — |
| `-b, --branch B` | checkout (or create) branch B | repo default |
| `-n, --name N` | sandbox name | `dv-<repo>` |
| `--blank` | no repo, scratch workspace | — |
| `--pick` | force the repo picker | — |
| `--fresh` | delete + recreate existing sandbox | — |
| `--no-attach` | don't SSH in afterwards | attaches when on a TTY |
| `-s, --size S` | `small` (1cpu/1gb/3gb) \| `medium` (2cpu/4gb/8gb) \| `large` (4cpu/8gb/10gb) | `medium` |
| `--auto-stop MIN` | 0 = run until stopped | 0 |
| `--snapshot S` | custom snapshot (its size is baked in; `--size` is ignored) | Daytona default image |

### The fire-and-forget pattern

```bash
devflow up -m "fix the flaky login test, open a PR" --no-attach
# …close your laptop…
devflow peek          # later, from anywhere: is it done?
devflow attach        # join the live session
devflow mobile        # …or reconnect from your phone (see "Access paths")
```

The agent keeps working while detached because the session lives in tmux
inside the sandbox and sandboxes default to `--auto-stop 0`.

### Run a script in the sandbox

```bash
devflow up repro.sh                          # positional arg naming a file = script
devflow up owner/repo --script ci-repro.sh   # with a repo: script runs in the clone
devflow up --blank repro.sh --no-attach      # scratch sandbox, fire-and-forget
```

The script is uploaded and runs in tmux window `script`; the agent window is
untouched, so `-m` tasks and normal prompting work alongside it, and it keeps
running while you're detached.

- watch live: `devflow peek NAME -w script` — or `devflow attach` and switch
  windows (`Ctrl-b 0..9`)
- full log: `~/.devflow/script.log` in the sandbox; the exit code is appended
  as `[devflow script exit: N]` and the window stays open for inspection
- running `up … --script` again (same sandbox) replaces the window + log

### Sandboxes from inside a sandbox (siblings)

```bash
devflow up --blank repro.sh --with-daytona
```

`--with-daytona` forwards Daytona control into the sandbox: the `daytona`
CLI (version-matched to your local one), an API key (as a 0600 CLI config),
devflow itself, and jq. Scripts or agents inside can then run `devflow up`,
`devflow ls`, `daytona create`… — sandboxes created from inside are
**siblings** on your account, not children: everything is an API call to
Daytona, so there is no container-in-container problem and it composes to
any depth. devflow-in-sandbox reuses the claude/codex/gh auth that's already
there, so inner `up`s need no re-login.

Which key gets forwarded: if you logged in with `daytona login --api-key`,
that key. With a browser login (an expiring OAuth token), devflow **mints a
dedicated API key** named `devflow-sandboxes` the first time — scoped to
`write:sandboxes`/`delete:sandboxes` only, cached in
`~/.config/devflow/secrets` (0600), revocable anytime at
[app.daytona.io/dashboard/keys](https://app.daytona.io/dashboard/keys).

Opt-in for a reason: that key can create/delete sandboxes on your account
(= billing), so it's only ever forwarded with the flag — and inner sandboxes
are **not** cleaned up automatically. `devflow ls` / `devflow rm` (laptop or
sandbox) see them all; make repro scripts delete what they create.

## Inside a session

- tmux session `dv`: window `agent` (Claude/Codex, auto-resumed), window
  `shell`; with `--agent both` also window `codex`. Detach: `Ctrl-b d`.
  Mouse is on; 100k scrollback.
- Claude runs `--dangerously-skip-permissions` (the sandbox is the safety
  boundary); Codex runs `approval_policy=never`, `sandbox_mode=danger-full-access`.
- `gh` is authenticated; git identity is set; push and `gh pr create` work.
- Aliases: `dv-work` (cd to repo), `yolo` (claude, no prompts).
- Resume semantics: after a sandbox restart, `attach` recreates tmux and the
  agent continues its previous conversation (`claude --continue` /
  `codex resume --last`).

### Multi-agent harness

| Harness | Comes with | Try |
|---|---|---|
| oh-my-claudecode (claude) | 29 agents (architect, designer, security-reviewer, …), skills, HUD | `autopilot: build X` · `/team 3:executor "fix type errors"` · `ultrawork …` |
| oh-my-codex (codex) | 34-agent catalog, `omx` launcher, worktree teams | `$ultragoal "…"` · `omx team 3:executor "…"` |
| devflow core (always) | native subagents dv-engineer / dv-designer / dv-security | `@agent-dv-security review this diff` |

Notes: everything bills the subscriptions (OMC/OMX drive the official CLIs).
Parallel teams burn plan quota faster; OMC auto-pauses/resumes across Max
rate-limit windows. Harness installs are best-effort — failures warn and the
session still works (`--harness core` skips third-party entirely).

## Access paths

```bash
devflow attach NAME        # daytona ssh + tmux auto-attach (primary)
devflow ssh NAME           # same, explicit
devflow mobile NAME        # phone hand-off: QR + every reconnect path (see below)
devflow ssh-command NAME [--expires MIN]
                           # prints `ssh <token>@ssh.app.daytona.io` for
                           # machines with only an ssh client (default 24h)
devflow ssh-config NAME [--expires MIN] [--remove]
                           # managed ~/.ssh/config Host block: `ssh NAME`,
                           # VS Code/Cursor Remote-SSH, scp/rsync — re-run
                           # to refresh the token, --remove to clean up
devflow exec NAME -- CMD   # one-off remote command (buffered output)
devflow dashboard          # app.daytona.io (web terminal exists there too)
```

From another machine: install devflow + `daytona login` (and that's all —
attach/peek/stop need only Daytona auth).

Why any of these land you in the live agent: the tmux auto-attach lives in the
sandbox's `~/.profile`/`~/.bashrc`, not in the `devflow` client. So **every**
interactive SSH login — `attach`, `ssh`, the raw `ssh <token>@…` line, or the
dashboard web terminal — drops straight into the running `dv` tmux session and
its agent. Detach with `Ctrl-b d`; the session keeps running.

### Start on your laptop, finish from your phone

The end-to-end flow — kick work off, close the laptop, reconnect from a phone
or a second machine:

```bash
# 1. laptop: start the agent working and walk away
devflow up -m "refactor the auth module, open a PR" --no-attach

# 2. laptop, before you leave: put the session on your phone
devflow mobile              # (alias: devflow qr; name optional with one sandbox)
```

`devflow mobile` renders a **QR code in the terminal** — point your phone's
camera at it and the session opens in your SSH app in one tap. The QR encodes
the tokenized session as an `ssh://` URI (Termius, Blink and ConnectBot all
register that scheme) and is generated locally by `qrencode` (a devflow brew
dependency; `apt install qrencode` elsewhere) — the token never touches a
third-party service. The matching plain `ssh <token>@ssh.app.daytona.io` line
is printed below the QR and auto-copied to your clipboard. Flags:
`--expires 10080` mints a ~7-day token (default 24h), `--no-qr` / `--no-copy`
opt out.

| Device | How to get back in |
|---|---|
| **Android** | Point the camera (or Google Lens) at the QR → opens in **Termius**/**ConnectBot**. **Termux** has no `ssh://` handler — paste the printed line there instead. For the full CLI: Termux → `pkg install curl` → run devflow's `install.sh`, `daytona login`, `devflow attach`. A UserLAnd/Ubuntu shell works the same way. |
| **iPhone/iPad** | Point the camera at the QR → one tap opens **Termius**/**Blink**. Or paste the line — the clipboard auto-copy plus Universal Clipboard means it's often already on the phone. |
| **another Mac/Linux** | Paste the `ssh …` line into Terminal (it's on your clipboard) — or install devflow + `daytona login` + `devflow attach` for the richer client (peek, stop, restart-on-attach). For your editor: `devflow ssh-config NAME` → open the host in VS Code/Cursor Remote-SSH. |
| **only a browser** | Open [app.daytona.io](https://app.daytona.io), pick the sandbox, open its Terminal. Zero install. |

The QR / `ssh …` line needs nothing installed but an SSH app and works until
the token expires. The full-devflow path is more capable (it restarts a
stopped sandbox on `attach`, and gives you `peek`/`stop`/`ls`); it needs only
`daytona login`, no re-auth of Claude/Codex. Either way you land in the same
tmux agent that's been running the whole time.

### No phone on you when you mint? Minted nothing at all?

`devflow mobile --send` delivers the reconnect line to the phone through a
channel that transports it on its own — nothing to scan, nothing to carry.
Auto picks the first configured of: **push → 1Password → Bitwarden → Apple
Notes**; force one with `--send push|op|bw|note`. `devflow doctor` shows
which channels you have.

- **Push notification (works for *every* laptop × phone combo)** — one-time
  setup: `devflow mobile --setup-push` mints a private high-entropy topic
  and shows a subscribe QR; install the free, open-source
  [ntfy](https://ntfy.sh) app (Android: Play/F-Droid · iPhone: App Store)
  and subscribe. From then on, `devflow mobile --send` from **any** macOS or
  Linux machine raises a real push notification on the phone, and **tapping
  it opens the session straight in your SSH app** — the notification's click
  action carries the `ssh://` link, so consumption is programmatic, not
  copy-paste. Trade-off to know: the line transits (and is cached ~12h by)
  the push server. The topic name is the password (ntfy's documented model),
  the token self-expires, and you can self-host:
  `devflow config set DEVFLOW_NTFY_URL https://ntfy.example.com`.
- **Password vault (also every combo, E2E-encrypted)** — **1Password**
  (`op` CLI) or **Bitwarden** (`bw` CLI + `BW_SESSION`): the line lands as a
  Secure Note in the vault app on any phone. The most secrets-appropriate
  channel — use it if you already run a vault; the CLIs exist for macOS and
  Linux alike.
- **Apple Notes** — macOS laptop + iPhone only (iCloud carries it). Zero
  install, but consumption is manual (open Notes, copy/tap). The
  convenience corner, not the general answer.
- **Park a pass file** — `devflow mobile --out pass.html` (add `--open`)
  writes a self-contained HTML pass (SVG QR + line + expiry): AirDrop it
  later or drop it in a folder your phone syncs. `chmod 600`, embeds the
  live token.
- **Mint nothing, use your logins** — from any browser on any device:
  [app.daytona.io](https://app.daytona.io) → sandbox → Terminal (just your
  Daytona login). Or any machine with devflow installed: `daytona login` +
  `devflow attach`. Both need zero preparation on the laptop.

Which channels cover which laptop/phone pair:

| laptop \ phone | Android | iPhone |
|---|---|---|
| **macOS** | push · vault · QR-scan | push · vault · Apple Notes · QR-scan · clipboard |
| **Ubuntu/Linux** | push · vault · QR-scan | push · vault · QR-scan |

(QR-scan needs the phone in hand at mint time; everything else doesn't. The
browser dashboard works from every cell with zero prep.)

And to make forgetting impossible — **auto-handoff**:

```bash
devflow config set DEVFLOW_AUTO_HANDOFF push   # or: auto | op | bw | note
```

Every `devflow up` then mints a token and sends the reconnect line through
that channel automatically, right after provisioning. Kick off a session and
walk away — it's already on your phone, every time, without running
`devflow mobile` at all. Best-effort: if minting or sending fails it warns
and the session comes up normally.

Tip: mint once with a long validity (`--expires 10080` = a week) and save the
`ssh …` line as a host in an SSH app that syncs across your devices (Termius
does) — a standing door back in from everything you own, no laptop needed.
Longer validity means a bigger window if the token leaks; pick your trade-off.

Note: `devflow mobile` / `ssh-command` mint the token from your Daytona API
key, so run them from a machine that has `daytona login` (e.g. the laptop
before you leave). On a phone with only an SSH app, scan a QR you minted
earlier; on a phone with full devflow, just `devflow attach`.

## Auth upkeep

```bash
devflow sync [NAME]   # re-harvest local claude/codex/gh auth into a sandbox
devflow token         # mint + store the 1-year Claude subscription token
```

If Codex auth goes stale inside a sandbox: `devflow sync`, or run
`codex login --device-auth` in the sandbox shell.

## Configuration

```bash
devflow config list | get KEY | set KEY VALUE | edit
```

Keys (file: `~/.config/devflow/config`, env vars override the file):
`DEVFLOW_AGENT`, `DEVFLOW_HARNESS`, `DEVFLOW_SIZE` (small|medium|large;
`DEVFLOW_CPU`/`MEMORY`/`DISK` are deprecated and map to the smallest size
that fits), `DEVFLOW_AUTO_STOP` (min), `DEVFLOW_TARGET` (us|eu),
`DEVFLOW_SNAPSHOT`, `DEVFLOW_CLAUDE_AUTH` (auto|token|creds),
`DEVFLOW_AUTO_HANDOFF` (off|auto|push|op|bw|note — send the reconnect line
to your phone after every `up`), `DEVFLOW_NTFY_URL` (push server,
self-hostable), `DEVFLOW_WORKROOT`, `DEVFLOW_EXEC_STYLE` (auto-probed;
leave alone). Secrets in `~/.config/devflow/secrets` (0600):
`DEVFLOW_CLAUDE_TOKEN`, `DEVFLOW_NTFY_TOPIC`.

## Faster starts

```bash
devflow snapshot build [--size S]  # one-time server-side image build; becomes default
devflow snapshot dockerfile        # print the Dockerfile it uses
```

Prebakes claude/codex/gh/tmux/node + both harnesses **plus Go, bun, uv and
build-essential** so `up` skips installs and agents get real toolchains from
second zero. A snapshot bakes its resources, so the name carries the size
(`devflow-base-<version>-<size>`, default size from your config). Want more
than one size? Build each once — they coexist; `DEVFLOW_SNAPSHOT` (set
automatically by the last build) picks which one `up` uses.

## Costs & lifecycle

- Daytona bills usage (~$0.05/vCPU-h + RAM/disk); the default `medium` size
  (2cpu/4GB) ≈ **$0.13/h while running**. New accounts: $200 free.
- devflow defaults to **auto-stop 0** because Daytona's idle timer ignores
  running processes (only SSH/API traffic resets it) — a 15-min auto-stop
  would kill detached agents mid-task. So run `devflow stop --all` when done.
- stopped → disk-only cost; `attach` restarts + resumes. ~7 days stopped →
  archived to object storage (slower first attach). `rm` deletes.
- Free-tier note: Tier 1/2 sandboxes have an egress whitelist (GitHub, npm,
  pip, Anthropic, OpenAI, …) — agents work; arbitrary hosts need Tier 3+.

## Troubleshooting

| Symptom | Fix |
|---|---|
| anything unclear | `devflow doctor` |
| "not logged in to Daytona" | `daytona login` (or `devflow setup`) |
| agent says logged out | `devflow sync NAME` |
| claude refuses bypass mode | sandbox user is root (custom image) — devflow falls back to acceptEdits; prefer non-root images |
| harness missing | `devflow exec NAME -- 'tail -20 ~/.devflow/omc-install.log ~/.devflow/omx-install.log'` |
| daytona CLI/API version-mismatch warning | `brew upgrade daytonaio/cli/daytona` |
| create fails: "Cannot specify Sandbox resources when using a snapshot" | you're on an old devflow that passes raw `--cpu/--memory/--disk` — update it; sizes are now `--size small\|medium\|large` |
| deep inspection | `devflow ssh NAME`, then `~/.devflow/` holds all state/logs |
