# devflow — agent notes

Single-file bash CLI (`bin/devflow`) that runs Claude Code / Codex sessions in
Daytona cloud sandboxes using the user's subscriptions (never API keys).
Full docs: [docs/README.md](docs/README.md) — read the page matching your
task: [usage](docs/usage.md) · [architecture](docs/architecture.md) ·
[development](docs/development.md) · [releasing](docs/releasing.md).

## Gate (run before every commit)

```bash
make lint && make test
make test-docker    # additionally, when emit_provision_script/emit_dockerfile changed (needs Docker+network, ~6 min)
```

## Hard invariants

- bash 3.2 compatible (macOS system bash; CI enforces): no `${var,,}`,
  `mapfile`, associative arrays; avoid empty-array expansion under `set -u`.
- `bin/devflow` stays one self-contained file; the sandbox provisioner and
  snapshot Dockerfile are embedded heredocs (`devflow __provision-script`,
  `devflow __dockerfile`). Outer heredoc delimiters are quoted; inner ones
  are unique `DV_*` names; `\$` for anything expanding at sandbox runtime.
- Remote commands ONLY via `dt_run` (join/argv exec-style probe), single-line
  scripts; file content via `dt_push_file`. Daytona flags as `--flag=value`.
- No secrets in the repo, ever; secrets are 0600 at rest and the staged
  bundle is shredded in the auth phase.
- Provision phases stay idempotent; sandbox dotfiles are write-if-absent;
  harness installs are best-effort (warn + continue, never block).
- Known traps (nvm PATH visibility, `omc setup` deleting `~/.claude/agents`
  files, `omx setup` writing to cwd, buffered `daytona exec`, auto-stop
  killing detached work) are catalogued in
  [docs/development.md](docs/development.md#traps-we-already-hit-dont-rediscover-them) — check it before "fixing" anything in the provisioner.

Behavior change ⇒ update the matching docs page + README in the same commit.
Release procedure is exact — follow [docs/releasing.md](docs/releasing.md)
step by step (tag first, then pin the GitHub tarball sha on main).
