/**
 * Node.js fallback server
 *
 * Minimal safety net — only handles webhook delivery when Elixir is down.
 * Nginx routes to this when Elixir returns 5xx or times out.
 *
 * What it does:
 *   - Verifies webhook secret
 *   - Inserts raw payload into SQLite (same DB as Elixir, WAL mode)
 *   - Sends push immediately (no grouping, no delay — safety net, not UX)
 *   - Returns 200 so Misskey stops retrying
 *
 * What it does NOT do:
 *   - Grouping or summarizing
 *   - Delay logic
 *   - Supporter tiers
 *   - Registration or settings
 *
 * Those live in Elixir. When Elixir recovers, it picks up from SQLite.
 */

import Fastify from 'fastify'
import Database from 'better-sqlite3'
import webpush from 'web-push'
import fs from 'fs'
import path from 'path'

const DB_PATH = process.env.DB_PATH ?? '/data/push_server.db'
const PORT    = parseInt(process.env.FALLBACK_PORT ?? '3000')

// Ensure directory exists
const dbDir = path.dirname(DB_PATH)
if (!fs.existsSync(dbDir)) {
  fs.mkdirSync(dbDir, { recursive: true })
}

// Open same SQLite file as Elixir
// WAL mode was set by Elixir on first boot — reads/writes coexist safely
// timeout: 5000ms helps avoid "database is locked" errors during contention
const db = new Database(DB_PATH, { timeout: 5000 })
db.pragma('journal_mode = WAL')
db.pragma('foreign_keys = ON')
db.pragma('busy_timeout = 5000')

// Ensure schema exists — Node may start before Elixir on first boot
try {
  db.exec(`
    CREATE TABLE IF NOT EXISTS users (
      id TEXT PRIMARY KEY,
      misskey_origin TEXT NOT NULL,
      webhook_user_id TEXT NOT NULL,
      webhook_secret TEXT NOT NULL,
      push_subscription TEXT NOT NULL,
      notification_preference TEXT NOT NULL DEFAULT 'quiet',
      delay_minutes INTEGER NOT NULL DEFAULT 1,
      supporter INTEGER NOT NULL DEFAULT 0,
      last_webhook_at TEXT,
      active INTEGER NOT NULL DEFAULT 1
    )
  `)
  db.exec(`
    CREATE TABLE IF NOT EXISTS pending_notifications (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      user_id TEXT NOT NULL,
      payload TEXT NOT NULL,
      deliver_at TEXT NOT NULL,
      created_at TEXT NOT NULL,
      retry_count INTEGER NOT NULL DEFAULT 0,
      last_attempted_at TEXT,
      FOREIGN KEY(user_id) REFERENCES users(id)
    )
  `)
  db.exec(`
    CREATE INDEX IF NOT EXISTS idx_pending_deliver_at
    ON pending_notifications(deliver_at)
  `)
  db.exec(`
    CREATE TABLE IF NOT EXISTS heartbeats (
      name TEXT PRIMARY KEY,
      last_at TEXT NOT NULL
    )
  `)
} catch (err) {
  console.error('[fallback] failed to initialize schema', err.message)
}

// VAPID — same keys as Elixir
webpush.setVapidDetails(
  process.env.VAPID_SUBJECT,
  process.env.VAPID_PUBLIC_KEY,
  process.env.VAPID_PRIVATE_KEY,
)

const app = Fastify({ logger: false })

// --- Webhook fallback endpoint ---

app.post('/webhook/:user_id', async (req, reply) => {
  const userId = req.params.user_id
  const secret = req.headers['x-misskey-hook-secret']

  let user
  try {
    user = db.prepare('SELECT * FROM users WHERE id = ? AND active = 1').get(userId)
  } catch (err) {
    console.error('[fallback] sqlite error during user lookup', { userId, error: err.message })
    return reply.code(200).send('ok')
  }

  // Always return 200 — even on errors.
  // Misskey retrying will not fix most failure modes,
  // and we don't want to trigger an infinite retry loop.

  if (!user) {
    req.log?.warn?.({ userId }, 'fallback: unknown user')
    return reply.code(200).send('ok')
  }

  if (secret !== user.webhook_secret) {
    req.log?.warn?.({ userId }, 'fallback: secret mismatch')
    return reply.code(200).send('ok')
  }

  const body = req.body
  if (!body?.type || !body?.body) {
    req.log?.warn?.({ userId, keys: Object.keys(body ?? {}) }, 'fallback: unexpected shape')
    return reply.code(200).send('ok')
  }

  try {
    // Build minimal payload — title only, no grouping
    const payload = buildPayload(body, user.notification_preference)

    // Send push immediately — no delay, no grouping
    // Do NOT insert into SQLite first — avoids race with Elixir's delivery worker
    // (Elixir polls pending_notifications and would double-deliver)
    const subscription = JSON.parse(user.push_subscription)
    await webpush.sendNotification(subscription, JSON.stringify(payload))

    console.log('[fallback] delivered notification', { userId, type: body.type })

  } catch (err) {
    if (err.statusCode === 410) {
      // Subscription expired
      db.prepare('UPDATE users SET active = 0 WHERE id = ?').run(userId)
      console.log('[fallback] deactivated user — subscription expired', { userId })
    } else {
      // Push failed — insert into SQLite so Elixir can retry when it recovers
      const now = new Date().toISOString()
      const payload = buildPayload(body, user.notification_preference)
      try {
        db.prepare(`
          INSERT INTO pending_notifications
            (user_id, payload, deliver_at, created_at, retry_count)
          VALUES (?, ?, ?, ?, 0)
        `).run(userId, JSON.stringify(payload), now, now)
        console.log('[fallback] push failed, saved for Elixir retry', {
          userId,
          error: err.message
        })
      } catch (dbErr) {
        console.error('[fallback] push failed AND db insert failed', {
          userId,
          pushError: err.message,
          dbError: dbErr.message
        })
      }
    }
  }

  return reply.code(200).send('ok')
})

// --- Health (minimal) ---

app.get('/health', async (_req, reply) => {
  const userCount = db.prepare('SELECT COUNT(*) as n FROM users WHERE active = 1').get()
  return reply.code(200).send({ ok: true, active_users: userCount.n, mode: 'fallback' })
})

// --- Start ---

app.listen({ port: PORT, host: '0.0.0.0' }, (err) => {
  if (err) { console.error(err); process.exit(1) }
  console.log(`[fallback] listening on ${PORT}`)
})

// --- Payload builder ---
// Minimal — no preference logic, always silent
// Elixir handles the nice parts when healthy

function buildPayload(params, _preference) {
  const type = params.type
  const body = params.body ?? {}
  const user = body.user ?? {}
  const note = body.note ?? {}

  const username = user.name || `@${user.username}` || 'Someone'
  const text     = (note.text ?? '').slice(0, 100)

  const titles = {
    mention:              `${username} mentioned you`,
    reply:                `${username} replied`,
    renote:               `${username} renoted your post`,
    quote:                `${username} quoted your post`,
    reaction:             `${username} reacted ${body.reaction ?? ''}`,
    follow:               `${username} followed you`,
    receiveFollowRequest: `${username} wants to follow you`,
    pollEnded:            'A poll you voted in ended',
  }

  return {
    title: titles[type] ?? 'New notification',
    body:  text,
    tag:   body.id ?? type,
    silent: true,
    data:  { type }
  }
}
