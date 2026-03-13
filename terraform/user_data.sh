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
# 10. AWS CLI v2
# ---------------------------------------------------------------------------
echo "==> Installing AWS CLI v2"
if ! command -v aws &>/dev/null; then
  curl -fsSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
  unzip -q /tmp/awscliv2.zip -d /tmp
  /tmp/aws/install
  rm -rf /tmp/awscliv2.zip /tmp/aws
fi

# ---------------------------------------------------------------------------
# 11. Automated S3 backup
# ---------------------------------------------------------------------------
echo "==> Setting up automated S3 backup"

# Create bin dir and systemd user dir
mkdir -p "$OPENCLAW_HOME/bin"
mkdir -p "$OPENCLAW_HOME/.config/systemd/user"

# Write backup script (${project_name} and ${name_suffix} are substituted by Terraform templatefile)
cat > "$OPENCLAW_HOME/bin/openclaw-backup.sh" <<'BACKUP_SCRIPT'
#!/usr/bin/env bash
# openclaw-backup.sh — back up OpenClaw config to S3
# Auth via EC2 IAM instance profile (no keys needed)
# Excludes: openclaw.json (secrets), logs/, media/, workspace/ (git-tracked)

set -euo pipefail

BACKUP_BUCKET="${project_name}-backups-${name_suffix}"
BACKUP_PREFIX="backups"
OPENCLAW_DIR="/home/openclaw/.openclaw"
TIMESTAMP=$(date -u +"%Y-%m-%dT%H-%M-%SZ")
ARCHIVE="/tmp/openclaw-backup-$${TIMESTAMP}.tar.gz"

echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Starting OpenClaw backup..."

tar -czf "$ARCHIVE" \
  --exclude="$OPENCLAW_DIR/openclaw.json" \
  --exclude="$OPENCLAW_DIR/logs" \
  --exclude="$OPENCLAW_DIR/media" \
  --exclude="$OPENCLAW_DIR/workspace" \
  -C /home/openclaw .openclaw

SIZE=$(du -sh "$ARCHIVE" | cut -f1)
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Archive: $ARCHIVE ($SIZE)"

aws s3 cp "$ARCHIVE" "s3://$${BACKUP_BUCKET}/$${BACKUP_PREFIX}/$${TIMESTAMP}.tar.gz" \
  --region us-east-2

rm -f "$ARCHIVE"
echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] Backup complete → s3://$${BACKUP_BUCKET}/$${BACKUP_PREFIX}/$${TIMESTAMP}.tar.gz"
BACKUP_SCRIPT

chmod +x "$OPENCLAW_HOME/bin/openclaw-backup.sh"

# Write systemd service unit
cat > "$OPENCLAW_HOME/.config/systemd/user/openclaw-backup.service" <<'SERVICE_EOF'
[Unit]
Description=OpenClaw S3 Backup
After=network-online.target

[Service]
Type=oneshot
ExecStart=/home/openclaw/bin/openclaw-backup.sh
StandardOutput=journal
StandardError=journal
SERVICE_EOF

# Write systemd timer unit
cat > "$OPENCLAW_HOME/.config/systemd/user/openclaw-backup.timer" <<'TIMER_EOF'
[Unit]
Description=OpenClaw S3 Backup — daily at 03:00 UTC

[Timer]
OnCalendar=*-*-* 03:00:00 UTC
Persistent=true

[Install]
WantedBy=timers.target
TIMER_EOF

# Fix ownership
chown -R "$OPENCLAW_USER:$OPENCLAW_USER" "$OPENCLAW_HOME/bin" "$OPENCLAW_HOME/.config"

# Enable lingering so user services survive without an active login session
loginctl enable-linger "$OPENCLAW_USER"
sleep 2

# Enable and start the timer as the openclaw user
OPENCLAW_UID="$(id -u "$OPENCLAW_USER")"
sudo -u "$OPENCLAW_USER" \
  XDG_RUNTIME_DIR="/run/user/$OPENCLAW_UID" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$OPENCLAW_UID/bus" \
  systemctl --user daemon-reload
sudo -u "$OPENCLAW_USER" \
  XDG_RUNTIME_DIR="/run/user/$OPENCLAW_UID" \
  DBUS_SESSION_BUS_ADDRESS="unix:path=/run/user/$OPENCLAW_UID/bus" \
  systemctl --user enable --now openclaw-backup.timer

# ---------------------------------------------------------------------------
# Done
# ---------------------------------------------------------------------------
echo "==> Bootstrap complete"
echo "    Domain:       $DOMAIN"
echo "    SSH user:     $OPENCLAW_USER"
echo "    Next step:    Point DNS A record to this instance's Elastic IP"
echo "    Then run:     ssh openclaw@<elastic-ip>"
echo "                  openclaw onboard"
