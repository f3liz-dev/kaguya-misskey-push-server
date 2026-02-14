# Deployment and Update Guide

## Quick Deploy (Recommended)

After pushing new images to GHCR, SSH to GCE and run:

```bash
/app/deploy.sh
```

This will:
1. ✅ Pull latest code from GitHub
2. ✅ Pull latest Docker images from GHCR
3. ✅ Stop old containers
4. ✅ Start new containers with fresh images
5. ✅ Run health check

---

## Manual Deployment Steps

### 1. Build and Push New Image

```bash
# On your local machine
cd kaguya-misskey-push-server/elixir

# Build (use BuildKit for faster builds)
export DOCKER_BUILDKIT=1
docker build -f Dockerfile.buildkit \
  -t ghcr.io/f3liz-dev/kaguya-misskey-push-server-elixir:latest .

# Push to registry
docker push ghcr.io/f3liz-dev/kaguya-misskey-push-server-elixir:latest
```

### 2. Deploy on GCE

```bash
# SSH to GCE instance
gcloud compute ssh <instance-name> --zone=<zone>

# Run deploy script
/app/deploy.sh
```

---

## Troubleshooting

### Containers not updating despite new image

**Problem:** `nerdctl compose up -d` doesn't recreate containers if they already exist.

**Solution:** The updated scripts now run `compose down` before `up` to force recreation.

Manual fix:
```bash
cd /app/src
sudo nerdctl compose pull
sudo nerdctl compose down
sudo nerdctl compose up -d
```

### Check which image version is running

```bash
# List running containers with images
sudo nerdctl ps --format "{{.Names}}\t{{.Image}}"

# Inspect container
sudo nerdctl inspect <container-name> | grep Image
```

### Force pull specific service

```bash
cd /app/src
sudo nerdctl compose pull elixir
sudo nerdctl compose up -d --force-recreate elixir
```

### View container logs

```bash
cd /app/src
sudo nerdctl compose logs -f elixir
```

### Check health status

```bash
curl http://localhost:4000/health | jq .

# Or from outside
curl https://push-server.f3liz.casa/health | jq .
```

---

## CI/CD Automation (Recommended)

### GitHub Actions Workflow

Create `.github/workflows/deploy.yml`:

```yaml
name: Build and Deploy

on:
  push:
    branches: [main]
    paths:
      - 'elixir/**'

jobs:
  build-and-deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      
      - name: Login to GHCR
        uses: docker/login-action@v3
        with:
          registry: ghcr.io
          username: ${{ github.actor }}
          password: ${{ secrets.GITHUB_TOKEN }}
      
      - name: Set up Docker Buildx
        uses: docker/setup-buildx-action@v3
      
      - name: Build and push
        uses: docker/build-push-action@v5
        with:
          context: ./elixir
          file: ./elixir/Dockerfile.buildkit
          push: true
          tags: ghcr.io/f3liz-dev/kaguya-misskey-push-server-elixir:latest
          cache-from: type=gha
          cache-to: type=gha,mode=max
      
      - name: Deploy to GCE
        uses: google-github-actions/ssh-compute@v0
        with:
          instance_name: <instance-name>
          zone: <zone>
          command: /app/deploy.sh
```

---

## Startup Script Updates

The startup script now ensures updates are applied on VM restart:

```bash
sudo nerdctl compose pull      # Pull latest images
sudo nerdctl compose down      # Stop old containers
sudo nerdctl compose up -d     # Start with new images
```

**Before:** Containers would just restart without checking for updates
**After:** Fresh containers with latest images on every VM restart

---

## Rollback

If new deployment has issues:

```bash
cd /app/src

# Pull specific version
sudo nerdctl pull ghcr.io/f3liz-dev/kaguya-misskey-push-server-elixir:<old-tag>

# Or revert code and rebuild
git checkout <old-commit>
sudo nerdctl compose down
sudo nerdctl compose up -d
```

---

## Best Practices

1. ✅ **Always test locally first**
   ```bash
   docker build -f Dockerfile.buildkit -t test-local .
   docker run --rm -p 4000:4000 test-local
   curl http://localhost:4000/health
   ```

2. ✅ **Use image tags for production**
   ```bash
   # Tag with version
   docker tag ghcr.io/.../elixir:latest ghcr.io/.../elixir:v1.2.3
   docker push ghcr.io/.../elixir:v1.2.3
   ```

3. ✅ **Monitor logs during deployment**
   ```bash
   sudo nerdctl compose logs -f elixir
   ```

4. ✅ **Check health endpoint after deploy**
   ```bash
   watch -n 2 'curl -s https://push-server.f3liz.casa/health | jq .'
   ```
