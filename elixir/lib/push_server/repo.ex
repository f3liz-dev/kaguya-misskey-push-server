defmodule PushServer.Repo do
  @moduledoc """
  All SQLite access lives here. Pure data layer — no OTP, no business logic.

  Every function either returns data or {:ok} / {:error, reason}.
  Nothing else. Callers decide what to do with results.

  SQLite runs in WAL mode so Node.js fallback can write concurrently.
  """
  use GenServer

  @db_path System.get_env("DB_PATH", "/data/push_server.db")

  # --- Public API ---

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  # Read timeout — fast, fail quickly under contention
  @read_timeout 2_000
  # Write timeout — slightly longer for INSERT/UPDATE
  @write_timeout 3_000

  def get_user(user_id),
    do: GenServer.call(__MODULE__, {:get_user, user_id}, @read_timeout)

  def get_user_by_webhook_id(webhook_user_id),
    do: GenServer.call(__MODULE__, {:get_user_by_webhook_id, webhook_user_id}, @read_timeout)

  def get_active_users(),
    do: GenServer.call(__MODULE__, :get_active_users, @read_timeout)

  def insert_user(user),
    do: GenServer.call(__MODULE__, {:insert_user, user}, @write_timeout)

  def delete_user(user_id),
    do: GenServer.call(__MODULE__, {:delete_user, user_id}, @write_timeout)

  def deactivate_user(user_id),
    do: GenServer.call(__MODULE__, {:deactivate_user, user_id}, @write_timeout)

  def update_supporter(user_id, supporter),
    do: GenServer.call(__MODULE__, {:update_supporter, user_id, supporter}, @write_timeout)

  def update_delay(user_id, delay_minutes),
    do: GenServer.call(__MODULE__, {:update_delay, user_id, delay_minutes}, @write_timeout)

  def update_preference(user_id, preference),
    do: GenServer.call(__MODULE__, {:update_preference, user_id, preference}, @write_timeout)

  def update_last_webhook_at(user_id),
    do: GenServer.call(__MODULE__, {:update_last_webhook_at, user_id}, @write_timeout)

  def insert_pending(user_id, payload, deliver_at),
    do: GenServer.call(__MODULE__, {:insert_pending, user_id, payload, deliver_at}, @write_timeout)

  def get_due_notifications(),
    do: GenServer.call(__MODULE__, :get_due_notifications, @read_timeout)

  def delete_pending(ids),
    do: GenServer.call(__MODULE__, {:delete_pending, ids}, @write_timeout)

  def increment_retry(ids),
    do: GenServer.call(__MODULE__, {:increment_retry, ids}, @write_timeout)

  def delete_stale_pending(max_retries: max),
    do: GenServer.call(__MODULE__, {:delete_stale_pending, max}, @write_timeout)

  def count_stale_pending(),
    do: GenServer.call(__MODULE__, :count_stale_pending, @read_timeout)

  def count_active_users(),
    do: GenServer.call(__MODULE__, :count_active_users, @read_timeout)

  def update_heartbeat(),
    do: GenServer.call(__MODULE__, :update_heartbeat, @write_timeout)

  def get_heartbeat(),
    do: GenServer.call(__MODULE__, :get_heartbeat)

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    db_path = @db_path
    File.mkdir_p!(Path.dirname(db_path))
    {:ok, db} = Exqlite.Basic.open(db_path)
    setup_schema(db)
    {:ok, db}
  end

  @impl true
  def handle_call({:get_user, user_id}, _from, db) do
    result =
      query_one(db, "SELECT * FROM users WHERE id = ?", [user_id])
    {:reply, result, db}
  end

  def handle_call({:get_user_by_webhook_id, webhook_user_id}, _from, db) do
    result =
      query_one(db, "SELECT * FROM users WHERE webhook_user_id = ?", [webhook_user_id])
    {:reply, result, db}
  end

  def handle_call(:get_active_users, _from, db) do
    result = query_many(db, "SELECT * FROM users WHERE active = 1", [])
    {:reply, result, db}
  end

  def handle_call({:insert_user, user}, _from, db) do
    result = Exqlite.Basic.exec(db, """
      INSERT INTO users
        (id, misskey_origin, webhook_user_id, webhook_secret,
         push_subscription, notification_preference, delay_minutes,
         supporter, active)
      VALUES (?, ?, ?, ?, ?, ?, ?, 0, 1)
      ON CONFLICT(id) DO UPDATE SET
        webhook_secret = excluded.webhook_secret,
        push_subscription = excluded.push_subscription,
        notification_preference = excluded.notification_preference,
        delay_minutes = excluded.delay_minutes,
        active = 1
    """, [
      user.id,
      user.misskey_origin,
      user.webhook_user_id,
      user.webhook_secret,
      Jason.encode!(user.push_subscription),
      user.notification_preference || "quiet",
      user.delay_minutes || 1
    ])
    {:reply, result, db}
  end

  def handle_call({:delete_user, user_id}, _from, db) do
    Exqlite.Basic.exec(db,
      "DELETE FROM pending_notifications WHERE user_id = ?", [user_id])
    result = Exqlite.Basic.exec(db,
      "DELETE FROM users WHERE id = ?", [user_id])
    {:reply, result, db}
  end

  def handle_call({:deactivate_user, user_id}, _from, db) do
    result = Exqlite.Basic.exec(db,
      "UPDATE users SET active = 0 WHERE id = ?", [user_id])
    {:reply, result, db}
  end

  def handle_call({:update_supporter, user_id, supporter}, _from, db) do
    result = Exqlite.Basic.exec(db,
      "UPDATE users SET supporter = ? WHERE id = ?",
      [if(supporter, do: 1, else: 0), user_id])
    {:reply, result, db}
  end

  def handle_call({:update_delay, user_id, delay_minutes}, _from, db) do
    result = Exqlite.Basic.exec(db,
      "UPDATE users SET delay_minutes = ? WHERE id = ?",
      [delay_minutes, user_id])
    {:reply, result, db}
  end

  def handle_call({:update_preference, user_id, preference}, _from, db) do
    result = Exqlite.Basic.exec(db,
      "UPDATE users SET notification_preference = ? WHERE id = ?",
      [preference, user_id])
    {:reply, result, db}
  end

  def handle_call({:update_last_webhook_at, user_id}, _from, db) do
    result = Exqlite.Basic.exec(db,
      "UPDATE users SET last_webhook_at = ? WHERE id = ?",
      [DateTime.utc_now() |> DateTime.to_iso8601(), user_id])
    {:reply, result, db}
  end

  def handle_call({:insert_pending, user_id, payload, deliver_at}, _from, db) do
    result = Exqlite.Basic.exec(db, """
      INSERT INTO pending_notifications
        (user_id, payload, deliver_at, created_at, retry_count)
      VALUES (?, ?, ?, ?, 0)
    """, [
      user_id,
      Jason.encode!(payload),
      DateTime.to_iso8601(deliver_at),
      DateTime.utc_now() |> DateTime.to_iso8601()
    ])
    {:reply, result, db}
  end

  def handle_call(:get_due_notifications, _from, db) do
    now = DateTime.utc_now() |> DateTime.to_iso8601()
    result = query_many(db, """
      SELECT pn.*, u.push_subscription, u.supporter
      FROM pending_notifications pn
      JOIN users u ON pn.user_id = u.id
      WHERE pn.deliver_at <= ?
      AND u.active = 1
      ORDER BY pn.deliver_at ASC
    """, [now])
    {:reply, result, db}
  end

  def handle_call({:delete_pending, ids}, _from, db) do
    placeholders = Enum.map_join(ids, ", ", fn _ -> "?" end)
    result = Exqlite.Basic.exec(db,
      "DELETE FROM pending_notifications WHERE id IN (#{placeholders})",
      ids)
    {:reply, result, db}
  end

  def handle_call({:increment_retry, ids}, _from, db) do
    placeholders = Enum.map_join(ids, ", ", fn _ -> "?" end)
    result = Exqlite.Basic.exec(db, """
      UPDATE pending_notifications
      SET retry_count = retry_count + 1,
          last_attempted_at = ?
      WHERE id IN (#{placeholders})
    """, [DateTime.utc_now() |> DateTime.to_iso8601() | ids])
    {:reply, result, db}
  end

  def handle_call({:delete_stale_pending, max_retries}, _from, db) do
    result = Exqlite.Basic.exec(db,
      "DELETE FROM pending_notifications WHERE retry_count >= ?",
      [max_retries])
    {:reply, result, db}
  end

  def handle_call(:count_stale_pending, _from, db) do
    one_hour_ago =
      DateTime.utc_now()
      |> DateTime.add(-3600, :second)
      |> DateTime.to_iso8601()
    result = query_one(db,
      "SELECT COUNT(*) as count FROM pending_notifications WHERE created_at < ?",
      [one_hour_ago])
    count = case result do
      {:ok, %{"count" => n}} -> n
      _ -> 0
    end
    {:reply, count, db}
  end

  def handle_call(:count_active_users, _from, db) do
    result = query_one(db,
      "SELECT COUNT(*) as count FROM users WHERE active = 1", [])
    count = case result do
      {:ok, %{"count" => n}} -> n
      _ -> 0
    end
    {:reply, count, db}
  end

  def handle_call(:update_heartbeat, _from, db) do
    result = Exqlite.Basic.exec(db, """
      INSERT INTO heartbeats (name, last_at)
      VALUES ('delivery_worker', ?)
      ON CONFLICT(name) DO UPDATE SET last_at = excluded.last_at
    """, [DateTime.utc_now() |> DateTime.to_iso8601()])
    {:reply, result, db}
  end

  def handle_call(:get_heartbeat, _from, db) do
    result = query_one(db,
      "SELECT last_at FROM heartbeats WHERE name = 'delivery_worker'", [])
    {:reply, result, db}
  end

  # --- Schema setup ---

  defp setup_schema(db) do
    # WAL mode: allows Node.js fallback to write concurrently
    Exqlite.Basic.exec(db, "PRAGMA journal_mode=WAL", [])
    Exqlite.Basic.exec(db, "PRAGMA foreign_keys=ON", [])

    Exqlite.Basic.exec(db, """
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
    """, [])

    Exqlite.Basic.exec(db, """
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
    """, [])

    Exqlite.Basic.exec(db, """
      CREATE INDEX IF NOT EXISTS idx_pending_deliver_at
      ON pending_notifications(deliver_at)
    """, [])

    Exqlite.Basic.exec(db, """
      CREATE TABLE IF NOT EXISTS heartbeats (
        name TEXT PRIMARY KEY,
        last_at TEXT NOT NULL
      )
    """, [])
  end

  # --- Query helpers ---

  # Rows to maps: columns zipped with values → plain map
  # This avoids the obj[2].rows[0][indexOf("col")] pain
  defp rows_to_maps(%{rows: rows, columns: columns}) do
    Enum.map(rows, fn row ->
      columns
      |> Enum.zip(row)
      |> Map.new()
    end)
  end

  defp query_one(db, sql, params) do
    case Exqlite.Basic.exec(db, sql, params) do
      {:ok, result} ->
        case rows_to_maps(result) do
          []    -> {:ok, nil}
          [row] -> {:ok, row}
          _     -> {:ok, nil}
        end
      {:error, reason} ->
        {:error, reason}
    end
  end

  defp query_many(db, sql, params) do
    case Exqlite.Basic.exec(db, sql, params) do
      {:ok, result} -> {:ok, rows_to_maps(result)}
      {:error, reason} -> {:error, reason}
    end
  end
end
