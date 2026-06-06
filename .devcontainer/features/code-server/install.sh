#!/usr/bin/env bash
# code-server devcontainer feature installer. Runs during image build.
# Requires curl in the base image.
set -euo pipefail

VERSION="${VERSION:-4.96.4}"

log() { echo "[code-server] $*"; }

# 1. code-server -------------------------------------------------------------
log "installing code-server ${VERSION}"
curl -fsSL https://code-server.dev/install.sh | sh -s -- --version "${VERSION}"

# 2. idempotent start script -------------------------------------------------
# Bound to the container loopback only; --auth none because the realm wss tunnel
# (login + workspace ownership) is the access boundary. Never published.
log "writing /usr/local/bin/realm-code-server-start"
# Quoted heredoc (<<'EOF'): ${1:-.} and pgrep must be written literally into the
# start script, NOT expanded here at build time.
cat > /usr/local/bin/realm-code-server-start <<'EOF'
#!/usr/bin/env bash
# Idempotent: start code-server on the container loopback if not already running.
# Arg 1 (optional) is the folder to open; defaults to the current directory.
# Match the bind flag (which the launched code-server has but THIS wrapper script's
# own path does not) so the guard never self-matches the start script on Linux.
pgrep -f -- '--bind-addr 127.0.0.1:8888' >/dev/null 2>&1 && exit 0
nohup code-server --auth none --bind-addr 127.0.0.1:8888 "${1:-.}" \
  >/tmp/code-server.log 2>&1 &
EOF
chmod +x /usr/local/bin/realm-code-server-start

log "done"
