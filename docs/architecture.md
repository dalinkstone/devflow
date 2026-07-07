# Architecture

How devflow works internally. Read this before modifying `bin/devflow`.

## Layers

```
user ──▶ bin/devflow (bash, single file)
              │  orchestrates via subprocess
              ▼
         daytona CLI ──TLS──▶ Daytona API ──▶ sandbox (container)
              │                                   │
              │ create/exec/ssh/list/info         │ embedded provisioner runs here
              ▼                                   ▼
         local auth harvest              ~/.devflow/* state, tmux session "dv",
         (keychain / files / gh)         claude+codex+gh+tmux, harness
```

devflow deliberately has **no runtime dependency on the Daytona REST API**
except one endpoint (`ssh-access`, used by `devflow ssh-command` and
`devflow mobile`); everything
else goes through the `daytona` CLI so auth/transport stay Daytona's problem.

## bin/devflow file map (one file, ordered sections)

| Section | What lives there |
|---|---|
| Config | `load_config` (env > config file > defaults), `config_set`, `resolve_harness` |
| UI helpers | `say/step/ok/warn/err/die/confirm`, color detection |
| Utilities | `b64_encode`, `sanitize_name`, `repo_from_arg`, `current_repo`, `need_cmd/need_val` |
| Daytona wrappers | `dt`, `dt_auth_check`, `dt_info_json`, `sandbox_state`, `wait_for_state`, **`probe_exec_style`/`dt_run`**, `dt_push_file` |
| Auth harvest | `harvest_all` (memoized), `build_secrets_bundle`, `auth_summary` |
| Repo picker | `pick_repo` (gh + fzf/numbered) |
| **Embedded payloads** | `emit_provision_script` (the in-sandbox provisioner), `emit_dockerfile` (snapshot image) |
| Orchestration | `upload_provisioner`, `run_phase`, `provision_sandbox`, `ensure_running` |
| Listing | `devflow_sandboxes_json` (label-filtered), `resolve_name` |
| Commands | `cmd_up`, `cmd_attach`, `cmd_ssh`, `cmd_ssh_command`, `cmd_exec`, `cmd_peek`, `cmd_ls`, `cmd_stop`, `cmd_rm`, `cmd_sync`, `cmd_token`, `cmd_config`, `cmd_dashboard`, `cmd_doctor`, `cmd_setup`, `cmd_snapshot` |
| Help + main | `usage`, `usage_up`, `main` dispatch |

Hidden commands: `devflow __provision-script` and `devflow __dockerfile`
print the embedded payloads — tests and the Docker validation consume them.

## The exec-style probe (critical invariant)

`daytona exec NAME -- args…` differs across CLI builds: some **join** the
args into one shell string (so quoting must be pre-baked), some pass **argv**
verbatim. devflow probes once per machine (`printf %s 'x y'` → `"x y"` = argv,
`"xy"` = join), caches `DEVFLOW_EXEC_STYLE` in the config file, and routes
every remote command through `dt_run NAME SCRIPT [TIMEOUT]`:

- argv style → `daytona exec NAME --timeout T -- bash -lc "$script"`
- join style → single pre-quoted token `"bash -lc $(printf %q "$script")"`

**Never call `daytona exec` directly for scripts — always `dt_run`.** Keep
`dt_run` scripts newline-free (join style + `printf %q` would emit `$'…'`
which a remote dash won't parse).

`daytona exec` **buffers output** until the command exits (no streaming) and
propagates the remote exit code. That's why provisioning is phased — each
phase's output appears when the phase ends.

## File pushes

`dt_push_file NAME REMOTE_PATH` (content on stdin): base64 → 6000-char chunks
→ `printf %s 'chunk' >>` appends via `dt_run` → remote `base64 -d`. Used for
the provisioner and the secrets bundle. Secrets transit the Daytona API over
TLS and land in 0600 files; the staged bundle is deleted at the end of the
auth phase (threat model: you already trust Daytona to run the agent).

## Provisioning (inside the sandbox)

`emit_provision_script` embeds a 4-phase idempotent script, run as:

```
DV_PHASE=<phase> DV_AGENT=… DV_REPO=… DV_BRANCH=… DV_NAME=… \
DV_TASK_B64=… DV_WORKROOT=… DV_HARNESS=… bash ~/.devflow/stage/provision.sh
```

| Phase | Does |
|---|---|
| `tools` | apt (tmux/jq/ripgrep via passwordless sudo), gh binary, Claude Code native installer (claude.ai/install.sh), Codex musl release binary; npm fallbacks; hard-fails only if the *selected* agent is unusable |
| `auth` | secrets bundle → `CLAUDE_CODE_OAUTH_TOKEN` in `~/.devflow/env` **or** `~/.claude/.credentials.json` (0600); `~/.codex/auth.json` (0600); `gh auth login --with-token` + `setup-git`; git identity; shreds the bundle |
| `workspace` | repo clone to `~/work/<repo>` (branch handling), `~/.claude.json` onboarding/trust seed, `~/.claude/settings.json` + `CLAUDE.md`, `~/.codex/config.toml` + `AGENTS.md`, `~/.tmux.conf`, shell integration (`~/.devflow/shellrc` sourced from .bashrc/.profile with re-entry guard; SSH logins auto-attach tmux), helper scripts `dv-agent`/`dv-ensure`/`dv-statusline`, queues `-m` task, starts tmux session `dv` |
| `harness` | `ensure_npm` (nvm-installs node 22 if needed, symlinks nvm bins into `~/.local/bin`), installs oh-my-claudecode (`omc setup --no-plugin --force --quiet`) and/or oh-my-codex (`omx setup --scope user --merge-agents --force`), then installs dv-engineer/dv-designer/dv-security **after** omc (whose setup syncs `~/.claude/agents` and deletes unknown files) |

All phases are safe to re-run. `devflow sync` re-uploads and runs only `auth`.

### Sandbox state directory (`~/.devflow/`)

`env` (0600 secrets env), `agent`, `workdir`, `name`, `repo`, `harness`,
`task` (consumed on first agent launch), `provisioned` (version marker),
`autotmux` (enables SSH auto-attach), `shellrc`, `stage/` (0700),
`bin/{dv-agent,dv-ensure,dv-statusline}`, `*-install.log`.

- `dv-agent [claude|codex]` — launches the agent in the workdir; consumes a
  queued task; resumes prior conversations; root fallback (`acceptEdits`,
  since claude refuses bypass as root); prefers the `omx` launcher for fresh
  codex sessions.
- `dv-ensure` — recreates tmux session `dv` (agent/[codex]/shell windows)
  if missing; run by attach after restarts.
- `dv-statusline` — Claude Code statusLine command (sandbox · model · dir ·
  branch · ctx%). oh-my-claudecode's HUD replaces it when installed.

## Daytona facts devflow relies on (verified 2026-07)

- Default image: user `daytona` + passwordless sudo, git/curl/python/node
  (node via **nvm**, invisible to non-interactive shells), **no tmux**.
- `create` flags use `--flag=value` form (cobra rejects bare negative values);
  `--memory` is **MB** on create but **GB** on `snapshot create`.
- Auto-stop default is 15 min and its timer **ignores running processes**
  (only SSH/API traffic resets it) → devflow defaults to `--auto-stop=0`.
- stop kills processes, preserves disk; archive (default after 7d stopped)
  moves disk to object storage; start restores either.
- Tier 1/2 egress whitelist covers github.com, *.githubusercontent.com, npm,
  pypi, claude.ai, *.anthropic.com, *.openai.com, chatgpt.com.
- Raw SSH: `POST /sandbox/{id}/ssh-access?expiresInMinutes=N` → token used as
  the ssh **username** at `ssh.app.daytona.io:22` (that's `ssh-command`, the
  line `mobile` prints, and the `User` in the managed `~/.ssh/config` block
  `ssh-config` writes — which is what makes plain `ssh NAME` and editor
  Remote-SSH work). `mobile` also renders that token as an
  `ssh://user@host` QR via local `qrencode` (optional dep, warn-and-continue
  without it — phone cameras hand the URI to Termius/Blink/ConnectBot in one
  tap) and best-effort copies the line to the clipboard (`pbcopy`/`wl-copy`/
  `xclip`); `mobile --out` writes the same thing as a self-contained 0600
  HTML pass (SVG QR) to AirDrop / park in a synced folder / print;
  `mobile --send` hands the line to a channel that carries it to the phone
  by itself: an ntfy push (opt-in `POST $DEVFLOW_NTFY_URL/$DEVFLOW_NTFY_TOPIC`,
  default ntfy.sh, self-hostable; topic minted by `--setup-push`, stored in
  secrets, topic-name-is-the-password model; `X-Click` carries the `ssh://`
  URI so tapping the notification opens the SSH app; server caches ~12h) or
  1Password / Bitwarden / Apple Notes through their local CLIs
  (`op` / `bw` / `osascript`). `DEVFLOW_AUTO_HANDOFF` wires the same send
  into the end of every `up` (best-effort, never blocks). The token never
  leaves the machine except to Daytona itself — and whichever channel the
  user explicitly points it at.
  tmux auto-attach is wired into the sandbox's
  `~/.profile`/`~/.bashrc`, so any interactive SSH login — CLI or raw token —
  lands in the running agent; the client does nothing special.
- Sandboxes are found/filtered via labels: `devflow=1`, `devflow.agent`,
  `devflow.repo`, `devflow.harness`.

## Subscription auth model

| Credential | Harvested from | Lands in sandbox as |
|---|---|---|
| Claude token (preferred) | `DEVFLOW_CLAUDE_TOKEN` in `~/.config/devflow/secrets` (via `devflow token`) | `export CLAUDE_CODE_OAUTH_TOKEN=…` in `~/.devflow/env` |
| Claude credentials (fallback) | macOS Keychain item "Claude Code-credentials" or `~/.claude/.credentials.json` | `~/.claude/.credentials.json` (0600); caveat: refresh rotation can race the laptop (why the token is preferred) |
| Codex | `${CODEX_HOME:-~/.codex}/auth.json` | `~/.codex/auth.json` (0600) — officially documented headless method |
| GitHub | `gh auth token` | `gh auth login --with-token` + `gh auth setup-git` |
| Git identity | `git config user.name/email` | `git config --global` |

`DEVFLOW_CLAUDE_AUTH=auto|token|creds` selects the Claude path.
