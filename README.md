# kaguya-misskey-push-server

Push notification proxy for [kaguya](https://github.com/f3liz-dev/kaguya), a Misskey client.

Misskey's `sw/register` endpoint is `secure: true`, blocking third-party apps from registering push subscriptions. This server receives Misskey webhooks and delivers Web Push notifications to the browser.

## Architecture

```
Browser (kaguya)
  ├── creates webhook on Misskey (token stays in browser)
  ├── subscribes to push via PushManager (this server's VAPID key)
  └── registers with this server (webhook_secret + push_subscription, NO token)

Misskey instance
  └── sends webhook to this server

This server
  ├── Elixir primary: receives webhooks, groups, delays, delivers
  └── Node.js fallback: immediate delivery when Elixir is down
```

**Privacy:** No access token is ever sent to or stored by this server.

## Deployment

### GCE e2-micro (recommended)

1. Generate VAPID keys: `npx web-push generate-vapid-keys`
2. Create `.env` from `.env.example` and fill in VAPID keys
3. Store in GCP Secret Manager: `gcloud secrets create push-server-env --data-file=.env`
4. Create instance with `startup-script.sh` (see comments in file for full command)

### Docker Compose (dev/alternative)

```bash
cp .env.example .env
# Fill in VAPID keys
docker compose up -d
```

## Endpoints

| Method | Path | Auth | Description |
|--------|------|------|-------------|
| POST | `/webhook/:user_id` | X-Misskey-Hook-Secret | Receive Misskey webhook |
| POST | `/register` | None | Register user + push subscription |
| DELETE | `/unregister` | None | Remove user |
| PATCH | `/settings` | None | Update delay/preference |
| GET | `/health` | None | Health check |

## Operations

```bash
# Logs
cd /app/src && docker compose logs -f

# Deploy update
/app/deploy.sh

# Migrate to new server
/app/migrate.sh <new-ip>
```

## License

MPL-2.0
