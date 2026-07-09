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
  if printf '%s' "$2" 2>/dev/null | grep -qF -- "$3"; then
    t_ok "$1"
  else
    t_fail "$1" "missing: $3 | got: $(printf '%s' "$2" | tr '\n' ' ' | head -c 200)"
  fi
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
      FAKE_QRENCODE_FAIL="${FAKE_QRENCODE_FAIL:-}" FAKE_OP_FAIL="${FAKE_OP_FAIL:-}" \
      CODEX_HOME="$T_HOME/.codex" \
      "$DEVFLOW" "$@" </dev/null 2>&1)"
  RC=$?
  return 0
}

extract_pushed_file() { # REMOTE_PATH -> decoded content (materialized by the fake)
  cat "$T_STATE/fs$1" 2>/dev/null
}

# ===========================================================================
echo "# devflow test suite"
echo "# 1..basic"
# ===========================================================================
fresh_env

run_devflow version
assert_rc "version exits 0" "$RC" 0
assert_contains "version prints version" "$OUT" "devflow 0."

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
assert_contains "doctor shows phone hand-off channels" "$OUT" "phone hand-off"
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
assert_not_contains "up stays quiet without auto-handoff" "$OUT" "auto-handoff"

assert_file_contains "create has name" "$T_LOG" "--name=dv-alpha"
assert_file_contains "create disables auto-stop" "$T_LOG" "--auto-stop=0"
assert_contains "up shows the default size" "$OUT" "size=medium (2cpu/4gb/8gb)"
assert_file_contains "create sizes via the medium snapshot" "$T_LOG" "--snapshot=daytona-medium"
assert_not_contains "create sends no raw cpu (API rejects it)" "$(cat "$T_LOG")" "--cpu="
assert_not_contains "create sends no raw memory" "$(cat "$T_LOG")" "--memory="
assert_not_contains "create sends no raw disk" "$(cat "$T_LOG")" "--disk="
assert_file_contains "create labels devflow" "$T_LOG" "--label devflow=1"
assert_file_contains "create labels agent" "$T_LOG" "--label devflow.agent=claude"
assert_file_contains "create labels repo" "$T_LOG" "--label devflow.repo=tester/alpha"

assert_file_contains "exec-style probed" "$T_LOG" "printf %s x y"
assert_file_contains "probe cached in config" "$T_CONFIG/config" "DEVFLOW_EXEC_STYLE=argv"

assert_file_contains "phase tools ran" "$T_LOG" "DV_PHASE='tools'"
assert_file_contains "phase auth ran" "$T_LOG" "DV_PHASE='auth'"
assert_file_contains "phase workspace ran" "$T_LOG" "DV_PHASE='workspace'"
assert_file_contains "phase harness ran" "$T_LOG" "DV_PHASE='harness'"
assert_file_contains "phase carries repo" "$T_LOG" "DV_REPO='tester/alpha'"
assert_file_contains "phase carries name" "$T_LOG" "DV_NAME='dv-alpha'"
assert_file_contains "claude agent gets omc harness" "$T_LOG" "DV_HARNESS='omc'"
assert_file_contains "harness label set" "$T_LOG" "--label devflow.harness=omc"

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
assert_contains "provisioner installs omc" "$PROVISION" "oh-my-claude-sisyphus"
assert_contains "provisioner runs omc setup headless" "$PROVISION" "omc setup --no-plugin --force --quiet"
assert_contains "provisioner installs omx" "$PROVISION" "oh-my-codex"
assert_contains "provisioner runs omx setup" "$PROVISION" "omx setup --scope user --merge-agents --force"
assert_contains "provisioner ships dv-engineer" "$PROVISION" "name: dv-engineer"
assert_contains "provisioner ships dv-designer" "$PROVISION" "name: dv-designer"
assert_contains "provisioner ships dv-security" "$PROVISION" "name: dv-security"

# ===========================================================================
echo "# 3..lifecycle (ls / existing / peek / stop / attach / rm)"
# ===========================================================================

run_devflow ls
assert_rc "ls exits 0" "$RC" 0
assert_contains "ls shows sandbox" "$OUT" "dv-alpha"
assert_contains "ls shows state" "$OUT" "started"
assert_contains "ls shows repo" "$OUT" "tester/alpha"
assert_contains "ls shows resources" "$OUT" "2c/4g"

run_devflow up tester/alpha --no-attach
assert_rc "up on existing exits 0" "$RC" 0
assert_contains "up on existing detects it" "$OUT" "already exists"
assert_not_contains "up on existing honors --no-attach (no ssh)" "$OUT" "FAKE-SSH"
assert_contains "up on existing prints the attach hint" "$OUT" "attach anytime"

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

SSHCFG="$T_HOME/.ssh/config"

run_devflow ssh-config dv-alpha
assert_rc "ssh-config exits 0" "$RC" 0
assert_contains "ssh-config announces the host" "$OUT" "Host dv-alpha"
assert_file_contains "ssh-config wrote the Host block" "$SSHCFG" "Host dv-alpha"
assert_file_contains "ssh-config wrote the gateway" "$SSHCFG" "HostName ssh.app.daytona.io"
assert_file_contains "ssh-config wrote the tokened user" "$SSHCFG" "User faketok123"
assert_contains "ssh-config file is 0600" "$(ls -l "$SSHCFG")" "-rw-------"

printf 'Host keepme\n  HostName example.com\n' >> "$SSHCFG"
run_devflow ssh-config dv-alpha --expires 60
assert_rc "ssh-config refresh exits 0" "$RC" 0
assert_eq "ssh-config is idempotent (one managed block)" "$(grep -c '>>> devflow dv-alpha >>>' "$SSHCFG")" "1"
assert_file_contains "ssh-config refresh preserved user content" "$SSHCFG" "Host keepme"
assert_file_contains "ssh-config refresh honored --expires" "$T_LOG" "ssh-access?expiresInMinutes=60"

run_devflow ssh-config dv-alpha --remove
assert_rc "ssh-config --remove exits 0" "$RC" 0
assert_not_contains "--remove drops the managed block" "$(cat "$SSHCFG")" "devflow dv-alpha"
assert_file_contains "--remove keeps user content" "$SSHCFG" "Host keepme"

run_devflow mobile dv-alpha
assert_rc "mobile exits 0" "$RC" 0
assert_contains "mobile QRs the ssh:// URI (one-tap open on phones)" "$OUT" "FAKE-QR[ssh://faketok123@ssh.app.daytona.io]"
assert_contains "mobile prints a ready ssh line" "$OUT" "ssh faketok123@ssh.app.daytona.io"
assert_contains "mobile mentions the clipboard copy" "$OUT" "clipboard"
assert_file_contains "mobile clipboard got the ssh line" "$T_LOG" "pbcopy ssh faketok123@ssh.app.daytona.io"
assert_contains "mobile shows browser path" "$OUT" "app.daytona.io"
assert_contains "mobile shows peek hint" "$OUT" "devflow peek dv-alpha"

run_devflow mobile dv-alpha --expires 60
assert_rc "mobile --expires exits 0" "$RC" 0
assert_file_contains "mobile honors --expires" "$T_LOG" "ssh-access?expiresInMinutes=60"

run_devflow mobile dv-alpha --no-qr --no-copy
assert_rc "mobile --no-qr --no-copy exits 0" "$RC" 0
assert_not_contains "--no-qr suppresses the QR" "$OUT" "FAKE-QR"
assert_not_contains "--no-copy skips the clipboard" "$OUT" "clipboard"

FAKE_QRENCODE_FAIL=1
run_devflow mobile dv-alpha
FAKE_QRENCODE_FAIL=""
assert_rc "mobile survives a broken qrencode" "$RC" 0
assert_contains "broken qrencode falls back to a hint" "$OUT" "install qrencode"
assert_contains "broken qrencode still prints the ssh line" "$OUT" "ssh faketok123@ssh.app.daytona.io"

run_devflow qr dv-alpha
assert_rc "qr alias exits 0" "$RC" 0
assert_contains "qr alias renders the QR" "$OUT" "FAKE-QR[ssh://faketok123@ssh.app.daytona.io]"

run_devflow mobile dv-alpha --out pass.html --no-copy
assert_rc "mobile --out exits 0" "$RC" 0
assert_contains "mobile announces the saved pass" "$OUT" "reconnect pass saved"
assert_file_contains "pass embeds the ssh line" "$T_CWD/pass.html" "ssh faketok123@ssh.app.daytona.io"
assert_file_contains "pass embeds the QR svg" "$T_CWD/pass.html" "FAKE-QR[ssh://faketok123@ssh.app.daytona.io]"
assert_file_contains "pass links the browser fallback" "$T_CWD/pass.html" "app.daytona.io"
assert_contains "pass file is 0600" "$(ls -l "$T_CWD/pass.html" 2>/dev/null)" "-rw-------"

run_devflow mobile dv-alpha --open
assert_rc "--open without --out is rejected" "$RC" 1
assert_contains "--open requires --out message" "$OUT" "--open requires --out"

run_devflow mobile dv-alpha --send --no-qr --no-copy
assert_rc "mobile --send auto exits 0" "$RC" 0
assert_contains "--send auto lands in 1Password" "$OUT" "sent via 1Password"
assert_file_contains "op got a Secure Note" "$T_LOG" "op item create --category Secure Note"
assert_file_contains "op note carries the ssh line" "$T_LOG" "ssh faketok123@ssh.app.daytona.io"

run_devflow mobile dv-alpha --send note --no-qr --no-copy
assert_rc "--send note exits 0" "$RC" 0
assert_contains "--send note lands in Apple Notes" "$OUT" "sent via Apple Notes"
assert_file_contains "osascript makes a note" "$T_LOG" "make new note"
assert_file_contains "note body carries the ssh line as html" "$T_LOG" "ssh faketok123@ssh.app.daytona.io<br>"

run_devflow mobile dv-alpha --send bw --no-qr --no-copy
assert_rc "--send bw exits 0" "$RC" 0
assert_contains "--send bw lands in Bitwarden" "$OUT" "sent via Bitwarden"
assert_file_contains "bw created an item" "$T_LOG" "bw --nointeraction create item"

FAKE_OP_FAIL=1
run_devflow mobile dv-alpha --send op --no-qr --no-copy
FAKE_OP_FAIL=""
assert_rc "--send op surfaces a failure" "$RC" 1
assert_contains "--send op failure hints at signin" "$OUT" "op signin"

run_devflow mobile dv-alpha --send push --no-qr --no-copy
assert_rc "--send push before setup fails" "$RC" 1
assert_contains "--send push points at setup" "$OUT" "devflow mobile --setup-push"

run_devflow mobile --setup-push
assert_rc "setup-push exits 0" "$RC" 0
assert_contains "setup-push shows the subscribe url" "$OUT" "https://ntfy.sh/devflow-"
assert_contains "setup-push renders a subscribe QR" "$OUT" "FAKE-QR[https://ntfy.sh/devflow-"
assert_file_contains "setup-push stores the topic in secrets" "$T_CONFIG/secrets" "DEVFLOW_NTFY_TOPIC=devflow-"
assert_file_contains "setup-push sent a test notification" "$T_LOG" "push channel works"

run_devflow mobile --setup-push
assert_rc "setup-push is idempotent" "$RC" 0
assert_eq "setup-push keeps one topic" "$(grep -c 'DEVFLOW_NTFY_TOPIC=' "$T_CONFIG/secrets")" "1"

run_devflow mobile dv-alpha --send push --no-qr --no-copy
assert_rc "--send push exits 0" "$RC" 0
assert_contains "--send push lands on ntfy" "$OUT" "sent via push (ntfy)"
assert_file_contains "push carries a tap-to-open ssh:// click" "$T_LOG" "X-Click: ssh://faketok123@ssh.app.daytona.io"
assert_file_contains "push body carries the ssh line" "$T_LOG" "ssh faketok123@ssh.app.daytona.io"

run_devflow mobile dv-alpha --send --no-qr --no-copy
assert_rc "--send auto with push configured exits 0" "$RC" 0
assert_contains "--send auto now prefers push" "$OUT" "sent via push (ntfy)"

run_devflow config set DEVFLOW_AUTO_HANDOFF push
assert_rc "config set auto-handoff exits 0" "$RC" 0

run_devflow up tester/beta --no-attach
assert_rc "up with auto-handoff exits 0" "$RC" 0
assert_contains "auto-handoff fires after up" "$OUT" "auto-handoff: reconnect line sent via push (ntfy)"
assert_file_contains "auto-handoff pushed the new session" "$T_LOG" "devflow · dv-beta"
run_devflow rm --force dv-beta   # keep the env's later rm/ls assertions honest

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
assert_file_contains "codex agent gets omx harness" "$T_LOG" "DV_HARNESS='omx'"

run_devflow up tester/beta --harness core --no-attach
assert_rc "harness core up exits 0" "$RC" 0
assert_file_contains "core harness phase" "$T_LOG" "DV_HARNESS='core'"

run_devflow up tester/beta --harness bogus --no-attach
assert_rc "invalid harness rejected" "$RC" 1
assert_contains "invalid harness message" "$OUT" "invalid --harness"

run_devflow up tester/alpha --agent both --no-attach --fresh
assert_rc "both agents up exits 0" "$RC" 0
assert_file_contains "both agents get both harnesses" "$T_LOG" "DV_HARNESS='both'"

# ===========================================================================
echo "# 8..sandbox sizes (Daytona fixed-size snapshot classes)"
# ===========================================================================
fresh_env

run_devflow up tester/gamma --size small --no-attach
assert_rc "--size small exits 0" "$RC" 0
assert_file_contains "--size small uses the small snapshot" "$T_LOG" "--snapshot=daytona-small"

run_devflow up tester/delta --cpu 4 --memory 8192 --disk 10 --no-attach
assert_rc "legacy resource flags still work" "$RC" 0
assert_contains "legacy flags announce the size mapping" "$OUT" "map to --size large"
assert_file_contains "legacy flags map to the large snapshot" "$T_LOG" "--snapshot=daytona-large"
assert_not_contains "legacy flags never reach daytona raw" "$(cat "$T_LOG")" "--cpu="

run_devflow up tester/epsilon --size huge --no-attach
assert_rc "invalid size rejected" "$RC" 1
assert_contains "invalid size message" "$OUT" "invalid --size"

run_devflow config set DEVFLOW_MEMORY 8192
run_devflow up tester/eta --no-attach
assert_rc "legacy config memory up exits 0" "$RC" 0
assert_file_contains "legacy config maps to the large snapshot" "$T_LOG" "--snapshot=daytona-large"

run_devflow config set DEVFLOW_SIZE small
run_devflow up tester/theta --no-attach
assert_rc "config size up exits 0" "$RC" 0
assert_file_contains "DEVFLOW_SIZE beats legacy config" "$T_LOG" "--snapshot=daytona-small"

run_devflow config set DEVFLOW_SNAPSHOT custom-snap
run_devflow up tester/zeta --size large --no-attach
assert_rc "custom snapshot up exits 0" "$RC" 0
assert_file_contains "custom snapshot passed through" "$T_LOG" "--snapshot=custom-snap"
assert_contains "custom snapshot ignores --size" "$OUT" "has its size baked in"

# ===========================================================================
echo "# 9..custom snapshot build"
# ===========================================================================
fresh_env

run_devflow snapshot build --size large
assert_rc "snapshot build exits 0" "$RC" 0
assert_file_contains "snapshot build size-suffixed name" "$T_LOG" "snapshot create devflow-base-"
assert_file_contains "snapshot build bakes large cpu" "$T_LOG" "--cpu=4"
assert_file_contains "snapshot build memory is GB" "$T_LOG" "--memory=8"
assert_file_contains "snapshot build bakes large disk" "$T_LOG" "--disk=10"
assert_file_contains "snapshot build set as default" "$T_CONFIG/config" "DEVFLOW_SNAPSHOT=devflow-base-"
assert_contains "snapshot build config name carries the size" "$(cat "$T_CONFIG/config")" "-large"

run_devflow up tester/iota --no-attach
assert_rc "up after snapshot build exits 0" "$RC" 0
assert_file_contains "up creates from the built snapshot" "$T_LOG" "--snapshot=devflow-base-"

run_devflow snapshot build --size huge
assert_rc "snapshot build rejects bad size" "$RC" 1
assert_contains "snapshot build bad size message" "$OUT" "invalid size"

# ===========================================================================
echo "# 10..run a script in the sandbox (+ --with-daytona)"
# ===========================================================================
fresh_env

printf '#!/usr/bin/env bash\necho repro-ran\n' > "$T_CWD/repro.sh"

run_devflow up tester/kappa --script repro.sh --no-attach
assert_rc "up --script exits 0" "$RC" 0
assert_contains "script launch announced" "$OUT" "script running"
assert_contains "script peek hint" "$OUT" "peek dv-kappa -w script"
assert_eq "script content uploaded intact" "$(extract_pushed_file /tmp/.dv-user-script)" "$(cat "$T_CWD/repro.sh")"
SCRIPT_LAUNCH="$(extract_pushed_file /tmp/.dv-script)"
assert_contains "launcher opens tmux window 'script'" "$SCRIPT_LAUNCH" "new-window -d -t dv -n script"
SCRIPT_EXEC="$(extract_pushed_file /tmp/.dv-script-exec)"
assert_contains "runner tees to the log" "$SCRIPT_EXEC" "script.log"
assert_file_contains "launcher invoked in sandbox" "$T_LOG" "dv-script"

run_devflow up tester/kappa --script repro.sh --no-attach
assert_rc "script rerun on existing sandbox exits 0" "$RC" 0
assert_contains "script reruns on the existing sandbox" "$OUT" "script running"
assert_not_contains "script rerun honors --no-attach" "$OUT" "FAKE-SSH"

printf 'echo positional\n' > "$T_CWD/positional.sh"
run_devflow up positional.sh --no-attach
assert_rc "positional script file exits 0" "$RC" 0
assert_contains "positional file treated as script" "$OUT" "script running"
assert_eq "positional script uploaded" "$(extract_pushed_file /tmp/.dv-user-script)" "$(cat "$T_CWD/positional.sh")"

run_devflow up tester/kappa --script nope.sh --no-attach
assert_rc "missing script rejected" "$RC" 1
assert_contains "missing script message" "$OUT" "script not found"

run_devflow up tester/lambda --with-daytona --no-attach
assert_rc "up --with-daytona exits 0" "$RC" 0
assert_contains "forwarding announced" "$OUT" "forwarding Daytona control"
assert_contains "sibling-sandbox caveat shown" "$OUT" "siblings"
DTCONF="$(extract_pushed_file /tmp/.dv-daytona-config)"
assert_contains "forwarded config carries the api key" "$DTCONF" "dtn_FAKEKEY"
assert_contains "forwarded config carries the api url" "$DTCONF" "fake.daytona.local"
assert_contains "devflow itself pushed into the sandbox" "$(extract_pushed_file /tmp/.dv-devflow)" "devflow — your agentic cloud dev environment"
assert_file_contains "daytona cli install targeted" "$T_LOG" "daytona-linux-amd64"

run_devflow peek dv-lambda -w script
assert_rc "peek -w exits 0" "$RC" 0
assert_file_contains "peek -w targets the requested window" "$T_LOG" "dv:script"

# browser login (no api key, OAuth token only) → devflow mints + caches a key
BROWSER_CFG='{"activeProfile":"initial","profiles":[{"id":"initial","name":"initial","api":{"url":"https://fake.daytona.local/api","key":null,"token":{"accessToken":"FAKE_OAUTH"}},"activeOrganizationId":"org-123"}]}'
printf '%s' "$BROWSER_CFG" > "$T_HOME/Library/Application Support/daytona/config.json"
printf '%s' "$BROWSER_CFG" > "$T_HOME/.config/daytona/config.json"
run_devflow up tester/mu --with-daytona --no-attach
assert_rc "with-daytona (browser login) exits 0" "$RC" 0
assert_contains "mint announced" "$OUT" "minted Daytona API key"
assert_file_contains "minted key cached in secrets" "$T_CONFIG/secrets" "dtn_MINTEDFAKE"
assert_contains "sandbox got the minted key" "$(extract_pushed_file /tmp/.dv-daytona-config)" "dtn_MINTEDFAKE"
assert_contains "sandbox config carries the org" "$(extract_pushed_file /tmp/.dv-daytona-config)" "org-123"

# ===========================================================================
echo "# 11..payload self-checks"
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
assert_contains "dockerfile installs go" "$DOCKERFILE" "go.dev/dl/go"
assert_contains "dockerfile installs bun" "$DOCKERFILE" "bun.sh/install"
assert_contains "dockerfile installs uv" "$DOCKERFILE" "astral.sh/uv"
assert_contains "dockerfile installs build tools" "$DOCKERFILE" "build-essential"
assert_contains "dockerfile links node for non-interactive shells" "$DOCKERFILE" '.local/bin/node'

# ===========================================================================
printf '\n# results: %d passed, %d failed, %d total\n' "$PASS" "$FAIL" "$TESTN"
[ "$FAIL" = 0 ] || exit 1
echo "# ALL TESTS PASSED"
