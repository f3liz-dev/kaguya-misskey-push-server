# Push Delivery Failure Diagnosis

## Problem

```
[info] Registration successful for user: 9mg89cu7wp
[error] encryption or dispatch failed
[warning] delivery failed
```

## Most Likely Causes

### 1. **Invalid Push Subscription (90% likely)**

The frontend registration may be sending test data instead of a real browser subscription.

**How to check:**
```bash
# On GCE:
sudo nerdctl exec $(sudo nerdctl ps -q -f name=elixir) sh -c \
  "sqlite3 /data/push_server.db \"SELECT push_subscription FROM users WHERE id = '9mg89cu7wp';\""
```

**Valid subscription must have:**
```json
{
  "endpoint": "https://fcm.googleapis.com/fcm/send/...",
  "keys": {
    "p256dh": "BG3xO...(base64, ~87 chars)",
    "auth": "rK3V...(base64, ~24 chars)"
  }
}
```

**Invalid examples:**
- `{"endpoint": "https://fcm.googleapis.com/test", "keys": {"p256dh": "key", "auth": "auth"}}` ❌ (test data)
- `{"endpoint": "...", "p256dh": "...", "auth": "..."}` ❌ (wrong structure)
- `null` or empty ❌

### 2. **Missing VAPID Keys (5% likely)**

If VAPID keys aren't configured, encryption will fail.

**How to check:**
```bash
sudo nerdctl exec $(sudo nerdctl ps -q -f name=elixir) env | grep VAPID
```

Should show:
```
VAPID_PUBLIC_KEY=BNR...
VAPID_PRIVATE_KEY=oaM...
VAPID_SUBJECT=mailto:...
```

### 3. **Malformed Keys in Subscription (5% likely)**

The p256dh/auth keys must be valid base64-encoded strings.

---

## Debugging Steps

### Step 1: Deploy Latest Code (with detailed error logging)

```bash
cd /app/src
sudo docker compose pull
sudo docker compose down
sudo docker compose up -d
```

### Step 2: Check User Subscription

```bash
# Run the debug script
cd /Users/nyanrus/repos/rescript/kaguya-misskey-push-server
bash debug-push.sh
```

Or manually:
```bash
sudo nerdctl exec $(sudo nerdctl ps -q -f name=elixir) sh -c \
  "sqlite3 /data/push_server.db \"SELECT id, push_subscription FROM users;\""
```

### Step 3: Check Detailed Error

After restart, the logs will show:
```
[error] encryption or dispatch failed
  error: "ArgumentError: invalid base64 encoding"  <-- or similar
  stacktrace: ...
  endpoint: https://...
```

### Step 4: Test with Valid Subscription

Get a real browser subscription from the frontend:

**In browser console (on your Kaguya app):**
```javascript
// Request permission
Notification.requestPermission().then(permission => {
  if (permission === 'granted') {
    // Get service worker registration
    navigator.serviceWorker.ready.then(reg => {
      // Subscribe with your VAPID public key
      reg.pushManager.subscribe({
        userVisibleOnly: true,
        applicationServerKey: 'YOUR_VAPID_PUBLIC_KEY'  // Get from backend
      }).then(sub => {
        console.log('Subscription:', JSON.stringify(sub));
      });
    });
  }
});
```

Then register with the **real** subscription.

---

## Common Issues

### Issue: "Invalid base64 encoding"

**Cause:** Frontend sent `"key"` instead of actual base64 key  
**Fix:** Use real browser push subscription

### Issue: "ArgumentError in argument errors: [:asn_error]"

**Cause:** VAPID keys are invalid or missing  
**Fix:** Generate new VAPID keys with `mix vapid.gen.keys` (or web-push library)

### Issue: "endpoint not found"

**Cause:** Subscription structure is wrong (keys not nested properly)  
**Fix:** Ensure structure is `{"endpoint": "...", "keys": {"p256dh": "...", "auth": "..."}}`

### Issue: "410 Gone"

**Cause:** Subscription expired/invalid on FCM side  
**Fix:** User needs to re-register from browser

---

## Frontend Check

**File:** `kaguya/packages/kaguya-app/src/pages/PushManualRegistrationPage.res`

The frontend is currently sending registration data. Check if it's:
- ✅ Getting real browser subscription via `navigator.serviceWorker.pushManager.subscribe()`
- ❌ Using test/mock data

If using test data, that's the problem. The frontend needs to:

1. Request notification permission
2. Get service worker registration
3. Subscribe to push with VAPID public key
4. Send the **real** subscription object to `/register`

---

## Quick Test

To quickly test if encryption works with a valid subscription:

```bash
# Inside container
sudo nerdctl exec -it $(sudo nerdctl ps -q -f name=elixir) sh

# Open IEx (Elixir console)
cd /app && /app/bin/push_server remote

# Test encryption
test_sub = %{
  "endpoint" => "https://fcm.googleapis.com/fcm/send/test",
  "keys" => %{
    "p256dh" => "BG3xOI6T-KyPeq3bZW0mGF2L8qLcD9f8J_V3TzxFyBjwEd7fKHkDx5l-Qr8u6h2sP1m0vN9wY4jR3tL5kX8cZg",
    "auth" => "rK3V_j2k9H3sL8pQ1mN0wX"
  }
}
payload = %{title: "Test", body: "Test notification"}
PushServer.WebPush.send(test_sub, payload)
# Should return {:error, _} if subscription is fake
# Should return :ok if subscription structure is valid
```

---

## Next Steps

1. **Run debug script** to see actual error
2. **Check if frontend** is using real vs test subscription
3. **Fix frontend** to get real browser push subscription if needed
4. **Test again** with valid subscription

