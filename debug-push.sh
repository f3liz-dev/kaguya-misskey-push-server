#!/bin/bash
# Debug script for push delivery failures

echo "=== Push Notification Delivery Debug ==="
echo ""

# 1. Check if container is running the latest version
echo "1. Checking container version..."
sudo nerdctl compose logs elixir | tail -1
echo ""

# 2. Check database for user subscription
echo "2. Checking user subscription data..."
USER_ID="9mg89cu7wp"
sudo nerdctl exec $(sudo nerdctl ps -q -f name=elixir) sh -c \
  "sqlite3 /data/push_server.db \"SELECT id, push_subscription FROM users WHERE id = '$USER_ID';\"" | \
  while IFS='|' read -r id subscription; do
    echo "User ID: $id"
    echo "Subscription: $subscription"
    echo ""
    # Try to parse as JSON
    if echo "$subscription" | jq . 2>/dev/null; then
      echo "✅ Valid JSON"
      # Check required fields
      if echo "$subscription" | jq -e '.endpoint' >/dev/null 2>&1; then
        echo "✅ Has endpoint: $(echo "$subscription" | jq -r '.endpoint')"
      else
        echo "❌ Missing endpoint"
      fi
      if echo "$subscription" | jq -e '.keys.p256dh' >/dev/null 2>&1; then
        echo "✅ Has p256dh key"
      else
        echo "❌ Missing p256dh key"
      fi
      if echo "$subscription" | jq -e '.keys.auth' >/dev/null 2>&1; then
        echo "✅ Has auth key"
      else
        echo "❌ Missing auth key"
      fi
    else
      echo "❌ Invalid JSON"
    fi
  done
echo ""

# 3. Check for detailed error messages
echo "3. Recent error logs..."
sudo nerdctl compose logs elixir | grep -A 15 "encryption or dispatch failed" | tail -20
echo ""

# 4. Check VAPID configuration
echo "4. Checking VAPID configuration..."
sudo nerdctl exec $(sudo nerdctl ps -q -f name=elixir) sh -c 'echo "VAPID_PRIVATE_KEY length: ${#VAPID_PRIVATE_KEY}"'
sudo nerdctl exec $(sudo nerdctl ps -q -f name=elixir) sh -c 'echo "VAPID_PUBLIC_KEY length: ${#VAPID_PUBLIC_KEY}"'
echo ""

# 5. Check active users and buffered notifications
echo "5. Checking system status..."
curl -s http://push-server.f3liz.casa/health | jq .
echo ""

# 6. Test notification flow
echo "6. Testing notification delivery..."
echo "Send a test webhook with:"
echo 'curl -X POST http://push-server.f3liz.casa/webhook/9mg89cu7wp \'
echo '  -H "X-Misskey-Hook-Secret: YOUR_SECRET" \'
echo '  -H "Content-Type: application/json" \'
echo '  -d '"'"'{"type":"mention","body":{"id":"test","user":{"name":"Test"}}}'"'"
echo ""

echo "Then check logs:"
echo "sudo nerdctl compose logs elixir -f"
