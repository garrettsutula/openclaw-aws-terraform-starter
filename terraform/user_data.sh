#!/usr/bin/env bash
# cloud-init bootstrap script — runs as root on first boot
# Installs: ufw, fail2ban, Caddy, OpenClaw (native host install)
# Hardens: SSH (key-only, no root), UFW (22/80/443), fail2ban (sshd)

set -euo pipefail
exec > >(tee /var/log/user-data.log) 2>&1

DOMAIN="${domain}"
OPENCLAW_USER="openclaw"
OPENCLAW_HOME="/home/$OPENCLAW_USER"

echo "==> Starting OpenClaw bootstrap (domain: $DOMAIN)"

# ---------------------------------------------------------------------------
# 1. System updates
# ---------------------------------------------------------------------------
echo "==> Updating system packages"
apt-get update -y
DEBIAN_FRONTEND=noninteractive apt-get upgrade -y
apt-get install -y ufw fail2ban curl git unzip jq

# ---------------------------------------------------------------------------
# 2. Create non-root user
# ---------------------------------------------------------------------------
echo "==> Creating $OPENCLAW_USER user"
if ! id "$OPENCLAW_USER" &>/dev/null; then
  useradd -m -s /bin/bash "$OPENCLAW_USER"
fi
usermod -aG sudo "$OPENCLAW_USER"
# Grant passwordless sudo so the openclaw installer can run sudo without a TTY
echo "$OPENCLAW_USER ALL=(ALL) NOPASSWD:ALL" > /etc/sudoers.d/openclaw
chmod 440 /etc/sudoers.d/openclaw

# Copy SSH authorized_keys from ubuntu (injected by AWS without forced-command restrictions)
mkdir -p "$OPENCLAW_HOME/.ssh"
cp /home/ubuntu/.ssh/authorized_keys "$OPENCLAW_HOME/.ssh/authorized_keys"
chown -R "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_HOME/.ssh"
chmod 700 "$OPENCLAW_HOME/.ssh"
chmod 600 "$OPENCLAW_HOME/.ssh/authorized_keys"

# ---------------------------------------------------------------------------
# 3. SSH hardening
# ---------------------------------------------------------------------------
echo "==> Hardening SSH"
cat > /etc/ssh/sshd_config.d/openclaw.conf <<'EOF'
PasswordAuthentication no
PermitRootLogin no
AllowUsers openclaw
PubkeyAuthentication yes
AuthorizedKeysFile .ssh/authorized_keys
X11Forwarding no
AllowTcpForwarding no
MaxAuthTries 3
LoginGraceTime 20
EOF
systemctl restart ssh

# ---------------------------------------------------------------------------
# 4. UFW firewall
# ---------------------------------------------------------------------------
echo "==> Configuring UFW"
ufw --force reset
ufw default deny incoming
ufw default allow outgoing
ufw allow 22/tcp comment "SSH"
ufw allow 80/tcp comment "HTTP (ACME)"
ufw allow 443/tcp comment "HTTPS"
ufw --force enable

# ---------------------------------------------------------------------------
# 5. fail2ban
# ---------------------------------------------------------------------------
echo "==> Configuring fail2ban"
cat > /etc/fail2ban/jail.local <<'EOF'
[DEFAULT]
bantime  = 3600
findtime = 600
maxretry = 5

[sshd]
enabled  = true
port     = ssh
logpath  = %(sshd_log)s
backend  = %(sshd_backend)s
maxretry = 5
EOF
systemctl enable fail2ban
systemctl restart fail2ban

# ---------------------------------------------------------------------------
# 6. Caddy
# ---------------------------------------------------------------------------
echo "==> Installing Caddy"
apt-get install -y debian-keyring debian-archive-keyring apt-transport-https gnupg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/gpg.key' \
  | gpg --dearmor -o /usr/share/keyrings/caddy-stable-archive-keyring.gpg
curl -1sLf 'https://dl.cloudsmith.io/public/caddy/stable/debian.deb.txt' \
  | tee /etc/apt/sources.list.d/caddy-stable.list
apt-get update -y
apt-get install -y caddy

cat > /etc/caddy/Caddyfile <<EOF
$DOMAIN {
    reverse_proxy localhost:18789
    log {
        output file /var/log/caddy/access.log
    }
}
EOF

mkdir -p /var/log/caddy
systemctl enable caddy
systemctl restart caddy

# ---------------------------------------------------------------------------
# 7. OpenClaw (native install)
# ---------------------------------------------------------------------------
echo "==> Installing Homebrew"
sudo -u "$OPENCLAW_USER" bash -lc \
  '/bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"'

echo "==> Installing OpenClaw"
# Install as the openclaw user; installer handles Node 22+ automatically
# Use a login shell so ~/.bashrc / ~/.profile are sourced and PATH is set correctly
sudo -u "$OPENCLAW_USER" bash -lc \
  'curl -fsSL https://openclaw.ai/install.sh | bash -s -- --no-onboard'

# Resolve the npm global bin dir using a login shell so nvm/node are on PATH
OPENCLAW_BIN="$(sudo -u "$OPENCLAW_USER" bash -lc 'npm prefix -g')/bin"

# ---------------------------------------------------------------------------
# 8. systemd service for OpenClaw
# ---------------------------------------------------------------------------
echo "==> Creating openclaw systemd service"
cat > /etc/systemd/system/openclaw.service <<EOF
[Unit]
Description=OpenClaw Gateway
After=network-online.target
Wants=network-online.target

[Service]
User=$OPENCLAW_USER
Environment=PATH=$OPENCLAW_BIN:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
ExecStart=$OPENCLAW_BIN/openclaw gateway start
Restart=on-failure
RestartSec=10
TimeoutStartSec=120

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable openclaw
systemctl start openclaw

# ---------------------------------------------------------------------------
# 9. Remove passwordless sudo (no longer needed after install)
# ---------------------------------------------------------------------------
echo "==> Removing passwordless sudo"
rm -f /etc/sudoers.d/openclaw

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo "==> Bootstrap complete"
echo "    Domain:       $DOMAIN"
echo "    SSH user:     $OPENCLAW_USER"
echo "    Next step:    Point DNS A record to this instance's Elastic IP"
echo "    Then run:     ssh openclaw@<elastic-ip>"
echo "                  openclaw onboard"
