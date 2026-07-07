#!/usr/bin/env bash
# devflow installer
#
#   curl -fsSL https://raw.githubusercontent.com/dalinkstone/devflow/main/install.sh | bash
#
# Installs the `devflow` CLI (plus a `dv` alias) and, when missing, its
# dependencies: the Daytona CLI, jq, and gh. Nothing here needs sudo unless
# you point DEVFLOW_INSTALL_DIR at a root-owned directory.
set -u
set -o pipefail

REPO="dalinkstone/devflow"
RAW="https://raw.githubusercontent.com/$REPO/main"
DAYTONA_VERSION="${DAYTONA_VERSION:-0.194.0}"
INSTALL_DIR="${DEVFLOW_INSTALL_DIR:-$HOME/.local/bin}"

bold() { printf '\033[1m%s\033[0m\n' "$*"; }
info() { printf '\033[34m▸\033[0m %s\n' "$*"; }
ok()   { printf '\033[32m✓\033[0m %s\n' "$*"; }
warn() { printf '\033[33m!\033[0m %s\n' "$*" >&2; }
die()  { printf '\033[31m✗\033[0m %s\n' "$*" >&2; exit 1; }

have() { command -v "$1" >/dev/null 2>&1; }

OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
case "$(uname -m)" in
  arm64|aarch64) ARCH=arm64 ;;
  *)             ARCH=amd64 ;;
esac
case "$OS" in
  darwin|linux) ;;
  *) die "unsupported OS: $OS (devflow needs macOS or Linux)" ;;
esac

mkdir -p "$INSTALL_DIR"

bold "devflow installer"

# --- devflow itself ---------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]:-.}")" 2>/dev/null && pwd || pwd)"
if [ -f "$SCRIPT_DIR/bin/devflow" ]; then
  info "installing devflow from local checkout…"
  cp "$SCRIPT_DIR/bin/devflow" "$INSTALL_DIR/devflow"
else
  info "downloading devflow…"
  curl -fsSL "$RAW/bin/devflow" -o "$INSTALL_DIR/devflow" || die "download failed: $RAW/bin/devflow"
fi
chmod +x "$INSTALL_DIR/devflow"
ln -sf "$INSTALL_DIR/devflow" "$INSTALL_DIR/dv"
ok "devflow → $INSTALL_DIR/devflow (alias: dv)"

# --- dependencies -----------------------------------------------------------
install_daytona() {
  if have brew; then
    info "installing Daytona CLI via Homebrew…"
    brew install daytonaio/cli/daytona && return 0
  fi
  info "installing Daytona CLI v$DAYTONA_VERSION…"
  curl -fsSL "https://github.com/daytona/clients/releases/download/v${DAYTONA_VERSION}/daytona-${OS}-${ARCH}" \
    -o "$INSTALL_DIR/daytona" || return 1
  chmod +x "$INSTALL_DIR/daytona"
}

install_jq() {
  if have brew; then brew install jq && return 0; fi
  local jq_arch
  case "$ARCH" in arm64) jq_arch=arm64 ;; *) jq_arch=amd64 ;; esac
  local jq_os
  case "$OS" in darwin) jq_os=macos ;; *) jq_os=linux ;; esac
  info "installing jq…"
  curl -fsSL "https://github.com/jqlang/jq/releases/download/jq-1.7.1/jq-${jq_os}-${jq_arch}" \
    -o "$INSTALL_DIR/jq" || return 1
  chmod +x "$INSTALL_DIR/jq"
}

install_gh() {
  if have brew; then brew install gh && return 0; fi
  local v=2.96.0 t
  t="$(mktemp -d)"
  info "installing gh v$v…"
  if [ "$OS" = "darwin" ]; then
    curl -fsSL "https://github.com/cli/cli/releases/download/v${v}/gh_${v}_macOS_${ARCH}.zip" -o "$t/gh.zip" \
      && unzip -q "$t/gh.zip" -d "$t" \
      && cp "$t/gh_${v}_macOS_${ARCH}/bin/gh" "$INSTALL_DIR/gh"
  else
    curl -fsSL "https://github.com/cli/cli/releases/download/v${v}/gh_${v}_linux_${ARCH}.tar.gz" -o "$t/gh.tgz" \
      && tar -xzf "$t/gh.tgz" -C "$t" \
      && cp "$t/gh_${v}_linux_${ARCH}/bin/gh" "$INSTALL_DIR/gh"
  fi
  local rc=$?
  rm -rf "$t"
  [ $rc -eq 0 ] && chmod +x "$INSTALL_DIR/gh"
  return $rc
}

if have daytona; then ok "daytona already installed"; else install_daytona && ok "daytona installed" || warn "could not install daytona — see https://www.daytona.io/docs"; fi
if have jq;      then ok "jq already installed";      else install_jq && ok "jq installed"           || warn "could not install jq"; fi
if have gh;      then ok "gh already installed";      else install_gh && ok "gh installed"           || warn "could not install gh — see https://cli.github.com"; fi
if have fzf;     then ok "fzf found (nicer pickers)"; else info "optional: install fzf for fuzzy pickers"; fi

# --- PATH check --------------------------------------------------------------
case ":$PATH:" in
  *":$INSTALL_DIR:"*) ;;
  *)
    warn "$INSTALL_DIR is not on your PATH — add this to your shell profile:"
    printf '    export PATH="%s:$PATH"\n' "$INSTALL_DIR"
    ;;
esac

echo
bold "installed! next steps:"
printf '  1. %s\n' "devflow setup     # connect Daytona + your Claude/ChatGPT subscriptions"
printf '  2. %s\n' "devflow up        # start an agent session in the cloud"
printf '  3. %s\n' "devflow attach    # ...from anywhere, anytime"
