#!/bin/bash

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

# --- Uninstall mode ---
if [ "${1:-}" = "uninstall" ]; then
  echo -e "${YELLOW}This will remove x-ui-proxy completely.${NC}"
  echo ""

  # Show current backend port from config
  BACKEND_PORT_SAVED=""
  if [ -f "$CONFIG_FILE" ]; then
    BACKEND_PORT_SAVED=$(grep '"backend"' "$CONFIG_FILE" 2>/dev/null | grep -oP ':\K[0-9]+(?=")')
    echo -e "  ${CYAN}Current proxy config: $(cat $CONFIG_FILE)${NC}"
    echo ""
  fi

  read -rp "  Proceed with uninstall? [y/N]: " CONFIRM
  [[ ! "$CONFIRM" =~ ^[Yy] ]] && echo "Aborted." && exit 0

  # Stop and disable service
  info "Stopping x-ui-proxy service..."
  systemctl disable --now x-ui-proxy 2>/dev/null || true
  rm -f "$SERVICE_FILE"
  systemctl daemon-reload
  success "Service removed"

  # Remove binary and config
  rm -f "$INSTALL_BIN"
  rm -rf "$CONFIG_DIR"
  success "Files removed"

  # Optionally restore panel port
  if [ -n "$BACKEND_PORT_SAVED" ] && [ -f "/etc/x-ui/x-ui.db" ] && command -v sqlite3 &>/dev/null; then
    echo ""
    read -rp "  Restore 3X-UI panel port back to public port? Enter port or leave empty to skip: " RESTORE_PORT
    if [ -n "$RESTORE_PORT" ]; then
      systemctl stop x-ui 2>/dev/null || true
      sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='${RESTORE_PORT}' WHERE key='webPort';"
      systemctl start x-ui 2>/dev/null || true
      sleep 2
      success "Panel port restored to ${RESTORE_PORT}"
    fi
  fi

  echo ""
  echo -e "${GREEN}x-ui-proxy has been uninstalled.${NC}"
  echo ""
  exit 0
fi

# Detect architecture
ARCH=$(uname -m)
case "$ARCH" in
  x86_64)  ARCH_SUFFIX="linux-amd64" ;;
  aarch64) ARCH_SUFFIX="linux-arm64" ;;
  *) error "Unsupported architecture: $ARCH" ;;
esac

# Ensure sqlite3 is available (needed to read 3X-UI settings)
if ! command -v sqlite3 &>/dev/null; then
  info "sqlite3 not found, installing..."
  apt-get update -qq && apt-get install -y sqlite3 || \
    yum install -y sqlite || \
    warn "Could not install sqlite3 — panel port detection unavailable"
fi

# Get latest release tag
info "Fetching latest release..."
LATEST=$(curl -sSf "https://api.github.com/repos/$REPO/releases/latest" | grep '"tag_name"' | cut -d'"' -f4)
[ -z "$LATEST" ] && error "Could not fetch latest release. Check your internet connection."
info "Latest version: $LATEST"

# --- Auto-detect SSL paths from 3X-UI database ---
detect_ssl_from_xui() {
  local db="/etc/x-ui/x-ui.db"
  [ ! -f "$db" ] && return
  command -v sqlite3 &>/dev/null || return
  local cert key
  cert=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='webCertFile';" 2>/dev/null)
  key=$(sqlite3  "$db" "SELECT value FROM settings WHERE key='webKeyFile';"  2>/dev/null)
  [ -n "$cert" ] && DETECTED_CERT="$cert"
  [ -n "$key"  ] && DETECTED_KEY="$key"
}

# Scan common acme.sh / certbot locations as fallback
detect_ssl_from_fs() {
  # acme.sh ECC (most common with x-ui ssl command)
  for d in /root/.acme.sh/*_ecc /root/.acme.sh/*; do
    [ -f "$d/fullchain.cer" ] && DETECTED_CERT="$d/fullchain.cer" && \
    DETECTED_KEY=$(ls "$d"/*.key 2>/dev/null | head -1) && return
  done
  # certbot
  for d in /etc/letsencrypt/live/*/; do
    [ -f "${d}fullchain.pem" ] && DETECTED_CERT="${d}fullchain.pem" && \
    DETECTED_KEY="${d}privkey.pem" && return
  done
  # x-ui ssl folder
  [ -f "/etc/x-ui/ssl/fullchain.cer" ] && \
    DETECTED_CERT="/etc/x-ui/ssl/fullchain.cer" && \
    DETECTED_KEY=$(ls /etc/x-ui/ssl/*.key 2>/dev/null | head -1)
}

DETECTED_CERT=""
DETECTED_KEY=""
detect_ssl_from_xui
[ -z "$DETECTED_CERT" ] && detect_ssl_from_fs

DEFAULT_CERT="${DETECTED_CERT:-/etc/x-ui/ssl/fullchain.cer}"
DEFAULT_KEY="${DETECTED_KEY:-/etc/x-ui/ssl/your-domain.key}"

if [ -n "$DETECTED_CERT" ]; then
  info "SSL certificate auto-detected from 3X-UI settings"
fi

# Read current panel port from 3X-UI database
CURRENT_PANEL_PORT=""
if [ -f "/etc/x-ui/x-ui.db" ] && command -v sqlite3 &>/dev/null; then
  CURRENT_PANEL_PORT=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webPort';" 2>/dev/null)
fi

# --- Collect configuration ---
echo ""
echo -e "${YELLOW}Please provide the following configuration:${NC}"
if [ -n "$CURRENT_PANEL_PORT" ]; then
  echo -e "  ${CYAN}Current 3X-UI panel port: ${CURRENT_PANEL_PORT}${NC}"
else
  echo -e "  ${CYAN}Current 3X-UI panel port: not detected (3X-UI not installed or sqlite3 missing)${NC}"
fi
echo ""

read -rp "  Proxy listen port        [5555]: " LISTEN_PORT
LISTEN_PORT="${LISTEN_PORT:-5555}"

read -rp "  3X-UI panel backend port [5554]: " BACKEND_PORT
BACKEND_PORT="${BACKEND_PORT:-5554}"

read -rp "  SSL certificate file     [$DEFAULT_CERT]: " CERT_FILE
CERT_FILE="${CERT_FILE:-$DEFAULT_CERT}"

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

# --- Update 3X-UI panel port if needed ---
if [ -f "/etc/x-ui/x-ui.db" ] && command -v sqlite3 &>/dev/null; then
  if [ "$CURRENT_PANEL_PORT" != "$BACKEND_PORT" ]; then
    info "Changing 3X-UI panel port: ${CURRENT_PANEL_PORT} → ${BACKEND_PORT}..."
    systemctl stop x-ui 2>/dev/null || true
    sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='${BACKEND_PORT}' WHERE key='webPort';"
    systemctl start x-ui 2>/dev/null || true
    sleep 2
    success "Panel port updated to ${BACKEND_PORT}"
  else
    info "Panel port is already ${BACKEND_PORT}, no change needed"
  fi
fi

# --- Download binary ---
echo ""
info "Downloading x-ui-proxy $LATEST ($ARCH_SUFFIX)..."
systemctl stop x-ui-proxy 2>/dev/null || true
DOWNLOAD_URL="https://github.com/$REPO/releases/download/$LATEST/${BINARY_NAME}-${ARCH_SUFFIX}"
TMP_BIN="/tmp/x-ui-proxy-new"
rm -f "$TMP_BIN"
curl -sSL "$DOWNLOAD_URL" -o "$TMP_BIN"
[ $? -ne 0 ] && error "Download failed. Check your internet connection."
[ ! -s "$TMP_BIN" ] && error "Downloaded file is empty. Try again."
chmod +x "$TMP_BIN"
mv -f "$TMP_BIN" "$INSTALL_BIN"
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

# --- Remove webDomain from 3X-UI database (causes 403 for proxy requests) ---
fix_webdomain() {
  local db="/etc/x-ui/x-ui.db"
  [ ! -f "$db" ] && return
  command -v sqlite3 &>/dev/null || return
  local val
  val=$(sqlite3 "$db" "SELECT value FROM settings WHERE key='webDomain';" 2>/dev/null)
  [ -z "$val" ] && return
  info "Found webDomain=$val in 3X-UI database — removing it (causes 403 with proxy)..."
  systemctl stop x-ui 2>/dev/null || true
  sqlite3 "$db" "DELETE FROM settings WHERE key='webDomain';"
  systemctl start x-ui 2>/dev/null || true
  sleep 2
  success "webDomain removed — 3X-UI restarted"
}
fix_webdomain

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

# --- Detect panel URL ---
PANEL_URL=""
DOMAIN=""
BASE_PATH=""
if [ -f "/etc/x-ui/x-ui.db" ] && command -v sqlite3 &>/dev/null; then
  BASE_PATH=$(sqlite3 /etc/x-ui/x-ui.db "SELECT value FROM settings WHERE key='webBasePath';" 2>/dev/null)
fi
if [ -f "$CERT_FILE" ] && command -v openssl &>/dev/null; then
  DOMAIN=$(openssl x509 -noout -subject -in "$CERT_FILE" 2>/dev/null \
    | sed 's/.*CN\s*=\s*//' | sed 's/[, ].*//' | tr -d '\n')
fi
[ -z "$DOMAIN" ] && DOMAIN=$(hostname -I 2>/dev/null | awk '{print $1}')
[ -n "$DOMAIN" ] && PANEL_URL="https://${DOMAIN}:${LISTEN_PORT}${BASE_PATH}"

# --- Draw dynamic-width completion box ---
box_lines=(
  ""
  "  Installation complete!"
  ""
  "  Proxy port : ${LISTEN_PORT}"
)
[ -n "$PANEL_URL" ] && box_lines+=("  Panel URL  : ${PANEL_URL}")
box_lines+=(
  ""
  "  To change title (no restart needed):"
  "    nano /etc/x-ui-proxy/config.json"
  ""
  "  Service commands:"
  "    systemctl status x-ui-proxy"
  "    systemctl restart x-ui-proxy"
  ""
)

W=0
for l in "${box_lines[@]}"; do
  len=${#l}
  [ "$len" -gt "$W" ] && W=$len
done
W=$((W + 2))

BDR=""
for ((i=0; i<W; i++)); do BDR+="═"; done

echo ""
echo -e "${GREEN}╔${BDR}╗${NC}"
for l in "${box_lines[@]}"; do
  printf "${GREEN}║%-${W}s║${NC}\n" "$l"
done
echo -e "${GREEN}╚${BDR}╝${NC}"
echo ""
