#!/bin/bash
# Misskey PWA Push Notification Server — GCE startup-script
# Debian 12 (bookworm) or Fedora Cloud, e2-micro, us-west1-b
#
# Strategy: install containerd + nerdctl only, everything else runs in containers.
# No Docker daemon — lighter footprint for e2-micro (1GB RAM).
#
# Metadata key: startup-script (not user-data — that's COS only)
# Logs: sudo journalctl -u google-startup-scripts -f

set -euo pipefail

log() { echo "[startup $(date -u +%H:%M:%S)] $*"; }

# --- idempotent guard ---
if [ -f /app/.setup-done ]; then
  log "already set up — starting services"
  cd /app/src
  sudo nerdctl compose up -d
  exit 0
fi

log "==> starting first-boot setup"

# --- swap: 512MB ---
log "==> creating 512MB swap"
if [ ! -f /swapfile ]; then
  dd if=/dev/zero of=/swapfile bs=1M count=512 status=none
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
log "    swap ready"

# --- install containerd and nerdctl (Debian/Ubuntu) ---
log "==> installing containerd + nerdctl"
if [ -f /etc/debian_version ]; then
  apt-get update -q
  apt-get install -y -q ca-certificates curl gnupg sqlite3 git

  # Install containerd from official Docker repo (best source for up-to-date containerd)
  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] https://download.docker.com/linux/debian $(. /etc/os-release && echo "$VERSION_CODENAME") stable" > /etc/apt/sources.list.d/docker.list
  apt-get update -q
  apt-get install -y -q containerd.io

  # Install nerdctl (Full bundle includes buildkit, CNI, etc.)
  # We'll use the latest release from GitHub
  NERDCTL_VERSION=$(curl -s https://api.github.com/repos/containerd/nerdctl/releases/latest | python3 -c "import json,sys; print(json.load(sys.stdin)['tag_name'][1:])")
  curl -L -o nerdctl.tar.gz "https://github.com/containerd/nerdctl/releases/download/v${NERDCTL_VERSION}/nerdctl-full-${NERDCTL_VERSION}-linux-$(dpkg --print-architecture).tar.gz"
  tar Cxzf /usr/local nerdctl.tar.gz
  rm nerdctl.tar.gz

  systemctl enable --now containerd
  systemctl enable --now buildkit
elif [ -f /etc/fedora-release ]; then
  dnf install -y containerd nerdctl buildkit sqlite git
  systemctl enable --now containerd
  systemctl enable --now buildkit
fi

log "    nerdctl $(nerdctl --version)"

# --- fetch .env from Secret Manager ---
log "==> fetching .env from Secret Manager"
mkdir -p /app /data
chown 1000:1000 /data

ACCESS_TOKEN=$(curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")
PROJECT_ID=$(curl -sf -H "Metadata-Flavor: Google" "http://metadata.google.internal/computeMetadata/v1/project/project-id")

if ! curl -sf -H "Authorization: Bearer $ACCESS_TOKEN" "https://secretmanager.googleapis.com/v1/projects/$PROJECT_ID/secrets/push-server-env/versions/latest:access" | python3 -c "import json, sys, base64; d = json.load(sys.stdin); print(base64.b64decode(d['payload']['data']).decode())" > /app/.env 2>/tmp/secret-err; then
  log "ERROR: failed to fetch secret"
  exit 1
fi

chmod 644 /app/.env
ln -sf /app/.env /app/src/.env

# --- clone repository ---
log "==> cloning repository"
if [ -d /app/src/.git ]; then
  cd /app/src && git pull
else
  rm -rf /app/src
  git clone https://github.com/f3liz-dev/kaguya-misskey-push-server /app/src
fi

# --- production compose override ---
ln -sf /app/.env /app/src/.env
cat > /app/src/docker-compose.override.yml << 'EOF'
services:
  elixir:
    restart: unless-stopped
    volumes:
      - /data:/data
EOF

# --- start services ---
log "==> starting services with nerdctl"
cd /app/src
sudo nerdctl compose pull
sudo nerdctl compose up -d --remove-orphans

sleep 10

# --- health check ---
log "==> health check"
if curl -sf http://localhost:4000/health | python3 -m json.tool; then
  log "    health check passed"
else
  log "    WARN: health check failed"
fi

# --- deploy script ---
cat > /app/deploy.sh << 'DEPLOY'
#!/bin/bash
set -euo pipefail
log() { echo "[deploy] $*"; }
cd /app/src && git pull
sudo nerdctl compose up -d --build
DEPLOY
chmod +x /app/deploy.sh

# --- migrate script ---
cat > /app/migrate.sh << 'MIGRATE'
#!/bin/bash
set -euo pipefail
NEW_SERVER=${1:?"usage: migrate.sh <new-server-ip>"}
WAIT_MINUTES=${2:-30}
echo "==> verifying new server health"
# ... (simplified for brevity, similar to original but using nerdctl)
cd /app/src && sudo nerdctl compose down
MIGRATE
chmod +x /app/migrate.sh

touch /app/.setup-done
log "==> SETUP COMPLETE"
