# x-ui-title-proxy

A lightweight HTTPS reverse proxy for [3X-UI](https://github.com/MHSanaei/3x-ui) that replaces the browser tab title with your own custom text — without modifying the panel itself.

**Before:** `node4.example.com - Inbounds`  
**After:** `My VPN Server (NODE1) - Inbounds`

The title is read from a config file on every request, so you can change it at any time **without restarting** the proxy.

---

## How it works

```
Browser → :8585 (x-ui-title-proxy) → :8584 (3X-UI panel)
```

The proxy sits in front of your 3X-UI panel. For every HTML response it:

1. Extracts the CSP nonce from the response headers (3X-UI uses strict Content Security Policy)
2. Injects a small `<script>` tag with the nonce into `<head>`
3. The script replaces `document.title` on page load while preserving the page name suffix (e.g., ` - Inbounds`, ` - Settings`)

Everything else (API calls, WebSocket, static assets) is proxied transparently.

---

## Requirements

- Linux (amd64 or arm64)
- 3X-UI panel already installed and running
- SSL certificate for your domain (e.g., issued by Let's Encrypt / acme.sh)

---

## Quick install

```bash
bash <(curl -sSL https://raw.githubusercontent.com/mrnickson-hue/x-ui-title-proxy/main/install.sh)
```

The installer will ask you:

| Prompt | Default | Description |
|--------|---------|-------------|
| Proxy listen port | `8585` | The public port users connect to |
| 3X-UI backend port | `8584` | The port your panel runs on internally |
| SSL certificate file | `/etc/x-ui/ssl/fullchain.cer` | Path to your fullchain certificate |
| SSL private key file | auto-detected | Path to your private key |
| Custom title | `My VPN Server` | What to show in the browser tab |

After installation, move your 3X-UI panel to the backend port (see [Panel port setup](#panel-port-setup)).

---

## Panel port setup

You need 3X-UI to listen on the **backend port** (e.g., `8584`) so the proxy can forward requests to it.

**Option A — via the 3X-UI web panel:**  
Settings → Panel Settings → Panel port → set to `8584` → Save

**Option B — via SQLite (if the panel is inaccessible):**

```bash
systemctl stop x-ui
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value=8584 WHERE key='webPort';"
systemctl start x-ui
```

> **Important:** stop x-ui before editing the database — otherwise it will overwrite your changes on restart.

---

## Configuration

Config file location: `/etc/x-ui-proxy/config.json`

```json
{
  "listen":  ":8585",
  "backend": "https://127.0.0.1:8584",
  "cert":    "/etc/x-ui/ssl/fullchain.cer",
  "key":     "/etc/x-ui/ssl/your-domain.key",
  "title":   "My VPN Server (NODE1)"
}
```

| Field | Description |
|-------|-------------|
| `listen` | Address and port the proxy listens on |
| `backend` | Full URL of your 3X-UI panel (must be HTTPS) |
| `cert` | Path to SSL certificate (fullchain) |
| `key` | Path to SSL private key |
| `title` | Text shown in the browser tab |

### Changing the title

Edit the config file — **no restart required**, changes apply to the next page load:

```bash
nano /etc/x-ui-proxy/config.json
```

---

## Service management

```bash
# Check status and logs
systemctl status x-ui-proxy
journalctl -u x-ui-proxy -f

# Restart
systemctl restart x-ui-proxy

# Stop / disable autostart
systemctl stop x-ui-proxy
systemctl disable x-ui-proxy
```

---

## Manual installation

If you prefer to install manually or build from source:

### Download pre-built binary

```bash
# amd64
curl -sSfL https://github.com/mrnickson-hue/x-ui-title-proxy/releases/latest/download/x-ui-proxy-linux-amd64 \
  -o /usr/local/bin/x-ui-proxy && chmod +x /usr/local/bin/x-ui-proxy

# arm64
curl -sSfL https://github.com/mrnickson-hue/x-ui-title-proxy/releases/latest/download/x-ui-proxy-linux-arm64 \
  -o /usr/local/bin/x-ui-proxy && chmod +x /usr/local/bin/x-ui-proxy
```

### Build from source

```bash
git clone https://github.com/mrnickson-hue/x-ui-title-proxy.git
cd x-ui-title-proxy
CGO_ENABLED=0 go build -ldflags="-s -w" -o /usr/local/bin/x-ui-proxy .
```

### Create config

```bash
mkdir -p /etc/x-ui-proxy
cp config.example.json /etc/x-ui-proxy/config.json
nano /etc/x-ui-proxy/config.json
```

### Install systemd service

```bash
cp x-ui-proxy.service /etc/systemd/system/
systemctl daemon-reload
systemctl enable --now x-ui-proxy
```

---

## Updating

Re-run the installer to download the latest binary:

```bash
bash <(curl -sSL https://raw.githubusercontent.com/mrnickson-hue/x-ui-title-proxy/main/install.sh)
```

Your config file will not be touched.

---

## Uninstall

```bash
systemctl disable --now x-ui-proxy
rm /usr/local/bin/x-ui-proxy
rm /etc/systemd/system/x-ui-proxy.service
rm -rf /etc/x-ui-proxy
systemctl daemon-reload
```

---

## Troubleshooting

**Proxy starts but panel shows 403**  
Check if `webDomain` is set in 3X-UI settings — it causes host-based blocking. Remove it:
```bash
systemctl stop x-ui
sqlite3 /etc/x-ui/x-ui.db "DELETE FROM settings WHERE key='webDomain';"
systemctl start x-ui
```

**Title not changing**  
Make sure you're connecting to the proxy port, not the panel directly. Check `config.json` for correct listen port.

**Service fails to start**  
Check that cert and key files exist and are readable:
```bash
journalctl -u x-ui-proxy --no-pager -n 20
ls -la /etc/x-ui/ssl/
```

**Port already in use**  
Another process (likely x-ui itself) is already on the listen port. Make sure you've moved the panel to the backend port first.

---

## License

MIT
