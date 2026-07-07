# devflow documentation

Documentation for humans and coding agents. Each page is self-contained and
states exact commands; if you are an agent, read the page matching your task
before touching anything.

| You want to… | Read |
|---|---|
| Use devflow: start/attach/manage cloud agent sessions | [usage.md](usage.md) |
| Understand how devflow works internally before changing it | [architecture.md](architecture.md) |
| Develop: change code, add commands, run tests, avoid known traps | [development.md](development.md) |
| Ship a release (tag, formula, brew, GitHub release) | [releasing.md](releasing.md) |

## The one-paragraph mental model

devflow is a **single-file bash CLI** (`bin/devflow`) that orchestrates the
official `daytona` CLI to run Claude Code / Codex sessions inside Daytona
cloud sandboxes, authenticated with the user's **subscriptions** (Claude
Pro/Max, ChatGPT Plus/Pro) — never API keys. It harvests auth locally, pushes
an embedded provisioning script into the sandbox (4 idempotent phases:
tools → auth → workspace → harness), and leaves a tmux session (`dv`)
running the agent so the user can detach, close the laptop, and
`devflow attach` from any machine. The multi-agent harness layer installs
oh-my-claudecode / oh-my-codex plus devflow's native
dv-engineer/dv-designer/dv-security subagents.

## Ground rules (all contributors, human or agent)

1. **No secrets in the repo. Ever.** Secrets live in `~/.config/devflow/secrets`
   (0600) on the user's machine and in 0600 files inside sandboxes.
2. **`bin/devflow` must stay a single self-contained file** — the sandbox
   provisioner and snapshot Dockerfile are embedded heredocs, printed via
   `devflow __provision-script` and `devflow __dockerfile`.
3. **bash 3.2 compatible** (macOS system bash). CI enforces this on
   macos-latest.
4. **Green gate before any commit**: `make lint && make test`. Before a
   release or provisioner change: `make test-docker` too.
5. Behavior change ⇒ update the matching page here and the README in the
   same commit.
