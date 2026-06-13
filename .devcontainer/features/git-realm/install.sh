#!/usr/bin/env bash
# git-realm devcontainer feature installer. Routes network git through agent-vault.
set -euo pipefail
AGENT_VAULT_VERSION="${AGENTVAULTVERSION:-0.21.1}"
log() { echo "[git-realm] $*"; }

# agent-vault (no-op if claude-realm already installed it) ---------------------
if ! command -v agent-vault >/dev/null 2>&1; then
  log "installing agent-vault (${AGENT_VAULT_VERSION})"
  arch="$(uname -m)"
  case "$arch" in
    x86_64 | amd64) av_arch="amd64" ;;
    aarch64 | arm64) av_arch="arm64" ;;
    *) echo "[git-realm] unsupported arch: $arch" >&2; exit 1 ;;
  esac
  tmp="$(mktemp -d)"
  trap 'rm -rf "$tmp"' EXIT
  curl -fsSL -o "$tmp/av.tgz" \
    "https://github.com/Infisical/agent-vault/releases/download/v${AGENT_VAULT_VERSION}/agent-vault_${AGENT_VAULT_VERSION}_linux_${av_arch}.tar.gz"
  tar -xzf "$tmp/av.tgz" -C "$tmp"
  bin="$(find "$tmp" -name agent-vault -type f | head -1)"
  [ -n "$bin" ] || { echo "[git-realm] agent-vault binary not found in archive" >&2; exit 1; }
  install -m 0755 "$bin" /usr/local/bin/agent-vault
fi

# git shim --------------------------------------------------------------------
# The real git is moved to a dir OFF $PATH but keeps basename `git`: git's own dispatch
# treats an invocation named `git-<x>` as the subcommand <x> ("git-real" -> "cannot handle
# real as a builtin"), so it must NOT be renamed with a `git-` prefix.
log "installing git shim"
REAL="$(command -v git)"
DIR="$(dirname "$REAL")"
REAL_DIR="/usr/local/lib/git-realm"
mkdir -p "$REAL_DIR"
mv "$REAL" "$REAL_DIR/git"
cat > "$DIR/git" <<'EOF'
#!/bin/sh
# Route NETWORK git ops through agent-vault so the git-host PAT is injected at the proxy.
# Local ops (status/commit/log/diff/...) bypass the broker — no round-trip, work offline.
[ -n "$AGENT_VAULT_GIT_WRAPPED" ] && exec /usr/local/lib/git-realm/git "$@"
export GIT_TERMINAL_PROMPT=0
case "$1" in
  clone|fetch|pull|push|ls-remote)
    # Run git under agent-vault (injects the PAT). The inner `sh -c` evaluates $GIT_SSL_CAINFO
    # AFTER agent-vault run has set it to the broker's MITM CA. Trust that CA for BOTH the
    # remote (sslCAInfo) AND the HTTPS proxy (proxySSLCAInfo — git verifies the proxy cert
    # against the system store otherwise). Pin HTTP/1.1 so the MITM can intercept (HTTP/2
    # would be forwarded un-injected).
    AGENT_VAULT_GIT_WRAPPED=1 exec agent-vault run -- sh -c \
      'exec /usr/local/lib/git-realm/git -c http.version=HTTP/1.1 -c http.sslCAInfo="$GIT_SSL_CAINFO" -c http.proxySSLCAInfo="$GIT_SSL_CAINFO" "$@"' \
      sh "$@" ;;
  *) exec /usr/local/lib/git-realm/git "$@" ;;
esac
EOF
chmod +x "$DIR/git"
log "done (git -> agent-vault run -> real git for network ops)"
