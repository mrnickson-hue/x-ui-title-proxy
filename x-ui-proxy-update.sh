#!/bin/bash
# x-ui-proxy auto-updater — runs daily via cron
# Checks GitHub for a new release and updates the binary if one is found.

REPO="mrnickson-hue/x-ui-title-proxy"
BINARY="/usr/local/bin/x-ui-proxy"
LOG_TAG="x-ui-proxy-update"

log() { echo "$(date '+%Y-%m-%d %H:%M:%S') [$LOG_TAG] $1"; }

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH_SUFFIX="linux-amd64" ;;
  aarch64) ARCH_SUFFIX="linux-arm64" ;;
  *)
    log "Unsupported architecture: $ARCH"
    exit 1
    ;;
esac

# Get current installed version
CURRENT=$("$BINARY" --version 2>/dev/null)
if [ -z "$CURRENT" ]; then
  log "Cannot determine current version, skipping"
  exit 0
fi

# Get latest release tag from GitHub
LATEST=$(curl -sSf --max-time 10 \
  "https://api.github.com/repos/$REPO/releases/latest" \
  | grep '"tag_name"' | cut -d'"' -f4)
if [ -z "$LATEST" ]; then
  log "GitHub API unreachable, skipping"
  exit 0
fi

# Compare (binary outputs "1.2.0", tag is "v1.2.0")
if [ "v$CURRENT" = "$LATEST" ]; then
  exit 0
fi

log "Update available: v$CURRENT → $LATEST — downloading..."

TMP=$(mktemp)
curl -sSfL --max-time 60 \
  "https://github.com/$REPO/releases/download/$LATEST/x-ui-proxy-$ARCH_SUFFIX" \
  -o "$TMP"
if [ $? -ne 0 ] || [ ! -s "$TMP" ]; then
  log "Download failed, skipping"
  rm -f "$TMP"
  exit 0
fi

chmod +x "$TMP"
systemctl stop x-ui-proxy
mv -f "$TMP" "$BINARY"
systemctl start x-ui-proxy
sleep 2

if systemctl is-active --quiet x-ui-proxy; then
  log "Updated successfully: v$CURRENT → $LATEST"
else
  log "Service failed to start after update — check: journalctl -u x-ui-proxy -n 20"
fi
