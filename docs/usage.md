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
devflow peek [NAME] [--lines N]# view the agent's screen without attaching
devflow ls                     # list devflow sandboxes
devflow stop [NAME|--all]      # stop compute billing; disk preserved
devflow rm [NAME|--all] [-f]   # delete (unpushed work is lost)
```

`up` REPO forms: `owner/name`, a GitHub URL, or omitted — inside a git repo it
uses that repo's origin; outside one you get a picker of your GitHub repos
(fzf if installed). `up` on an existing sandbox just attaches (idempotent);
`--fresh` recreates it.

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
| `--cpu N` / `--memory MB` / `--disk GB` | resources (Daytona no-quota max: 4/8192/10) | 2 / 4096 / 10 |
| `--auto-stop MIN` | 0 = run until stopped | 0 |
| `--snapshot S` | custom snapshot | Daytona default image |

### The fire-and-forget pattern

```bash
devflow up -m "fix the flaky login test, open a PR" --no-attach
# …close your laptop…
devflow peek          # later, from anywhere: is it done?
devflow attach        # join the live session
```

The agent keeps working while detached because the session lives in tmux
inside the sandbox and sandboxes default to `--auto-stop 0`.

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
devflow ssh-command NAME [--expires MIN]
                           # prints `ssh <token>@ssh.app.daytona.io` for
                           # machines with only an ssh client (default 24h)
devflow exec NAME -- CMD   # one-off remote command (buffered output)
devflow dashboard          # app.daytona.io (web terminal exists there too)
```

From another machine: install devflow + `daytona login` (and that's all —
attach/peek/stop need only Daytona auth).

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
`DEVFLOW_AGENT`, `DEVFLOW_HARNESS`, `DEVFLOW_CPU`, `DEVFLOW_MEMORY` (MB),
`DEVFLOW_DISK` (GB), `DEVFLOW_AUTO_STOP` (min), `DEVFLOW_TARGET` (us|eu),
`DEVFLOW_SNAPSHOT`, `DEVFLOW_CLAUDE_AUTH` (auto|token|creds),
`DEVFLOW_WORKROOT`, `DEVFLOW_EXEC_STYLE` (auto-probed; leave alone).
Secret: `DEVFLOW_CLAUDE_TOKEN` in `~/.config/devflow/secrets` (0600).

## Faster starts

```bash
devflow snapshot build       # one-time server-side image build; becomes default
devflow snapshot dockerfile  # print the Dockerfile it uses
```

Prebakes claude/codex/gh/tmux/node + both harnesses so `up` skips installs.

## Costs & lifecycle

- Daytona bills usage (~$0.05/vCPU-h + RAM/disk); default 2cpu/4GB ≈
  **$0.13/h while running**. New accounts: $200 free.
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
| deep inspection | `devflow ssh NAME`, then `~/.devflow/` holds all state/logs |
