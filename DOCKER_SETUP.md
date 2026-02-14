# GitHub Packages Docker Build Setup

## Summary of Changes

This setup enables automatic building and pushing of Docker images to GitHub Container Registry (ghcr.io) on every commit to the main branch.

## Files Created/Modified

### Created:
1. `.github/workflows/docker-build.yml` - GitHub Actions workflow for building and testing images
2. `docker-compose.override.yml.example` - Example override for local development
3. `.gitignore` - Added `docker-compose.override.yml` to ignore list

### Modified:
1. `elixir/Dockerfile` - Added HEALTHCHECK instruction
2. `docker-compose.yml` - Changed to use pre-built images from ghcr.io, removed duplicate healthcheck configs
3. `README.md` - Updated deployment documentation

## Key Features

### GitHub Actions Workflow
- **Builds on**: Push to main/master, PRs, and version tags
- **Multi-platform**: Builds for linux/amd64 and linux/arm64
- **Caching**: Uses GitHub Actions cache for faster builds
- **Testing**: Automatically tests built images by running containers and checking health endpoints
- **Parallel builds**: Node and Elixir images build simultaneously

### Docker Health Checks
Both Dockerfiles now have built-in HEALTHCHECK instructions:

**Node** (already had it):
```dockerfile
HEALTHCHECK --interval=30s --timeout=5s --start-period=5s \
  CMD node -e "require('http').get('http://localhost:3000/health',r=>{r.statusCode===200?process.exit(0):process.exit(1)}).on('error',()=>process.exit(1))"
```

**Elixir** (newly added):
```dockerfile
HEALTHCHECK --interval=15s --timeout=5s --start-period=30s --retries=3 \
  CMD curl -sf http://localhost:4000/health || exit 1
```

### Docker Compose Updates
- **Production**: Uses pre-built images from `ghcr.io/f3liz-dev/kaguya-misskey-push-server-{node,elixir}:latest`
- **Development**: Copy `docker-compose.override.yml.example` to enable local builds
- **Health checks**: Relies on Dockerfile HEALTHCHECK, removed redundant compose configs
- **Dependencies**: nginx now waits for both services to be healthy

## Usage

### For CI/CD (Automatic)
Simply push to main branch and GitHub Actions will:
1. Build both images
2. Push to ghcr.io
3. Test the images
4. Tag with branch name and "latest"

### For Production Deployment
```bash
docker compose pull  # Pull latest images
docker compose up -d
```

Images are publicly available at:
- `ghcr.io/f3liz-dev/kaguya-misskey-push-server-node:latest`
- `ghcr.io/f3liz-dev/kaguya-misskey-push-server-elixir:latest`

### For Local Development
```bash
cp docker-compose.override.yml.example docker-compose.override.yml
docker compose up --build
```

The override file tells compose to build locally instead of pulling from registry.

## Benefits

1. **No custom healthcheck logic** - Uses Docker's built-in HEALTHCHECK
2. **Faster deployments** - Pull pre-built images instead of building on the server
3. **Multi-arch support** - Images work on both x86_64 and ARM64
4. **Automatic testing** - Every build is tested before being available
5. **Version tracking** - Tagged with commit SHA, branch, and semantic versions
6. **Layer caching** - GitHub Actions cache speeds up builds

## Testing Locally

Once Docker daemon is running, you can test builds:

```bash
# Build Node image
cd node && docker build -t test-node .

# Build Elixir image  
cd elixir && docker build -t test-elixir .

# Test healthchecks
docker run -d --name test-node -e DB_PATH=/data/push_server.db -e FALLBACK_PORT=3000 test-node
docker ps  # Check health status
docker stop test-node && docker rm test-node
```

## Next Steps

1. Push changes to GitHub
2. Check GitHub Actions workflow execution
3. Once successful, images will be available at ghcr.io
4. Update production to pull from registry instead of building locally
