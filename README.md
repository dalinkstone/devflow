# devflow

**Agentic cloud dev sessions.** One command spins up Claude Code or Codex in a
[Daytona](https://daytona.io) sandbox — authenticated with the **subscriptions
you already pay for** (Claude Pro/Max, ChatGPT Plus/Pro), no API keys. The
session lives in tmux in the cloud: start a task, close your laptop, reattach
from any machine later. It just keeps working.

```console
$ devflow up dalinkstone/myapp -m "add rate limiting to the API" --no-attach
devflow spinning up dv-myapp  agent=claude repo=dalinkstone/myapp 2cpu/4096mb/10gb auto-stop=0m
✓ Claude Code: long-lived subscription token
✓ Codex: ChatGPT sign-in will be copied
✓ GitHub: gh token will be forwarded
▸ creating sandbox…
✓ sandbox running
▸ installing tools (tmux, gh, claude, codex — output appears when done)…
▸ applying auth…
▸ setting up workspace + starting agent session…
✓ provisioned
devflow the agent is on it. it keeps working even when you're not attached.
▸ peek progress:  devflow peek dv-myapp
▸ join session:   devflow attach dv-myapp
```

Now close the laptop. Later, from any machine:

```console
$ devflow attach          # drops you straight into the live tmux session
$ devflow peek            # or just glance at the agent's screen
```

## How it works

```
 your machine                          Daytona cloud sandbox
┌──────────────────────┐              ┌─────────────────────────────────┐
│ devflow up           │   creates    │  tmux session "dv"              │
│  ├ claude Max token ─┼─────────────▶│   ├ window: agent (claude/codex)│
│  ├ ~/.codex/auth.json┼──── auth ───▶│   ├ window: shell               │
│  ├ gh token ─────────┼─────────────▶│   └ survives disconnects        │
│  └ git identity      │              │  ~/work/<repo>  (cloned via gh) │
│                      │              │  harness: CLAUDE.md, AGENTS.md, │
│ devflow attach ──────┼──── ssh ────▶│  settings, statusline, aliases  │
└──────────────────────┘              └─────────────────────────────────┘
```

- **devflow** is a single-file bash CLI that orchestrates the official
  [`daytona` CLI](https://www.daytona.io/docs) — create, exec, ssh.
- **Auth is harvested locally at launch** and injected into the sandbox:
  your Claude subscription token (or credentials), your Codex ChatGPT login,
  your `gh` token, and your git identity. No API keys anywhere.
- **The session is tmux**, so SSH disconnects are meaningless. Attaching from
  a fresh machine lands you in the same screen, and if the sandbox was
  stopped, attach restarts it and the agent **resumes its conversation**
  (`claude --continue` / `codex resume --last`).

## Install

**curl** (macOS / Linux):

```bash
curl -fsSL https://raw.githubusercontent.com/dalinkstone/devflow/main/install.sh | bash
```

**Homebrew**:

```bash
brew tap dalinkstone/devflow https://github.com/dalinkstone/devflow
brew install dalinkstone/devflow/devflow
brew install daytonaio/cli/daytona   # the sandbox engine
```

**From a checkout**: `make install` (installs to `~/.local/bin`, plus a `dv` alias).

Then run the one-time setup:

```bash
devflow setup     # Daytona login (free $200 compute for new accounts),
                  # Claude subscription token, Codex + GitHub checks
devflow doctor    # verify everything is green
```

## Subscription auth — no API keys

devflow never asks for an Anthropic or OpenAI API key:

| agent | how it authenticates in the sandbox |
|---|---|
| **Claude Code** | Preferred: a 1-year OAuth token from `claude setup-token` (run `devflow token` once; stored `0600` in `~/.config/devflow/secrets`, exported as `CLAUDE_CODE_OAUTH_TOKEN` in the sandbox). Fallback: your local subscription credentials (macOS Keychain / `~/.claude/.credentials.json`) are copied in — works, but token refreshes can race your laptop, so the dedicated token is recommended. |
| **Codex** | Your `~/.codex/auth.json` (ChatGPT sign-in) is copied in — the [officially documented headless method](https://developers.openai.com/codex/auth). If it ever goes stale: `devflow sync`, or run `codex login --device-auth` inside the sandbox. |
| **GitHub** | `gh auth token` is forwarded and `gh auth setup-git` configures git, so private clones, pushes, and `gh pr create` all work. |

Both agents bill your subscriptions, exactly like running them on your laptop.

## Daily driving

```
devflow up [REPO]             new session (repo picker outside a repo; auto-detects inside one)
devflow up -m "task" --no-attach     fire-and-forget: agent starts working, you walk away
devflow attach [NAME]         reattach from anywhere (detach: Ctrl-b d)
devflow peek [NAME]           see the agent's last screenful without attaching
devflow ls                    what's running
devflow stop [NAME|--all]     stop billing CPU (disk kept); attach resumes the agent
devflow rm [NAME|--all]       delete
devflow sync [NAME]           refresh subscription auth inside a sandbox
devflow ssh [NAME]            plain SSH (still lands in tmux)
devflow ssh-command [NAME]    print an `ssh token@ssh.app.daytona.io` line for machines without devflow
devflow exec NAME -- CMD      one-off remote command
devflow snapshot build        prebake a custom snapshot → sessions start in seconds
devflow config set K V        defaults: DEVFLOW_AGENT, DEVFLOW_CPU/MEMORY/DISK, DEVFLOW_AUTO_STOP…
```

`devflow up --agent codex` runs Codex instead of Claude; `--agent both` gives
you a tmux window for each. `up` on an existing sandbox just reattaches —
it's idempotent.

## What's inside the sandbox (the harness)

Every sandbox gets an opinionated, tweakable setup:

- **tmux session `dv`** — `agent` window (auto-launches the agent, resumes
  prior conversations) + `shell` window. Mouse on, 100k scrollback. SSH
  logins auto-attach; detaching leaves everything running.
- **Claude Code**: runs `--dangerously-skip-permissions` (the *sandbox* is
  the safety boundary), a statusline (`☁ sandbox · model · dir · branch ·
  ctx%`), and a `~/.claude/CLAUDE.md` that teaches the agent sandbox
  etiquette: commit early, push feature branches, `gh pr create`, re-orient
  with `git status` after a resume.
- **Codex**: `approval_policy = "never"`, `sandbox_mode =
  "danger-full-access"` (again — Daytona is the sandbox), workdir pre-trusted,
  matching `~/.codex/AGENTS.md`.
- **Tools**: `gh`, `tmux`, `jq`, `ripgrep`, plus whatever the base image has
  (the Daytona default image includes python, node, and more). `claude` and
  `codex` install as native binaries — no Node required.
- Aliases: `dv-work` (cd to the repo), `yolo` (claude, no prompts).

Everything is written only if absent, so your own dotfiles win if you bake a
custom snapshot.

## Cost & lifecycle

- Daytona bills per use (~$0.05/vCPU-hr + RAM/disk); new accounts get **$200
  free**. A default 2-cpu/4GB sandbox costs roughly **$0.13/hour while
  running**.
- devflow creates sandboxes with **auto-stop disabled** by default — that's
  the whole point (Daytona's default 15-minute auto-stop kills sessions even
  while the agent is working, because only SSH/API traffic resets the timer).
  So: `devflow stop` (or `stop --all`) when you're done, `devflow ls` to see
  what's running. Prefer a safety net? `devflow config set DEVFLOW_AUTO_STOP
  120` — just know a detached agent gets frozen mid-task after that idle
  window (attach resumes it).
- **stop** preserves disk (a stopped sandbox costs only storage);
  **attach** restarts it and the agent picks the conversation back up.
  After ~7 days stopped, Daytona archives to object storage (slower first
  attach, same data). **rm** deletes — only pushed work survives that.

## Security model

- Tokens travel from your machine to the sandbox over the Daytona API (TLS)
  and land in `0600` files owned by the sandbox user. Treat a sandbox like a
  logged-in laptop: `devflow rm` when a project ends, and revoke tokens
  centrally if ever needed (Claude: claude.ai settings; GitHub: token
  settings; Codex: sign out).
- You are trusting Daytona's infrastructure with those tokens while the
  sandbox exists — the same trust you extend by running the agent there at
  all. If that's not acceptable, this tool isn't the right fit.
- devflow itself stores secrets only in `~/.config/devflow/secrets` (0600),
  and nothing is ever hardcoded in the repo.
- Free-tier note: Daytona Tier 1/2 sandboxes have a network egress whitelist
  (GitHub, npm/pip, Anthropic, OpenAI, …) — agents work fine, but arbitrary
  outbound hosts need Tier 3+.

## From anywhere

Any machine with devflow + `daytona login` can `devflow attach` — state
lives in the sandbox, not on your laptop. For a machine with only an ssh
client, `devflow ssh-command` mints a tokenized `ssh
<token>@ssh.app.daytona.io` line (default 24h validity). There's also a web
terminal in the [Daytona dashboard](https://app.daytona.io) as a last resort.

## Faster starts

The first `up` on the default image installs tools (~1–3 min). Prebake them:

```bash
devflow snapshot build    # server-side Docker build, then it's the default
```

New sandboxes then boot with claude/codex/gh/tmux already in place.

## Troubleshooting

- `devflow doctor` — checks every dependency and credential, with fixes.
- Agent says it's logged out → `devflow sync` (re-copies fresh auth).
- `daytona` CLI/API version-mismatch warnings → `brew upgrade daytonaio/cli/daytona`.
- Claude refuses `--dangerously-skip-permissions` → the sandbox user is root
  (custom snapshot?); devflow falls back to `acceptEdits`, but prefer a
  non-root image (the default image and `devflow snapshot build` are fine).
- Something else → `devflow ssh NAME` and poke around, or
  `devflow exec NAME -- cat .devflow/claude-install.log`.

## Development

```bash
make lint         # shellcheck on the CLI + embedded payloads
make test         # hermetic functional tests (fake daytona/gh/keychain)
make test-docker  # runs the real provisioner in an Ubuntu container
```

Single file: [`bin/devflow`](bin/devflow). The sandbox provisioner and the
snapshot Dockerfile are embedded in it (`devflow __provision-script`,
`devflow __dockerfile`).

MIT © dalinkstone
