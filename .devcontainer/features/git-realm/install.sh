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
log "installing git shim"
REAL="$(command -v git)"
DIR="$(dirname "$REAL")"
mv "$REAL" "$DIR/git-real"
cat > "$DIR/git" <<'EOF'
#!/bin/sh
# Route NETWORK git ops through agent-vault so the git-host PAT is injected at the proxy.
# Local ops (status/commit/log/diff/...) bypass the broker — no round-trip, work offline.
[ -n "$AGENT_VAULT_GIT_WRAPPED" ] && exec git-real "$@"
export GIT_TERMINAL_PROMPT=0
case "$1" in
  clone|fetch|pull|push|ls-remote)
    # agent-vault's MITM proxy intercepts HTTP/1.1 only; pin git to it so an HTTP/2
    # negotiation can't bypass credential injection.
    AGENT_VAULT_GIT_WRAPPED=1 exec agent-vault run -- git-real -c http.version=HTTP/1.1 "$@" ;;
  *) exec git-real "$@" ;;
esac
EOF
chmod +x "$DIR/git"
log "done (git -> agent-vault run -> git-real for network ops)"
