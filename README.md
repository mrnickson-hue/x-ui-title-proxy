# x-ui-title-proxy

[🇷🇺 Русская версия](README_RU.md)

A lightweight HTTPS reverse proxy for [3X-UI](https://github.com/MHSanaei/3x-ui) that replaces the browser tab title with your own custom text and protects against accidental self-lockout — without modifying the panel itself.

**Before:** `node4.example.com - Inbounds`  
**After:** `My VPN Server (NODE1) - Inbounds`

The title is read from a config file on every request, so you can change it at any time **without restarting** the proxy.

> **Why does this exist?** A feature request to add custom title management directly to the 3X-UI admin panel was submitted to the project, but received no response from the developer. So this proxy was built as a self-contained alternative — no panel modifications, no waiting for upstream.

---

## How it works

```
Browser → :5555 (x-ui-title-proxy) → :5554 (3X-UI panel)
```

The proxy sits in front of your 3X-UI panel. For every HTML response it:

1. Extracts the CSP nonce from the response headers (3X-UI uses strict Content Security Policy)
2. Injects a small `<script>` tag with the nonce into `<head>`
3. The script replaces `document.title` on page load while preserving the page name suffix (e.g., ` - Inbounds`, ` - Settings`)

For every settings POST request it:

4. Strips the `webDomain` field before forwarding to the backend — so it can never be accidentally set via the panel UI (see [webDomain protection](#webdomain-protection))

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
| Proxy listen port | `5555` | The public port users connect to |
| 3X-UI backend port | `5554` | The port your panel will run on internally. The installer shows the current panel port and updates it automatically. |
| SSL certificate file | **auto-detected** | Path to your fullchain certificate |
| SSL private key file | **auto-detected** | Path to your private key |
| Custom title | `My VPN Server` | What to show in the browser tab |

The installer handles everything automatically:
- **SSL paths** — read from the 3X-UI database; falls back to scanning acme.sh, certbot, and `/etc/x-ui/ssl/`
- **Panel port** — shows the current port, then updates it in the 3X-UI database to the backend port you specify (no manual steps needed)
- **`webDomain` setting** — removed automatically if present (it causes 403 errors with the proxy)
- **Panel URL** — shown in the completion screen with the full address

---

## SSL certificate locations

The installer auto-detects your certificate, but if you need to find it manually — the location depends on how SSL was set up:

| How SSL was issued | Certificate | Private key |
|--------------------|-------------|-------------|
| 3X-UI panel built-in (`x-ui ssl`) | `/etc/x-ui/ssl/fullchain.cer` | `/etc/x-ui/ssl/<domain>.key` |
| acme.sh (standalone) | `~/.acme.sh/<domain>_ecc/fullchain.cer` | `~/.acme.sh/<domain>_ecc/<domain>.key` |
| Certbot / Let's Encrypt | `/etc/letsencrypt/live/<domain>/fullchain.pem` | `/etc/letsencrypt/live/<domain>/privkey.pem` |

The fastest way to check — ask 3X-UI itself (it stores the paths in its database):

```bash
sqlite3 /etc/x-ui/x-ui.db "SELECT key,value FROM settings WHERE key IN ('webCertFile','webKeyFile');"
```

---

## Configuration

Config file location: `/etc/x-ui-proxy/config.json`

```json
{
  "listen":  ":5555",
  "backend": "https://127.0.0.1:5554",
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

### Set panel port manually

If you installed manually, move the 3X-UI panel to the backend port yourself:

```bash
systemctl stop x-ui
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value=5554 WHERE key='webPort';"
systemctl start x-ui
```

> **Important:** stop x-ui before editing the database — otherwise it will overwrite your changes on restart.

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
bash <(curl -sSL https://raw.githubusercontent.com/mrnickson-hue/x-ui-title-proxy/main/install.sh) uninstall
```

The uninstaller will stop and remove the service, binary, and config. It will also offer to restore the 3X-UI panel port back to the public port.

---

## webDomain protection

3X-UI has a **"Panel Domain"** setting (`webDomain`) that, when set, restricts panel access to requests whose `Host` header matches the configured domain. This blocks all requests from the proxy (which connects via `127.0.0.1`) and causes 403 errors.

The installer clears `webDomain` during setup. But if someone accidentally sets it again through the panel UI, they get locked out with no way to fix it from the browser.

**Since v1.1.0**, the proxy intercepts every settings POST request and silently strips `webDomain` from the JSON body before forwarding it to the backend. The panel reports success, but `webDomain` is never written to the database. The lockout scenario becomes impossible.

If it does get triggered, you'll see a log entry:
```
x-ui-proxy: stripped webDomain="example.com" from settings request
```

---

## Troubleshooting

**Proxy starts but panel shows 403**  
This is caused by the `webDomain` setting in 3X-UI — it enables host-based request filtering that blocks the proxy. The installer removes it automatically. If you installed manually or upgraded from v1.0.x without reinstalling, fix it with:
```bash
systemctl stop x-ui
sqlite3 /etc/x-ui/x-ui.db "UPDATE settings SET value='' WHERE key='webDomain';"
systemctl start x-ui
```
After upgrading to v1.1.0, this issue cannot recur.

**Title not changing**  
Make sure you're connecting to the proxy port, not the panel directly. Check `config.json` for correct listen port.

**Service fails to start**  
Check that cert and key files exist and are readable:
```bash
journalctl -u x-ui-proxy --no-pager -n 20
ls -la /etc/x-ui/ssl/
```

**Port already in use**  
Another process is already on the listen port. Check what's using it:
```bash
ss -tlnp | grep 5555
```

---

## License

MIT
