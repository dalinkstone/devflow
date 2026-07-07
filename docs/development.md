# Development guide

How to change this repo safely. Written for coding agents as much as humans:
follow the checklists literally.

## Repo layout

```
bin/devflow                     the entire CLI (one self-contained file)
install.sh                      curl|bash installer (also works from checkout)
Formula/devflow.rb              Homebrew formula (this repo doubles as the tap)
Makefile                        install / lint / test / test-docker
docs/                           this documentation
tests/run-tests.sh              hermetic functional suite (fake CLIs)
tests/fakebin/{daytona,gh,security,curl,qrencode,pbcopy,op,bw,osascript}   PATH-shim fakes
tests/docker-provision-test.sh  real provisioner in ubuntu:24.04 (needs Docker)
.github/workflows/ci.yml        lint+test (ubuntu, macos) + docker provision
```

## The gate

```bash
make lint          # bash -n + shellcheck on CLI, installer, tests, AND the
                   # extracted provision payload
make test          # hermetic suite (~5s, no network)
make test-docker   # real provisioner end-to-end (~5-8 min, network + Docker);
                   # REQUIRED when you touched emit_provision_script/emit_dockerfile
```

All green before every commit. CI runs the same three on push/PR
(macos-latest runs the suite under bash 3.2 — that's deliberate).

## Hard invariants (violating these breaks users)

1. **bash 3.2 compatibility** in `bin/devflow` and `tests/*`:
   no `${var,,}`, `mapfile`/`readarray`, associative arrays, `local -n`;
   guard empty arrays (`"${arr[@]}"` under `set -u` explodes on 3.2 — avoid
   empty-array expansion entirely).
2. **Remote commands only via `dt_run`** (handles the join/argv exec-style
   probe). Scripts passed to `dt_run` must be **single-line**. File content
   goes through `dt_push_file`, never inline.
3. **cobra flag form**: pass daytona values as `--flag=value` (a bare
   `--flag -1` is parsed as another flag).
4. **Embedded payload heredocs**: outer delimiter `DVPROV_EOF` is quoted
   (nothing expands at emit time). Inner heredocs need unique delimiters
   (`DV_*` convention). Inside the provisioner, `$var` expands at *provision
   runtime*; write `\$` for anything that must survive into generated files
   or messages. After editing payloads run
   `bin/devflow __provision-script | bash -n` (make lint does this).
5. **Secrets**: never echoed, never in repo, 0600 at rest, staged bundle
   deleted in the auth phase. Locally they exist only in memory
   (`harvest_all`) and `~/.config/devflow/secrets`.
6. **Idempotency**: every provision phase and every user-facing command must
   be safe to re-run. Config/dotfiles in the sandbox are write-if-absent so
   user customization survives.
7. **Best-effort harness**: omc/omx failures must warn (with log tail) and
   continue — never block a session.
8. **Env > config file > defaults** precedence for all `DEVFLOW_*` keys
   (see `load_config`; add new keys to `_CONFIG_KEYS`).

## Traps we already hit (don't rediscover them)

| Trap | Rule |
|---|---|
| nvm-installed node/npm/omc/omx invisible to non-interactive login shells (ubuntu .bashrc early-returns) | after npm installs, `link_global_bin <name>` into `~/.local/bin` |
| `omc setup` syncs `~/.claude/agents/` and **deletes unknown files** | install dv-* subagents **after** omc setup (see `phase_harness` ordering) |
| `omx setup` writes `.omx` state into **cwd** | provisioner does `cd "$HOME"` at start — keep it |
| `daytona exec` buffers all output | keep provisioning phased; print progress from the local side |
| Daytona auto-stop ignores running processes | never lower the `--auto-stop=0` default |
| claude refuses `--dangerously-skip-permissions` as root | dv-agent falls back to `--permission-mode acceptEdits` |
| macOS runners lack shellcheck | CI installs it via brew on macOS |
| GitHub tarball sha | always compute from the **downloaded** tag tarball, not local `git archive` |

## How-to recipes

### Add a CLI command
1. Write `cmd_<name>()` next to its peers; reuse `resolve_name`,
   `ensure_running`, `dt_run`.
2. Register in `main`'s dispatch (plus aliases) and in `usage()`.
3. Add suite coverage in `tests/run-tests.sh` (see patterns below).
4. `make lint && make test`; update `docs/usage.md`.

### Change the sandbox provisioner
1. Edit inside `emit_provision_script` heredoc (respect invariant 4).
2. If you add/remove phase inputs, thread them through `run_phase` /
   `provision_sandbox` / `cmd_up` and the `DV_*` defaults block.
3. `make lint && make test` then **`make test-docker`** — it exists precisely
   to catch sandbox-side breakage (it has caught real bugs: unbound vars,
   PATH visibility, cwd state, agent-dir clobbering).
4. Consider bumping `DV_PROVISION_VERSION` when the change invalidates
   already-provisioned sandboxes (marker: `~/.devflow/provisioned`).

### Change version pins
`GH_PIN_VERSION` / `CODEX_PIN_TAG` near the top of `bin/devflow` (fallbacks
when the sandbox can't query the GitHub API) and mirrored in
`emit_dockerfile`. Verify the release assets exist before bumping.

## Test harness anatomy

`tests/run-tests.sh` runs devflow with `env -i`, a temp `$HOME`, temp
`DEVFLOW_CONFIG_DIR`, and `tests/fakebin` prepended to PATH. The fakes:

- `daytona` — records every invocation to `$FAKE_LOG`; keeps sandbox state as
  JSON files in `$FAKE_STATE_DIR`; emulates **both** exec styles via
  `FAKE_EXEC_STYLE=argv|join`; **materializes `dt_push_file` uploads** into
  `$FAKE_STATE_DIR/fs/<remote-path>` so tests assert on the exact decoded
  bytes (log-parsing proved environment-brittle — don't go back to it).
- `gh` / `security` / `curl` — canned auth fixtures, the ssh-access API, and
  a silent-accept ntfy push endpoint.
- `qrencode` / `pbcopy` — deterministic `FAKE-QR[payload]` marker instead of
  a real QR (`FAKE_QRENCODE_FAIL=1` simulates a broken install) and a
  clipboard sink so tests never clobber the real clipboard.
- `op` / `bw` / `osascript` — `mobile --send` channel sinks: log-only 1Password
  (`FAKE_OP_FAIL=1` simulates signed-out), a Bitwarden that answers the exact
  template/encode/create pipeline, and an osascript that records the
  AppleScript instead of touching Notes.

Test idioms:

```bash
run_devflow up tester/alpha --no-attach     # sets $OUT and $RC
assert_rc "…" "$RC" 0
assert_contains "…" "$OUT" "needle"         # prints got-snippet on failure
assert_file_contains "…" "$T_LOG" "daytona create"
SECRETS="$(extract_pushed_file /tmp/.dv-secrets.env)"   # decoded upload
```

Run one section quickly: the suite is linear — comment nothing out; it takes
seconds. Both exec styles are covered (`fresh_env argv` / `fresh_env join`).

`tests/docker-provision-test.sh` builds a daytona-like container (non-root
`daytona` + passwordless sudo, no tmux), runs all four phases with dummy
secrets and `DV_HARNESS=both`, then asserts ~48 facts (binaries run, 0600
modes, files, tmux session, harness health incl. `omx list` and OMX's
AGENTS.md merge markers). `PLATFORM=linux/amd64` env forces cross-arch.

## Style

- Match the existing section banners and helper vocabulary (`step/ok/warn/die`).
- shellcheck clean at `-S warning`; add targeted `# shellcheck disable=` with
  a reason only when unavoidable.
- User-facing strings: lowercase terse, actionable ("run: devflow setup").
- Comments only for non-obvious constraints (see the exec-style and heredoc
  notes in the source — that's the bar).
