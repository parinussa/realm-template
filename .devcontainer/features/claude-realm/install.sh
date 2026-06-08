#!/usr/bin/env bash
# claude-realm devcontainer feature installer.
# Runs during image build. Requires node+npm and curl/tar in the base image.
set -euo pipefail

CLAUDE_VERSION="${CLAUDEVERSION:-latest}"
AGENT_VAULT_VERSION="${AGENTVAULTVERSION:-0.21.1}"
AUTH_MODE="${AUTHMODE:-oauth}"

log() { echo "[claude-realm] $*"; }

# 1. Claude Code -------------------------------------------------------------
log "installing Claude Code (${CLAUDE_VERSION})"
npm install -g "@anthropic-ai/claude-code@${CLAUDE_VERSION}"

# 2. agent-vault client ------------------------------------------------------
log "installing agent-vault (${AGENT_VAULT_VERSION})"
arch="$(uname -m)"
case "$arch" in
  x86_64 | amd64) av_arch="amd64" ;;
  aarch64 | arm64) av_arch="arm64" ;;
  *) echo "[claude-realm] unsupported arch: $arch" >&2; exit 1 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT
url="https://github.com/Infisical/agent-vault/releases/download/v${AGENT_VAULT_VERSION}/agent-vault_${AGENT_VAULT_VERSION}_linux_${av_arch}.tar.gz"
log "downloading $url"
curl -fsSL -o "$tmp/av.tgz" "$url"
tar -xzf "$tmp/av.tgz" -C "$tmp"
bin="$(find "$tmp" -name agent-vault -type f | head -1)"
[ -n "$bin" ] || { echo "[claude-realm] agent-vault binary not found in archive" >&2; exit 1; }
install -m 0755 "$bin" /usr/local/bin/agent-vault

# 3. claude shim -------------------------------------------------------------
# Move the real launcher aside and replace `claude` with a wrapper that execs it
# under `agent-vault run`, so api.anthropic.com (and github, etc.) get credentials
# injected at the proxy boundary. The real token is never written into the container.
log "installing claude shim (auth mode: ${AUTH_MODE})"
REAL="$(command -v claude)"
DIR="$(dirname "$REAL")"
mv "$REAL" "$DIR/claude-real"

if [ "$AUTH_MODE" = "apikey" ]; then
  cat > "$DIR/claude" <<EOF
#!/bin/sh
# API-key mode: placeholder forces API mode; the proxy injects the real x-api-key.
export ANTHROPIC_API_KEY="\${ANTHROPIC_API_KEY:-placeholder-proxy-injects-real-key}"
exec agent-vault run -- "$DIR/claude-real" "\$@"
EOF
else
  cat > "$DIR/claude" <<EOF
#!/bin/sh
# OAuth mode: placeholder OAuth token makes Claude send Authorization: Bearer;
# the broker overrides it with the real CLAUDE_CODE_OAUTH_TOKEN. No API key set.
unset ANTHROPIC_API_KEY
export CLAUDE_CODE_OAUTH_TOKEN="\${CLAUDE_CODE_OAUTH_TOKEN:-placeholder-proxy-injects-real-token}"
exec agent-vault run -- "$DIR/claude-real" "\$@"
EOF
fi
chmod +x "$DIR/claude"

# 4. claude interactive onboarding seeder ------------------------------------
# Installs realm-claude-init; the template's postCreateCommand runs it (as the remote user) to
# seed ~/.claude.json so interactive `claude` skips onboarding/login + the folder-trust prompt.
log "installing realm-claude-init"
install -m 0755 "$(dirname "$0")/realm-claude-init" /usr/local/bin/realm-claude-init

log "done (claude -> agent-vault run -> claude-real)"
