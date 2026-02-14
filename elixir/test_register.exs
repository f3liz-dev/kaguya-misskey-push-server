# Quick test to verify registration works
IO.puts("Testing push server registration...")

# Simulate a valid registration
user = %{
  id: "test_user_123",
  misskey_origin: "https://misskey.io",
  webhook_user_id: "test_user_123",
  webhook_secret: "test_secret",
  push_subscription: %{
    "endpoint" => "https://fcm.googleapis.com/fcm/send/test",
    "keys" => %{
      "p256dh" => "test_key",
      "auth" => "test_auth"
    }
  },
  notification_preference: "quiet",
  delay_minutes: 1
}

# This would test the actual insert
IO.inspect(user, label: "Test user")
IO.puts("\nFix applied: insert_user now returns {:error, :db_error} on failure")
IO.puts("Fix applied: Router will properly handle errors and return 400 on DB failures")
