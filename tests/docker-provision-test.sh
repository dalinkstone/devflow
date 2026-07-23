#!/usr/bin/env bash
# Validates the embedded sandbox provisioner inside a real Ubuntu container
# that mirrors Daytona's default sandbox image (non-root `daytona` user with
# passwordless sudo, no tmux preinstalled). Needs Docker + network.
#
#   bash tests/docker-provision-test.sh            # native arch
#   PLATFORM=linux/amd64 bash tests/docker-provision-test.sh
set -u

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMG="${IMG:-ubuntu:24.04}"
PLATFORM="${PLATFORM:-}"

command -v docker >/dev/null 2>&1 || { echo "SKIP: docker not available"; exit 0; }

WORK="$(mktemp -d "${TMPDIR:-/tmp}/devflow-docker.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT

"$ROOT/bin/devflow" __provision-script > "$WORK/provision.sh"

# fake-but-well-formed secrets (no real tokens; gh login fails gracefully,
# the clone target is a public repo so no auth is needed)
FAKE_CREDS='{"claudeAiOauth":{"accessToken":"sk-ant-oat01-FAKE","refreshToken":"sk-ant-ort01-FAKE","expiresAt":9999999999,"subscriptionType":"max"}}'
FAKE_CODEX='{"auth_mode":"chatgpt","tokens":{"id_token":"FAKE","access_token":"FAKE"},"last_refresh":"2026-01-01T00:00:00Z"}'
FAKE_AWS_CREDS='[devflow]
aws_access_key_id = ASIAFAKEDOCKER00000
aws_secret_access_key = fake-docker-secret
aws_session_token = fake-docker-session'
FAKE_AWS_CONFIG='[profile devflow]
region = us-west-2
output = json'
FAKE_FORWARDED='export DAYTONA_API_KEY=dtn_DOCKER_FAKE
export CLOUDFLARE_API_TOKEN=cf_DOCKER_FAKE'
{
  printf 'DV_CLAUDE_MODE=creds\n'
  printf 'DV_CLAUDE_TOKEN=\n'
  printf 'DV_CLAUDE_CREDS_B64=%s\n' "$(printf '%s' "$FAKE_CREDS" | base64 | tr -d '\n')"
  printf 'DV_CODEX_AUTH_B64=%s\n' "$(printf '%s' "$FAKE_CODEX" | base64 | tr -d '\n')"
  printf 'DV_GH_TOKEN=\n'
  printf 'DV_GIT_NAME=Docker\\ Test\n'
  printf 'DV_GIT_EMAIL=docker@test.local\n'
  printf 'DV_GH_PIN=2.96.0\n'
  printf 'DV_CODEX_PIN=rust-v0.142.5\n'
  printf 'DV_AWS_ENABLED=1\n'
  printf 'DV_AWS_CREDS_B64=%s\n' "$(printf '%s' "$FAKE_AWS_CREDS" | base64 | tr -d '\n')"
  printf 'DV_AWS_CONFIG_B64=%s\n' "$(printf '%s' "$FAKE_AWS_CONFIG" | base64 | tr -d '\n')"
  printf 'DV_AWS_EXPIRATION=2099-01-01T00:00:00Z\n'
  printf 'DV_AWS_SOURCE_PROFILE=devflow-deployer\n'
  printf 'DV_SECRET_ENV_B64=%s\n' "$(printf '%s' "$FAKE_FORWARDED" | base64 | tr -d '\n')"
  printf 'DV_SECRET_ENV_NAMES=DAYTONA_API_KEY\\ CLOUDFLARE_API_TOKEN\n'
} > "$WORK/secrets.env"

cat > "$WORK/inner.sh" <<'INNER'
#!/usr/bin/env bash
# Runs as root in the container: build a daytona-like user, then run the
# devflow provisioner as that user and assert the result.
set -e
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null
apt-get install -y -qq sudo curl ca-certificates git >/dev/null
userdel -r ubuntu 2>/dev/null || true
useradd -m -s /bin/bash daytona
echo 'daytona ALL=(ALL) NOPASSWD:ALL' > /etc/sudoers.d/91-daytona

# Daytona snapshots can ship an old Codex. Provisioning must replace it,
# rather than accepting any binary merely because it exists on PATH.
cat > /usr/local/bin/codex <<'STALE_CODEX'
#!/usr/bin/env bash
echo 'codex-cli 0.128.0'
STALE_CODEX
chmod 0755 /usr/local/bin/codex

install -d -o daytona -g daytona /home/daytona/.devflow /home/daytona/.devflow/stage
install -o daytona -g daytona -m 700 /payload/provision.sh /home/daytona/.devflow/stage/provision.sh
install -o daytona -g daytona -m 600 /payload/secrets.env /home/daytona/.devflow/stage/secrets.env

run_phase() {
  sudo -u daytona -H env \
    DV_PHASE="$1" DV_AGENT=none DV_REPO=octocat/Hello-World DV_BRANCH= \
    DV_NAME=dv-dockertest DV_TASK_B64= \
    DV_WORKROOT=work DV_HARNESS=both \
    bash /home/daytona/.devflow/stage/provision.sh
}

echo "=== phase: tools ==="
run_phase tools
echo "=== phase: auth ==="
run_phase auth
echo "=== phase: workspace ==="
run_phase workspace
echo "=== phase: harness ==="
run_phase harness

echo "=== assertions ==="
H=/home/daytona
PASS=0; FAIL=0
ok()   { PASS=$((PASS+1)); echo "ok - $1"; }
bad()  { FAIL=$((FAIL+1)); echo "NOT OK - $1"; }
check(){ if sudo -u daytona -H bash -lc "$2" >/dev/null 2>&1; then ok "$1"; else bad "$1"; fi; }
checkmode() { m="$(stat -c %a "$3")"; if [ "$m" = "$2" ]; then ok "$1"; else bad "$1 (mode $m, want $2)"; fi; }

check "tmux installed"            'command -v tmux'
check "gh installed"              'command -v gh && gh --version'
check "claude installed + runs"   'command -v claude && claude --version'
check "stale codex upgraded"      'command -v codex && codex --version | grep -q "0.142.5"'
check "jq installed"              'command -v jq'
check "ripgrep installed"         'command -v rg'
check "aws installed"             'command -v aws && aws --version'
check "eksctl installed"          'command -v eksctl'
check "kubectl installed"         'command -v kubectl'
check "helm installed"            'command -v helm'
check "helm-unittest installed"   'helm unittest --help'
check "yq installed"              'command -v yq'
check "envsubst installed"        'command -v envsubst'
check "shellcheck installed"      'command -v shellcheck'
check "docker cli installed"      'command -v docker'
check "python3 installed"         'command -v python3'

check "claude creds file"         "test -f $H/.claude/.credentials.json"
checkmode "claude creds 600"      600 "$H/.claude/.credentials.json"
check "codex auth file"           "test -f $H/.codex/auth.json"
checkmode "codex auth 600"        600 "$H/.codex/auth.json"
check "codex config full-access"  "grep -q danger-full-access $H/.codex/config.toml"
check "codex config never-approve" "grep -q 'approval_policy = \"never\"' $H/.codex/config.toml"
check "codex AGENTS.md"           "test -f $H/.codex/AGENTS.md"
check "claude onboarding skipped" "grep -q hasCompletedOnboarding $H/.claude.json"
check "claude project trusted"    "grep -q hasTrustDialogAccepted $H/.claude.json"
check "claude settings"           "test -f $H/.claude/settings.json"
check "claude CLAUDE.md"          "grep -q 'Daytona cloud sandbox' $H/.claude/CLAUDE.md"
check "git identity name"         "git config --global user.name | grep -q 'Docker Test'"
check "git identity email"        "git config --global user.email | grep -q docker@test.local"
check "secrets file shredded"     "test ! -f $H/.devflow/stage/secrets.env"
check "aws credentials file"      "grep -q ASIAFAKEDOCKER $H/.aws/credentials"
checkmode "aws credentials 600"   600 "$H/.aws/credentials"
check "aws config file"           "grep -q us-west-2 $H/.aws/config"
checkmode "aws config 600"        600 "$H/.aws/config"
check "aws expiry recorded"       "grep -q 2099-01-01 $H/.devflow/aws-expiration"
check "named secrets forwarded"   "grep -q CLOUDFLARE_API_TOKEN $H/.devflow/forwarded.env"
checkmode "forwarded secrets 600" 600 "$H/.devflow/forwarded.env"
check "main env loads AWS"        "grep -q aws.env $H/.devflow/env"
check "AWS expiration exported"   "grep -q 'AWS_CREDENTIAL_EXPIRATION=2099-01-01T00:00:00Z' $H/.devflow/aws.env"

check "repo cloned"               "test -d $H/work/Hello-World/.git"
check "workdir recorded"          "grep -q Hello-World $H/.devflow/workdir"
check "tmux.conf written"         "test -f $H/.tmux.conf"
check "bashrc hook"               "grep -q devflow/shellrc $H/.bashrc"
check "profile hook"              "grep -q devflow/shellrc $H/.profile"
check "dv-agent executable"       "test -x $H/.devflow/bin/dv-agent"
check "dv-task-start executable"  "test -x $H/.devflow/bin/dv-task-start"
check "dv-ensure executable"      "test -x $H/.devflow/bin/dv-ensure"
check "dv-statusline executable"  "test -x $H/.devflow/bin/dv-statusline"
check "dv-agent parses"           "bash -n $H/.devflow/bin/dv-agent"
check "dv-task-start parses"      "bash -n $H/.devflow/bin/dv-task-start"
check "dv-ensure parses"          "bash -n $H/.devflow/bin/dv-ensure"
check "shellrc parses"            "bash -n $H/.devflow/shellrc"
check "provisioned marker v5"     "grep -qx 5 $H/.devflow/provisioned"

check "detached tmux survived the provisioning caller" 'tmux has-session -t dv'
check "tmux window agent"         'tmux list-windows -t dv | grep -q agent'
check "tmux window shell"         'tmux list-windows -t dv | grep -q shell'

check "dv-engineer subagent"      "grep -q 'name: dv-engineer' $H/.claude/agents/dv-engineer.md"
check "dv-designer subagent"      "grep -q 'name: dv-designer' $H/.claude/agents/dv-designer.md"
check "dv-security subagent"      "grep -q 'name: dv-security' $H/.claude/agents/dv-security.md"
check "node available for harness" 'command -v node && command -v npm'
check "omc installed"             'command -v omc'
check "omc roster installed"      "ls $H/.claude/agents/ | wc -l | grep -qE '^[2-9][0-9]'"
check "omx installed"             'command -v omx'
check "omx healthy"               'omx list >/dev/null'
check "omx setup merged AGENTS"   "grep -q 'OMX:AGENTS' $H/.codex/AGENTS.md"
check "harness marker"            "grep -q both $H/.devflow/harness"

SL_OUT="$(printf '{"model":{"display_name":"Fable"},"workspace":{"current_dir":"/home/daytona/work/Hello-World"},"context_window":{"used_percentage":42}}' \
  | sudo -u daytona -H bash -lc "$H/.devflow/bin/dv-statusline")"
case "$SL_OUT" in
  *dv-dockertest*Fable*42*) ok "statusline renders ($SL_OUT)" ;;
  *) bad "statusline output: $SL_OUT" ;;
esac

echo "=== re-run idempotency ==="
if run_phase workspace >/dev/null 2>&1; then ok "workspace re-run idempotent"; else bad "workspace re-run"; fi

echo
echo "RESULTS: $PASS passed, $FAIL failed"
[ "$FAIL" = 0 ] || exit 1
echo "DOCKER PROVISION TEST PASSED"
INNER
chmod +x "$WORK/inner.sh"

if [ -n "$PLATFORM" ]; then
  exec docker run --rm --platform "$PLATFORM" -v "$WORK:/payload:ro" "$IMG" bash /payload/inner.sh
else
  exec docker run --rm -v "$WORK:/payload:ro" "$IMG" bash /payload/inner.sh
fi
