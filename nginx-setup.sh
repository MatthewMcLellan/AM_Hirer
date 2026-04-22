#!/usr/bin/env bash
# ============================================================
# FIX-R EC2 AI Server — Nginx + Let's Encrypt HTTPS Setup
# Ubuntu 22.04 LTS
# Run as root or with sudo: sudo bash nginx-setup.sh
#
# Usage:
#   sudo bash nginx-setup.sh                    # interactive — prompts for domain
#   sudo bash nginx-setup.sh ai.example.com     # non-interactive
# ============================================================
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; CYAN='\033[0;36m'; NC='\033[0m'
info()    { echo -e "${GREEN}[INFO]${NC}  $*"; }
warn()    { echo -e "${YELLOW}[WARN]${NC}  $*"; }
error()   { echo -e "${RED}[ERROR]${NC} $*"; exit 1; }
section() { echo -e "\n${CYAN}══ $* ══${NC}"; }

[[ $EUID -ne 0 ]] && error "Run as root: sudo bash nginx-setup.sh"

SCRIPT_DIR="$(dirname "$0")"

# ── Domain name ───────────────────────────────────────────────
DOMAIN="${1:-}"

if [[ -z "$DOMAIN" ]]; then
  echo ""
  echo -e "${YELLOW}============================================================"
  echo " What domain will point to this server?"
  echo " Example: ai.ams-seattle.com"
  echo ""
  echo " BEFORE continuing, make sure you have:"
  echo "   1. A domain name (or subdomain)"
  echo "   2. An A record: your-domain -> this EC2's public IP"
  echo "   3. EC2 security group open on ports 80 and 443"
  echo "============================================================${NC}"
  read -r -p "Enter your domain name: " DOMAIN
fi

[[ -z "$DOMAIN" ]] && error "Domain name is required."

# Basic sanity check — must contain a dot
[[ "$DOMAIN" != *.* ]] && error "That doesn't look like a valid domain: $DOMAIN"

info "Setting up HTTPS for: $DOMAIN"

# ── 1. System packages ────────────────────────────────────────
section "Installing packages"
apt-get update -qq
apt-get install -y -qq nginx certbot python3-certbot-nginx curl dnsutils

info "Nginx and Certbot installed."

# ── 2. Verify port 80 is accessible ──────────────────────────
section "Checking port 80 reachability"

# Get this instance's public IP from EC2 metadata service
INSTANCE_IP=$(curl -sf --max-time 5 http://169.254.169.254/latest/meta-data/public-ipv4 2>/dev/null || echo "unknown")
if [[ "$INSTANCE_IP" != "unknown" ]]; then
  info "This instance's public IP: $INSTANCE_IP"
fi

# Check that the domain resolves to this instance's IP
info "Checking DNS: does $DOMAIN resolve to $INSTANCE_IP?"
RESOLVED_IP=$(dig +short "$DOMAIN" 2>/dev/null | tail -1 || true)
if [[ -z "$RESOLVED_IP" ]]; then
  warn "Could not resolve $DOMAIN — DNS may not have propagated yet."
  warn "Certbot requires the domain to resolve before it can issue a certificate."
  read -r -p "Continue anyway? [y/N]: " CONTINUE_DNS
  [[ "${CONTINUE_DNS,,}" != "y" ]] && error "Aborted. Fix DNS and re-run."
elif [[ "$RESOLVED_IP" != "$INSTANCE_IP" && "$INSTANCE_IP" != "unknown" ]]; then
  warn "$DOMAIN resolves to $RESOLVED_IP, but this instance is $INSTANCE_IP"
  warn "Make sure your DNS A record points to $INSTANCE_IP."
  read -r -p "Continue anyway? [y/N]: " CONTINUE_DNS
  [[ "${CONTINUE_DNS,,}" != "y" ]] && error "Aborted. Fix DNS A record and re-run."
else
  info "DNS OK — $DOMAIN -> $RESOLVED_IP"
fi

# Check that port 80 is locally bound (Nginx is actually listening)
info "Verifying Nginx is listening on port 80..."
if ss -tlnp 2>/dev/null | grep -q ':80 ' || netstat -tlnp 2>/dev/null | grep -q ':80 '; then
  info "Nginx is listening on port 80."
else
  warn "Port 80 does not appear to be bound yet — Nginx may still be starting."
fi

# Remind user about the external requirement — diagnostic only, never blocks
echo ""
echo -e "${YELLOW}  REMINDER: Before Certbot can issue a certificate, port 80 must be"
echo "  reachable from the internet (not just locally)."
echo ""
echo "  In AWS Console → EC2 → Security Groups → Inbound rules, confirm:"
echo "    Port 80  | TCP | Source: 0.0.0.0/0"
echo "    Port 443 | TCP | Source: 0.0.0.0/0"
echo ""
echo "  If Certbot fails with a connection error, fix the security group"
echo "  and re-run: sudo certbot --nginx -d $DOMAIN${NC}"
echo ""

# ── 3. Install Nginx config ───────────────────────────────────
section "Configuring Nginx"
CONF_SRC="${SCRIPT_DIR}/nginx-ollama.conf"
CONF_DEST="/etc/nginx/sites-available/ollama"

if [[ -f "$CONF_SRC" ]]; then
  cp "$CONF_SRC" "$CONF_DEST"
else
  # Write the config inline if the file wasn't copied over
  cat > "$CONF_DEST" << 'NGINXCONF'
server {
    listen 80;
    server_name DOMAIN_PLACEHOLDER;

    location / {
        proxy_pass         http://127.0.0.1:11434;
        proxy_http_version 1.1;
        proxy_set_header   Host              $host;
        proxy_set_header   X-Real-IP         $remote_addr;
        proxy_set_header   X-Forwarded-For   $proxy_add_x_forwarded_for;
        proxy_set_header   X-Forwarded-Proto $scheme;
        proxy_read_timeout    120s;
        proxy_connect_timeout 10s;
        proxy_send_timeout    120s;
        client_max_body_size  50M;
        add_header Access-Control-Allow-Origin  "*" always;
        add_header Access-Control-Allow-Methods "GET, POST, OPTIONS" always;
        add_header Access-Control-Allow-Headers "Authorization, Content-Type" always;
        if ($request_method = OPTIONS) { return 204; }
    }
}
NGINXCONF
fi

# Substitute the domain into the config
sed -i "s/YOUR_DOMAIN_HERE/$DOMAIN/g; s/DOMAIN_PLACEHOLDER/$DOMAIN/g" "$CONF_DEST"

# Enable the site
ln -sf "$CONF_DEST" /etc/nginx/sites-enabled/ollama

# Remove the default site if present
rm -f /etc/nginx/sites-enabled/default

# Verify config is valid
nginx -t || error "Nginx config test failed. Check $CONF_DEST"
systemctl reload nginx
info "Nginx configured and running."

# ── 4. Lock Ollama to localhost ───────────────────────────────
section "Securing Ollama"
OLLAMA_OVERRIDE="/etc/systemd/system/ollama.service.d/override.conf"

# Always ensure OLLAMA_HOST=127.0.0.1:11434 — idempotent regardless of prior state
mkdir -p "$(dirname "$OLLAMA_OVERRIDE")"

NEEDS_RESTART=false

if [[ -f "$OLLAMA_OVERRIDE" ]]; then
  # Check current OLLAMA_HOST value
  CURRENT_HOST=$(grep -E '^Environment="OLLAMA_HOST=' "$OLLAMA_OVERRIDE" 2>/dev/null \
    | sed 's/.*OLLAMA_HOST=//; s/"//' || true)

  if [[ "$CURRENT_HOST" == "127.0.0.1:11434" ]]; then
    info "Ollama already bound to 127.0.0.1:11434 — no change needed."
  else
    # Remove any existing OLLAMA_HOST line and add the correct one
    sed -i '/OLLAMA_HOST/d' "$OLLAMA_OVERRIDE"
    echo 'Environment="OLLAMA_HOST=127.0.0.1:11434"' >> "$OLLAMA_OVERRIDE"
    warn "Updated OLLAMA_HOST to 127.0.0.1:11434 (was: ${CURRENT_HOST:-not set})."
    NEEDS_RESTART=true
  fi
else
  # Create fresh override
  cat > "$OLLAMA_OVERRIDE" << 'EOF'
[Service]
Environment="OLLAMA_HOST=127.0.0.1:11434"
EOF
  info "Created Ollama override — bound to localhost:11434."
  NEEDS_RESTART=true
fi

if [[ "$NEEDS_RESTART" == "true" ]]; then
  systemctl daemon-reload
  systemctl restart ollama
  sleep 3
  info "Ollama restarted — listening on localhost only."
fi

# ── 5. Obtain SSL certificate ─────────────────────────────────
section "Obtaining SSL certificate from Let's Encrypt"
info "Running Certbot for $DOMAIN..."
echo ""

certbot --nginx -d "$DOMAIN" --non-interactive --agree-tos \
  --register-unsafely-without-email \
  || {
    echo ""
    echo -e "${YELLOW}Certbot failed. Common causes:"
    echo "  1. Port 80 is not open in your EC2 security group"
    echo "  2. DNS A record for $DOMAIN hasn't propagated yet"
    echo "  3. The domain doesn't resolve to this instance's IP"
    echo ""
    echo "Fix the issue above, then re-run:"
    echo "  sudo certbot --nginx -d $DOMAIN"
    echo ""
    echo "Your Nginx proxy is already configured — only the certificate is missing.${NC}"
    exit 1
  }

info "SSL certificate issued successfully."

# ── 6. Verify auto-renewal ────────────────────────────────────
section "Enabling auto-renewal"
systemctl enable certbot.timer 2>/dev/null || true
certbot renew --dry-run &>/dev/null && info "Auto-renewal dry-run passed." \
  || warn "Auto-renewal dry-run failed — check 'certbot renew --dry-run' manually."

# ── 7. Stop and disable ngrok (if running) ────────────────────
section "Cleaning up ngrok"
if systemctl is-active --quiet fixr-ngrok 2>/dev/null; then
  systemctl stop fixr-ngrok
  systemctl disable fixr-ngrok
  info "ngrok service stopped and disabled."
else
  info "ngrok service not running — nothing to stop."
fi

# ── 8. Read API key for summary ───────────────────────────────
API_KEY_FILE="/etc/fixr/api.key"
API_KEY="(not set — run setup.sh first to configure)"
[[ -f "$API_KEY_FILE" ]] && API_KEY=$(cat "$API_KEY_FILE")

# ── 9. Summary ────────────────────────────────────────────────
echo ""
echo -e "${GREEN}============================================================"
echo " ✓  FIX-R Nginx + HTTPS setup complete!"
echo "============================================================${NC}"
echo ""
echo "  HTTPS endpoint : https://$DOMAIN"
echo "  API Key        : $API_KEY"
echo ""
echo "  Quick test:"
echo "    curl https://$DOMAIN/v1/models \\"
echo "      -H 'Authorization: Bearer \$API_KEY'"
echo ""
echo "  Update FIX-R → Admin → Servers:"
echo "    Old URL: (your ngrok URL)"
echo "    New URL: https://$DOMAIN"
echo ""
echo "  Certificate auto-renews via system timer every 12 hours."
echo "  Manual renewal: sudo certbot renew"
echo ""
echo "  Useful commands:"
echo "    sudo nginx -t                    # test config"
echo "    sudo systemctl reload nginx      # apply config changes"
echo "    journalctl -u nginx -f           # nginx logs"
echo "    journalctl -u ollama -f          # ollama logs"
echo ""
