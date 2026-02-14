# Build and Deploy Instructions

## What was fixed

The `PushServer.Repo.insert_user/1` function was always returning `:ok` even when database inserts failed. This caused the API to return success (200 OK) even when no user was saved.

**Changes made:**
- `lib/push_server/repo.ex`: Modified `handle_call({:insert_user, ...})` to return `{:error, :db_error}` on database failures
- This allows the router to properly handle errors and return 400 status code to the client

## Build new Docker image

```bash
cd kaguya-misskey-push-server/elixir

# Build the image
docker build -t ghcr.io/f3liz-dev/kaguya-misskey-push-server-elixir:latest .

# Or if you use nerdctl
nerdctl build -t ghcr.io/f3liz-dev/kaguya-misskey-push-server-elixir:latest .
```

## Push to GitHub Container Registry

```bash
# Login to GHCR
echo $GITHUB_TOKEN | docker login ghcr.io -u USERNAME --password-stdin

# Push the image
docker push ghcr.io/f3liz-dev/kaguya-misskey-push-server-elixir:latest
```

## Deploy on GCE

SSH into your GCE instance and run:

```bash
cd /app/src
sudo nerdctl compose pull
sudo nerdctl compose up -d --force-recreate elixir
```

Or use the deploy script:

```bash
/app/deploy.sh
```

## Verify the fix

After deployment, test the registration:

1. Register via the frontend
2. Check if you get an error message if it fails
3. Verify active users count:
   ```bash
   curl https://push-server.f3liz.casa/health | jq .
   ```

The `active_users` count should now correctly reflect registered users, or you should see a proper error message if registration fails.
