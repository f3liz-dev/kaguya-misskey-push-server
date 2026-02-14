#!/bin/bash
# Misskey PWA Push Notification Server — GCE startup-script
# Debian 12 (bookworm) or Fedora Cloud, e2-micro, us-west1-b
#
# Strategy: install Docker only, everything else runs in containers.
# No Erlang/Elixir/Node on host — no PPA issues, no version conflicts.
#
# Metadata key: startup-script (not user-data — that's COS only)
# Logs: sudo journalctl -u google-startup-scripts -f
#
# Prerequisites (run locally before creating instance):
#   1. gcloud secrets create push-server-env --data-file=.env
#   2. SA=$(gcloud iam service-accounts list \
#        --filter='email~compute@developer' --format='value(email)')
#      gcloud secrets add-iam-policy-binding push-server-env \
#        --member="serviceAccount:$SA" \
#        --role="roles/secretmanager.secretAccessor"
#
# Create instance (free tier compliant):
#   gcloud compute instances create push-kaguya \
#     --zone=us-west1-b \
#     --machine-type=e2-micro \
#     --image-family=debian-12 \
#     --image-project=debian-cloud \
#     --boot-disk-size=30GB \
#     --boot-disk-type=pd-standard \
#     --network-tier=STANDARD \
#     --provisioning-model=STANDARD \
#     --maintenance-policy=MIGRATE \
#     --metadata-from-file=startup-script=startup-script.sh \
#     --scopes=cloud-platform \
#     --tags=push-server

set -euo pipefail

log() { echo "[startup $(date -u +%H:%M:%S)] $*"; }

# --- idempotent guard ---
# GCE runs startup-script on every boot.
# Only do full setup once — on reboot just restart containers.
if [ -f /app/.setup-done ]; then
  log "already set up — starting services"
  cd /app/src
  sudo docker compose up -d
  exit 0
fi

log "==> starting first-boot setup"

# --- swap: 512MB ---
# e2-micro has 1GB RAM. Docker build needs headroom.
# Swap prevents OOM during image build.
log "==> creating 512MB swap"
if [ ! -f /swapfile ]; then
  # fallocate fails on GCE disk — use dd instead
  dd if=/dev/zero of=/swapfile bs=1M count=512 status=none
  chmod 600 /swapfile
  mkswap /swapfile
  swapon /swapfile
  echo '/swapfile none swap sw 0 0' >> /etc/fstab
fi
log "    swap ready"

# --- install Docker (OS-aware) ---
log "==> installing Docker"
if [ -f /etc/debian_version ]; then
  # Debian path — official Docker repo
  apt-get update -q
  apt-get install -y -q ca-certificates curl gnupg sqlite3 git

  install -m 0755 -d /etc/apt/keyrings
  curl -fsSL https://download.docker.com/linux/debian/gpg \
    | gpg --dearmor -o /etc/apt/keyrings/docker.gpg
  chmod a+r /etc/apt/keyrings/docker.gpg

  echo \
    "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.gpg] \
    https://download.docker.com/linux/debian \
    $(. /etc/os-release && echo "$VERSION_CODENAME") stable" \
    > /etc/apt/sources.list.d/docker.list

  apt-get update -q
  apt-get install -y -q docker-ce docker-ce-cli containerd.io docker-compose-plugin

elif [ -f /etc/fedora-release ]; then
 dnf remove -y docker \
                  docker-client \
                  docker-client-latest \
                  docker-common \
                  docker-latest \
                  docker-latest-logrotate \
                  docker-logrotate \
                  docker-selinux \
                  docker-engine-selinux \
                  docker-engine \
                  docker-cli \
                  docker-compose-plugin \
                  moby-engine
  dnf config-manager addrepo --from-repofile https://download.docker.com/linux/fedora/docker-ce.repo --overwrite
  dnf install -y docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
  dnf install -y sqlite git
fi

systemctl enable --now docker
log "    Docker $(docker --version)"

# --- fetch .env from Secret Manager ---
log "==> fetching .env from Secret Manager"
mkdir -p /app /data
chown 1000:1000 /data

# Use Secret Manager REST API directly
# gcloud is not reliably in PATH during startup-script execution
# The metadata server is always available at 169.254.169.254 — no auth needed
ACCESS_TOKEN=$(curl -sf \
  -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/instance/service-accounts/default/token" \
  | python3 -c "import json,sys; print(json.load(sys.stdin)['access_token'])")

PROJECT_ID=$(curl -sf \
  -H "Metadata-Flavor: Google" \
  "http://metadata.google.internal/computeMetadata/v1/project/project-id")

log "    project: $PROJECT_ID"

if ! curl -sf \
  -H "Authorization: Bearer $ACCESS_TOKEN" \
  "https://secretmanager.googleapis.com/v1/projects/$PROJECT_ID/secrets/push-server-env/versions/latest:access" \
  | python3 -c "
import json, sys, base64
d = json.load(sys.stdin)
print(base64.b64decode(d['payload']['data']).decode())
" > /app/.env 2>/tmp/secret-err; then
  log "ERROR: failed to fetch secret"
  log "  reason: $(cat /tmp/secret-err)"
  log "  check: SA has roles/secretmanager.secretAccessor"
  log "  check: secret name is 'push-server-env'"
  exit 1
fi

chmod 644 /app/.env

if [ ! -s /app/.env ]; then
  log "ERROR: .env is empty"
  exit 1
fi

log "    .env written ($(wc -l < /app/.env) lines)"

# --- clone repository ---
log "==> cloning repository"
if [ -d /app/src/.git ]; then
  log "    already cloned — pulling latest"
  cd /app/src && git pull
else
  # remove partial clone if exists
  rm -rf /app/src
  git clone https://github.com/f3liz-dev/kaguya-misskey-push-server /app/src
fi
log "    cloned"

# --- production compose override ---
# Mounts host /data into containers so SQLite is on the host disk.
# Survives container rebuilds. Survives docker compose down.
#
# Also symlink .env into /app/src — docker compose auto-loads .env
# from its working directory. Without this it fails with "not found".
ln -sf /app/.env /app/src/.env

cat > /app/src/docker-compose.override.yml << 'EOF'
services:
  elixir:
    restart: unless-stopped
    volumes:
      - /data:/data
EOF

log "    compose override written"

# --- firewall ---
log "==> configuring firewall"
if command -v ufw &>/dev/null; then
  ufw default deny incoming
  ufw default allow outgoing
  ufw allow ssh
  ufw --force enable
elif command -v firewall-cmd &>/dev/null; then
  firewall-cmd --permanent --add-service=ssh
  firewall-cmd --reload
fi
log "    firewall configured"

# --- start services ---
log "==> building and starting services"
cd /app/src

docker compose pull --quiet 2>/dev/null || true
sudo chmod 666 /var/run/docker.sock
sudo docker compose up -d --build --remove-orphans

sleep 10

# --- health check ---
log "==> health check"
if curl -sf http://localhost:4000/health | python3 -m json.tool; then
  log "    health check passed"
else
  log "    WARN: health check failed"
  log "    check: cd /app/src && docker compose logs"
fi

# --- deploy script ---
cat > /app/deploy.sh << 'DEPLOY'
#!/bin/bash
set -euo pipefail
log() { echo "[deploy] $*"; }

log "pulling latest code"
cd /app/src && git pull

log "rebuilding containers"
sudo docker compose up -d --build

sleep 5
log "health check"
curl -sf http://localhost/health | python3 -m json.tool
log "done"
DEPLOY
chmod +x /app/deploy.sh

# --- migrate script ---
cat > /app/migrate.sh << 'MIGRATE'
#!/bin/bash
set -euo pipefail
NEW_SERVER=${1:?"usage: migrate.sh <new-server-ip>"}
WAIT_MINUTES=${2:-30}

echo "==> verifying new server health"
NEW_HEALTH=$(curl -sf "http://$NEW_SERVER/health" || echo "FAILED")
if echo "$NEW_HEALTH" | grep -q '"db":true'; then
  echo "    new server healthy"
else
  echo "    ERROR: new server not healthy"
  echo "    $NEW_HEALTH"
  exit 1
fi

echo "==> waiting ${WAIT_MINUTES}m for pending queue to drain"
for i in $(seq $WAIT_MINUTES -1 1); do
  PENDING=$(sqlite3 /data/push_server.db \
    "SELECT COUNT(*) FROM pending_notifications" 2>/dev/null || echo "?")
  printf "\r    %2dm remaining — pending: %s  " "$i" "$PENDING"
  sleep 60
done
echo ""

PENDING=$(sqlite3 /data/push_server.db \
  "SELECT COUNT(*) FROM pending_notifications" 2>/dev/null || echo "?")
echo "==> pending rows: $PENDING"
[ "$PENDING" != "0" ] && echo "    WARNING: rows still pending — check logs"

read -rp "==> stop services? [y/N] " confirm
if [[ "$confirm" == "y" ]]; then
  cd /app/src && sudo docker compose down
  echo "    stopped — safe to delete instance"
fi
MIGRATE
chmod +x /app/migrate.sh

# --- done ---
touch /app/.setup-done

log ""
log "==> SETUP COMPLETE"
log "    health:  curl http://localhost/health"
log "    logs:    cd /app/src && docker compose logs -f"
log "    deploy:  /app/deploy.sh"
log "    migrate: /app/migrate.sh <new-ip>"
