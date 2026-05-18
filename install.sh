#!/bin/bash
set -e

REPO="mrnickson-hue/x-ui-title-proxy"
BINARY_NAME="x-ui-proxy"
INSTALL_BIN="/usr/local/bin/x-ui-proxy"
CONFIG_DIR="/etc/x-ui-proxy"
CONFIG_FILE="$CONFIG_DIR/config.json"
SERVICE_FILE="/etc/systemd/system/x-ui-proxy.service"

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

info()    { echo -e "${CYAN}[*]${NC} $1"; }
success() { echo -e "${GREEN}[✓]${NC} $1"; }
warn()    { echo -e "${YELLOW}[!]${NC} $1"; }
error()   { echo -e "${RED}[✗]${NC} $1"; exit 1; }

echo ""
echo -e "${CYAN}╔══════════════════════════════════════╗${NC}"
echo -e "${CYAN}║     x-ui-title-proxy  installer      ║${NC}"
echo -e "${CYAN}╚══════════════════════════════════════╝${NC}"
echo ""

# Check root
[ "$EUID" -ne 0 ] && error "Please run as root"

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH_SUFFIX="linux-amd64" ;;
  aarch64) ARCH_SUFFIX="linux-arm64" ;;
  *) error "Unsupported architecture: $ARCH" ;;
esac

# Get latest release tag
info "Fetching latest release..."
LATEST=$(curl -sSf "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | cut -d'"' -f4)
[ -z "$LATEST" ] && error "Could not fetch latest release. Check your internet connection."
info "Latest version: $LATEST"

# --- Collect configuration ---
echo ""
echo -e "${YELLOW}Please provide the following configuration:${NC}"
echo ""

read -rp "  Proxy listen port        [8585]: " LISTEN_PORT
LISTEN_PORT="${LISTEN_PORT:-8585}"

read -rp "  3X-UI panel backend port [8584]: " BACKEND_PORT
BACKEND_PORT="${BACKEND_PORT:-8584}"

read -rp "  SSL certificate file     [/etc/x-ui/ssl/fullchain.cer]: " CERT_FILE
CERT_FILE="${CERT_FILE:-/etc/x-ui/ssl/fullchain.cer}"

# Try to auto-detect key file
DEFAULT_KEY=""
KEY_DIR=$(dirname "$CERT_FILE")
KEY_CANDIDATE=$(ls "$KEY_DIR"/*.key 2>/dev/null | head -1)
[ -n "$KEY_CANDIDATE" ] && DEFAULT_KEY="$KEY_CANDIDATE"
[ -z "$DEFAULT_KEY" ] && DEFAULT_KEY="/etc/x-ui/ssl/your-domain.key"

read -rp "  SSL private key file     [$DEFAULT_KEY]: " KEY_FILE
KEY_FILE="${KEY_FILE:-$DEFAULT_KEY}"

read -rp "  Custom browser tab title [My VPN Server]: " TITLE
TITLE="${TITLE:-My VPN Server}"

# Validate files exist
[ ! -f "$CERT_FILE" ] && warn "Certificate file not found: $CERT_FILE (continuing anyway)"
[ ! -f "$KEY_FILE"  ] && warn "Key file not found: $KEY_FILE (continuing anyway)"

echo ""
info "Summary:"
echo "    Listen:   :$LISTEN_PORT"
echo "    Backend:  https://127.0.0.1:$BACKEND_PORT"
echo "    Cert:     $CERT_FILE"
echo "    Key:      $KEY_FILE"
echo "    Title:    $TITLE"
echo ""
read -rp "  Proceed? [Y/n]: " CONFIRM
CONFIRM="${CONFIRM:-Y}"
[[ "$CONFIRM" =~ ^[Nn] ]] && echo "Aborted." && exit 0

# --- Download binary ---
echo ""
info "Downloading x-ui-proxy $LATEST ($ARCH_SUFFIX)..."
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$LATEST/${BINARY_NAME}-${ARCH_SUFFIX}"
curl -sSfL "$DOWNLOAD_URL" -o "$INSTALL_BIN"
chmod +x "$INSTALL_BIN"
success "Binary installed to $INSTALL_BIN"

# --- Write config ---
mkdir -p "$CONFIG_DIR"
cat > "$CONFIG_FILE" <<EOF
{
  "listen":  ":${LISTEN_PORT}",
  "backend": "https://127.0.0.1:${BACKEND_PORT}",
  "cert":    "${CERT_FILE}",
  "key":     "${KEY_FILE}",
  "title":   "${TITLE}"
}
EOF
success "Config written to $CONFIG_FILE"

# --- Install systemd service ---
cat > "$SERVICE_FILE" <<EOF
[Unit]
Description=x-ui Title Proxy
After=network.target x-ui.service

[Service]
Type=simple
ExecStart=/usr/local/bin/x-ui-proxy -config /etc/x-ui-proxy/config.json
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable x-ui-proxy
systemctl restart x-ui-proxy
success "Service enabled and started"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Installation complete!                              ║${NC}"
echo -e "${GREEN}║                                                      ║${NC}"
echo -e "${GREEN}║  Proxy is running on port :${LISTEN_PORT}                   ║${NC}"
echo -e "${GREEN}║                                                      ║${NC}"
echo -e "${GREEN}║  To change title (no restart needed):                ║${NC}"
echo -e "${GREEN}║    nano /etc/x-ui-proxy/config.json                  ║${NC}"
echo -e "${GREEN}║                                                      ║${NC}"
echo -e "${GREEN}║  Service commands:                                   ║${NC}"
echo -e "${GREEN}║    systemctl status x-ui-proxy                       ║${NC}"
echo -e "${GREEN}║    systemctl restart x-ui-proxy                      ║${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════╝${NC}"
echo ""
