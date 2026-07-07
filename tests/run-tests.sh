#!/usr/bin/env bash
# devflow test suite — hermetic functional tests using PATH-shim fakes.
# No network, no real Daytona/GitHub/keychain access.
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DEVFLOW="$ROOT/bin/devflow"
FAKEBIN="$ROOT/tests/fakebin"

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devflow-tests.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

PASS=0; FAIL=0; TESTN=0

t_ok()   { TESTN=$((TESTN+1)); PASS=$((PASS+1)); printf 'ok %d - %s\n' "$TESTN" "$1"; }
t_fail() { TESTN=$((TESTN+1)); FAIL=$((FAIL+1)); printf 'not ok %d - %s\n' "$TESTN" "$1"; [ -n "${2:-}" ] && printf '    # %s\n' "$2"; }

assert_contains() { # NAME HAYSTACK NEEDLE
  if printf '%s' "$2" | grep -qF -- "$3"; then t_ok "$1"; else t_fail "$1" "missing: $3"; fi
}
assert_not_contains() {
  if printf '%s' "$2" | grep -qF -- "$3"; then t_fail "$1" "unexpected: $3"; else t_ok "$1"; fi
}
assert_file_contains() {
  if grep -qF -- "$3" "$2" 2>/dev/null; then t_ok "$1"; else t_fail "$1" "file $2 missing: $3"; fi
}
assert_eq() {
  if [ "$2" = "$3" ]; then t_ok "$1"; else t_fail "$1" "got '$2' want '$3'"; fi
}
assert_rc() { # NAME GOT WANT
  if [ "$2" = "$3" ]; then t_ok "$1"; else t_fail "$1" "exit code $2, want $3"; fi
}

# ---------------------------------------------------------------------------
# environment factory
# ---------------------------------------------------------------------------
fresh_env() { # [EXEC_STYLE]
  ENV_DIR="$WORK/env-$RANDOM"
  T_HOME="$ENV_DIR/home"
  T_CONFIG="$ENV_DIR/config"
  T_STATE="$ENV_DIR/state"
  T_LOG="$ENV_DIR/log"
  T_CWD="$ENV_DIR/cwd"
  mkdir -p "$T_HOME/.claude" "$T_HOME/.codex" "$T_CONFIG" "$T_STATE" "$T_CWD"
  : > "$T_LOG"
  EXEC_STYLE="${1:-argv}"

  # local subscription auth fixtures
  printf '{"claudeAiOauth":{"accessToken":"sk-ant-oat01-FAKEACCESS","refreshToken":"sk-ant-ort01-FAKEREFRESH","expiresAt":9999999999,"subscriptionType":"max"}}' \
    > "$T_HOME/.claude/.credentials.json"
  printf '{"auth_mode":"chatgpt","tokens":{"id_token":"FAKE_CODEX_ID","access_token":"FAKE_CODEX_ACCESS"},"last_refresh":"2026-01-01T00:00:00Z"}' \
    > "$T_HOME/.codex/auth.json"
  printf '[user]\n\tname = Test User\n\temail = test@example.com\n' > "$T_HOME/.gitconfig"

  # daytona CLI config (for ssh-command API key discovery), both OS layouts
  local dtcfg='{"activeProfile":"default","profiles":[{"id":"default","name":"default","api":{"url":"https://fake.daytona.local/api","key":"dtn_FAKEKEY"}}]}'
  mkdir -p "$T_HOME/Library/Application Support/daytona" "$T_HOME/.config/daytona"
  printf '%s' "$dtcfg" > "$T_HOME/Library/Application Support/daytona/config.json"
  printf '%s' "$dtcfg" > "$T_HOME/.config/daytona/config.json"
}

run_devflow() { # args… (stdin=/dev/null, captures stdout+stderr, sets RC/OUT)
  OUT="$(cd "$T_CWD" && env -i \
      PATH="$FAKEBIN:$PATH" \
      HOME="$T_HOME" \
      TMPDIR="$ENV_DIR" \
      TERM=dumb NO_COLOR=1 \
      DEVFLOW_CONFIG_DIR="$T_CONFIG" \
      FAKE_LOG="$T_LOG" FAKE_STATE_DIR="$T_STATE" FAKE_EXEC_STYLE="$EXEC_STYLE" \
      CODEX_HOME="$T_HOME/.codex" \
      "$DEVFLOW" "$@" </dev/null 2>&1)"
  RC=$?
  return 0
}

extract_pushed_file() { # REMOTE_PATH -> decoded content (from chunked upload log)
  grep -F "$1.b64" "$T_LOG" \
    | grep -o "printf %s '[A-Za-z0-9+/=]*'" \
    | sed "s/printf %s '//; s/'$//" \
    | tr -d '\n' \
    | base64 --decode 2>/dev/null
}

# ===========================================================================
echo "# devflow test suite"
echo "# 1..basic"
# ===========================================================================
fresh_env

run_devflow version
assert_rc "version exits 0" "$RC" 0
assert_contains "version prints version" "$OUT" "devflow 0.1."

run_devflow help
assert_rc "help exits 0" "$RC" 0
assert_contains "help lists up" "$OUT" "devflow up"

run_devflow bogus-command
assert_rc "unknown command exits 1" "$RC" 1
assert_contains "unknown command message" "$OUT" "unknown command: bogus-command"

run_devflow doctor
assert_rc "doctor exits 0" "$RC" 0
assert_contains "doctor sees daytona" "$OUT" "daytona"
assert_contains "doctor sees claude creds" "$OUT" "local credentials found"
assert_contains "doctor sees codex auth" "$OUT" ".codex/auth.json present"

# ===========================================================================
echo "# 2..up (argv exec style)"
# ===========================================================================
fresh_env argv

run_devflow up tester/alpha --no-attach
assert_rc "up exits 0" "$RC" 0
assert_contains "up announces sandbox" "$OUT" "spinning up dv-alpha"
assert_contains "up ran provision phases" "$OUT" "fake provision phase ran"
assert_contains "up final hint" "$OUT" "devflow attach dv-alpha"

assert_file_contains "create has name" "$T_LOG" "--name=dv-alpha"
assert_file_contains "create disables auto-stop" "$T_LOG" "--auto-stop=0"
assert_file_contains "create default cpu" "$T_LOG" "--cpu=2"
assert_file_contains "create default memory" "$T_LOG" "--memory=4096"
assert_file_contains "create default disk" "$T_LOG" "--disk=10"
assert_file_contains "create labels devflow" "$T_LOG" "--label devflow=1"
assert_file_contains "create labels agent" "$T_LOG" "--label devflow.agent=claude"
assert_file_contains "create labels repo" "$T_LOG" "--label devflow.repo=tester/alpha"

assert_file_contains "exec-style probed" "$T_LOG" "printf %s x y"
assert_file_contains "probe cached in config" "$T_CONFIG/config" "DEVFLOW_EXEC_STYLE=argv"

assert_file_contains "phase tools ran" "$T_LOG" "DV_PHASE='tools'"
assert_file_contains "phase auth ran" "$T_LOG" "DV_PHASE='auth'"
assert_file_contains "phase workspace ran" "$T_LOG" "DV_PHASE='workspace'"
assert_file_contains "phase carries repo" "$T_LOG" "DV_REPO='tester/alpha'"
assert_file_contains "phase carries name" "$T_LOG" "DV_NAME='dv-alpha'"

SECRETS="$(extract_pushed_file /tmp/.dv-secrets.env)"
assert_contains "secrets: claude creds mode" "$SECRETS" "DV_CLAUDE_MODE=creds"
assert_contains "secrets: gh token forwarded" "$SECRETS" "DV_GH_TOKEN=gho_FAKETOKEN123"
assert_contains "secrets: git name" "$SECRETS" "Test\\ User"
assert_contains "secrets: git email" "$SECRETS" "test@example.com"
CLAUDE_CREDS_B64_LINE="$(printf '%s\n' "$SECRETS" | grep '^DV_CLAUDE_CREDS_B64=' | cut -d= -f2)"
DECODED_CREDS="$(printf '%s' "$CLAUDE_CREDS_B64_LINE" | base64 --decode 2>/dev/null)"
assert_contains "secrets: claude creds decode" "$DECODED_CREDS" "sk-ant-oat01-FAKEACCESS"
CODEX_B64_LINE="$(printf '%s\n' "$SECRETS" | grep '^DV_CODEX_AUTH_B64=' | cut -d= -f2)"
DECODED_CODEX="$(printf '%s' "$CODEX_B64_LINE" | base64 --decode 2>/dev/null)"
assert_contains "secrets: codex auth decode" "$DECODED_CODEX" "FAKE_CODEX_ACCESS"

PROVISION="$(extract_pushed_file /tmp/.dv-provision.sh)"
assert_contains "provisioner uploaded intact" "$PROVISION" "devflow sandbox provisioner"
assert_contains "provisioner has claude install" "$PROVISION" "claude.ai/install.sh"
assert_contains "provisioner has codex musl" "$PROVISION" "unknown-linux-musl"
assert_contains "provisioner writes codex config" "$PROVISION" 'approval_policy = "never"'
assert_contains "provisioner sets token env var" "$PROVISION" "CLAUDE_CODE_OAUTH_TOKEN"

# ===========================================================================
echo "# 3..lifecycle (ls / existing / peek / stop / attach / rm)"
# ===========================================================================

run_devflow ls
assert_rc "ls exits 0" "$RC" 0
assert_contains "ls shows sandbox" "$OUT" "dv-alpha"
assert_contains "ls shows state" "$OUT" "started"
assert_contains "ls shows repo" "$OUT" "tester/alpha"
assert_contains "ls shows resources" "$OUT" "2c/4096m"

run_devflow up tester/alpha --no-attach
assert_rc "up on existing exits 0" "$RC" 0
assert_contains "up on existing attaches" "$OUT" "already exists"
assert_contains "up on existing reaches ssh" "$OUT" "FAKE-SSH dv-alpha"

run_devflow peek
assert_rc "peek (auto-resolve) exits 0" "$RC" 0
assert_contains "peek shows agent pane" "$OUT" "fake agent output line"

run_devflow stop
assert_rc "stop exits 0" "$RC" 0
assert_contains "stop message" "$OUT" "stopped 'dv-alpha'"
assert_eq "state file is stopped" "$(jq -r .state "$T_STATE/dv-alpha.json")" "stopped"

run_devflow attach dv-alpha
assert_rc "attach exits 0" "$RC" 0
assert_contains "attach restarts stopped sandbox" "$OUT" "starting"
assert_contains "attach reaches ssh" "$OUT" "FAKE-SSH dv-alpha"
assert_file_contains "attach ran dv-ensure" "$T_LOG" "dv-ensure"
assert_eq "state file is started again" "$(jq -r .state "$T_STATE/dv-alpha.json")" "started"

run_devflow ssh-command dv-alpha
assert_rc "ssh-command exits 0" "$RC" 0
assert_contains "ssh-command prints ssh line" "$OUT" "ssh faketok123@ssh.app.daytona.io"
assert_file_contains "ssh-command hit api" "$T_LOG" "/sandbox/id-dv-alpha/ssh-access?expiresInMinutes=1440"
assert_file_contains "ssh-command used bearer key" "$T_LOG" "Bearer dtn_FAKEKEY"

run_devflow sync dv-alpha
assert_rc "sync exits 0" "$RC" 0
assert_contains "sync message" "$OUT" "auth refreshed"

run_devflow rm --force dv-alpha
assert_rc "rm exits 0" "$RC" 0
assert_contains "rm message" "$OUT" "deleted 'dv-alpha'"
[ ! -f "$T_STATE/dv-alpha.json" ] && t_ok "rm removed state" || t_fail "rm removed state"

run_devflow ls
assert_contains "ls empty after rm" "$OUT" "no devflow sandboxes"

# ===========================================================================
echo "# 4..blank sandbox with a queued task"
# ===========================================================================
fresh_env argv

run_devflow up --blank -m "fix the flaky login test" --no-attach
assert_rc "blank up exits 0" "$RC" 0
assert_contains "blank names dv-scratch" "$OUT" "spinning up dv-scratch"
assert_not_contains "blank has no repo label" "$(cat "$T_LOG")" "devflow.repo"
assert_contains "task fire-and-forget hint" "$OUT" "devflow peek dv-scratch"

TASK_B64="$(grep -o "DV_TASK_B64='[A-Za-z0-9+/=]*'" "$T_LOG" | head -1 | sed "s/DV_TASK_B64='//; s/'$//")"
assert_eq "task delivered base64-intact" "$(printf '%s' "$TASK_B64" | base64 --decode)" "fix the flaky login test"

# ===========================================================================
echo "# 5..--fresh recreates"
# ===========================================================================
run_devflow up --blank --no-attach --fresh
assert_rc "fresh up exits 0" "$RC" 0
assert_contains "fresh recreates" "$OUT" "recreating 'dv-scratch'"
assert_file_contains "fresh deleted old" "$T_LOG" "daytona delete dv-scratch"

# ===========================================================================
echo "# 6..join exec style"
# ===========================================================================
fresh_env join

run_devflow up tester/beta --no-attach
assert_rc "join-style up exits 0" "$RC" 0
assert_file_contains "join style cached" "$T_CONFIG/config" "DEVFLOW_EXEC_STYLE=join"
assert_contains "join-style provision phases ran" "$OUT" "fake provision phase ran"
assert_file_contains "join-style self-quoted exec" "$T_LOG" "bash -lc "

# ===========================================================================
echo "# 7..config + validation + env precedence"
# ===========================================================================
fresh_env

run_devflow config set DEVFLOW_AGENT codex
assert_rc "config set exits 0" "$RC" 0
run_devflow config get DEVFLOW_AGENT
assert_eq "config get returns set value" "$OUT" "codex"

OUT="$(cd "$T_CWD" && env -i PATH="$FAKEBIN:$PATH" HOME="$T_HOME" TERM=dumb NO_COLOR=1 \
      DEVFLOW_CONFIG_DIR="$T_CONFIG" FAKE_LOG="$T_LOG" FAKE_STATE_DIR="$T_STATE" \
      DEVFLOW_AGENT=claude "$DEVFLOW" config get DEVFLOW_AGENT </dev/null 2>&1)"
assert_eq "env var beats config file" "$OUT" "claude"

run_devflow up tester/alpha --agent bogus --no-attach
assert_rc "invalid agent rejected" "$RC" 1
assert_contains "invalid agent message" "$OUT" "invalid --agent"

run_devflow up "not a repo!!" --no-attach
assert_rc "invalid repo rejected" "$RC" 1
assert_contains "invalid repo message" "$OUT" "could not parse repo"

run_devflow up tester/alpha --agent codex --no-attach
assert_rc "codex agent up exits 0" "$RC" 0
assert_file_contains "codex agent label" "$T_LOG" "--label devflow.agent=codex"
assert_file_contains "codex agent phase" "$T_LOG" "DV_AGENT='codex'"

# ===========================================================================
echo "# 8..payload self-checks"
# ===========================================================================
PROV="$("$DEVFLOW" __provision-script)"
printf '%s\n' "$PROV" > "$WORK/prov.sh"
if bash -n "$WORK/prov.sh" 2>/dev/null; then t_ok "provision script parses"; else t_fail "provision script parses"; fi
assert_contains "provision is phased" "$PROV" 'case "$DV_PHASE" in'
assert_contains "provision writes CLAUDE.md" "$PROV" "devflow sandbox"
assert_contains "provision guards root bypass" "$PROV" "acceptEdits"
assert_contains "provision autotmux marker" "$PROV" "autotmux"

DOCKERFILE="$("$DEVFLOW" __dockerfile)"
assert_contains "dockerfile non-root user" "$DOCKERFILE" "USER daytona"
assert_contains "dockerfile installs tmux" "$DOCKERFILE" "tmux"

# ===========================================================================
printf '\n# results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$TESTN"
[ "$FAIL" = 0 ] || exit 1
echo "# ALL TESTS PASSED"
