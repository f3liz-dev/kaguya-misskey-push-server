defmodule PushServer.Repo do
  @moduledoc """
  Persistent storage for User registrations only.
  """
  use GenServer
  require Logger

  @db_path System.get_env("DB_PATH", "/data/push_server.db")

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def get_user(user_id), do: GenServer.call(__MODULE__, {:get_user, user_id})
  def insert_user(user), do: GenServer.call(__MODULE__, {:insert_user, user})
  def delete_user(user_id), do: GenServer.call(__MODULE__, {:delete_user, user_id})
  def deactivate_user(user_id), do: GenServer.call(__MODULE__, {:deactivate_user, user_id})
  def update_delay(user_id, delay), do: GenServer.call(__MODULE__, {:update_delay, user_id, delay})
  def update_preference(user_id, pref), do: GenServer.call(__MODULE__, {:update_preference, user_id, pref})
  def update_buffer_seconds(user_id, seconds), do: GenServer.call(__MODULE__, {:update_buffer_seconds, user_id, seconds})
  def count_active_users(), do: GenServer.call(__MODULE__, :count_active_users)

  @impl true
  def init(_) do
    db_path = @db_path
    File.mkdir_p!(Path.dirname(db_path))
    Logger.info("Repo: Opening database at #{db_path}")
    {:ok, db} = Exqlite.Basic.open(db_path)
    
    Exqlite.Basic.exec(db, """
      CREATE TABLE IF NOT EXISTS users (
        id TEXT PRIMARY KEY,
        misskey_origin TEXT NOT NULL,
        webhook_user_id TEXT NOT NULL,
        webhook_secret TEXT NOT NULL,
        push_subscription TEXT NOT NULL,
        notification_preference TEXT NOT NULL DEFAULT 'quiet',
        delay_minutes INTEGER NOT NULL DEFAULT 1,
        buffer_seconds INTEGER NOT NULL DEFAULT 60,
        supporter INTEGER NOT NULL DEFAULT 0,
        active INTEGER NOT NULL DEFAULT 1
      )
    """, [])
    
    # Add buffer_seconds column if it doesn't exist (migration for existing DBs)
    Exqlite.Basic.exec(db, """
      ALTER TABLE users ADD COLUMN buffer_seconds INTEGER NOT NULL DEFAULT 60
    """, [])

    {:ok, db}
  end

  @impl true
  def handle_call({:get_user, id}, _from, db) do
    case Exqlite.Basic.exec(db, "SELECT * FROM users WHERE id = ?", [id]) do
      {:ok, _, %{rows: [row], columns: cols}, _} -> {:reply, {:ok, Enum.zip(cols, row) |> Map.new()}, db}
      {:ok, %{rows: [row], columns: cols}} -> {:reply, {:ok, Enum.zip(cols, row) |> Map.new()}, db}
      _ -> {:reply, {:ok, nil}, db}
    end
  end

  def handle_call({:insert_user, user}, _from, db) do
    Logger.info("Repo: Attempting to insert/update user #{user.id}")
    buffer_seconds = Map.get(user, :buffer_seconds, 60)
    res = Exqlite.Basic.exec(db, """
      INSERT INTO users (id, misskey_origin, webhook_user_id, webhook_secret, push_subscription, notification_preference, delay_minutes, buffer_seconds, active)
      VALUES (?, ?, ?, ?, ?, ?, ?, ?, 1)
      ON CONFLICT(id) DO UPDATE SET
        webhook_secret = excluded.webhook_secret,
        push_subscription = excluded.push_subscription,
        notification_preference = excluded.notification_preference,
        delay_minutes = excluded.delay_minutes,
        buffer_seconds = excluded.buffer_seconds,
        active = 1
    """, [user.id, user.misskey_origin, user.webhook_user_id, user.webhook_secret, Jason.encode!(user.push_subscription), user.notification_preference, user.delay_minutes, buffer_seconds])
    
    case res do
      {:ok, _, _, _} -> 
        Logger.info("Repo: Successfully saved user #{user.id}")
        {:reply, :ok, db}
      {:ok, _, _} ->
        Logger.info("Repo: Successfully saved user #{user.id}")
        {:reply, :ok, db}
      {:ok, _} ->
        Logger.info("Repo: Successfully saved user #{user.id}")
        {:reply, :ok, db}
      {:error, reason} -> 
        Logger.error("Repo: Failed to save user #{user.id}: #{inspect(reason)}")
        {:reply, {:error, :db_error}, db}
      err -> 
        Logger.error("Repo: Failed to save user #{user.id} (unexpected): #{inspect(err)}")
        {:reply, {:error, :db_error}, db}
    end
  end

  def handle_call({:delete_user, id}, _from, db) do
    Exqlite.Basic.exec(db, "DELETE FROM users WHERE id = ?", [id])
    {:reply, :ok, db}
  end

  def handle_call({:deactivate_user, id}, _from, db) do
    Exqlite.Basic.exec(db, "UPDATE users SET active = 0 WHERE id = ?", [id])
    {:reply, :ok, db}
  end

  def handle_call({:update_delay, id, delay}, _from, db) do
    Exqlite.Basic.exec(db, "UPDATE users SET delay_minutes = ? WHERE id = ?", [delay, id])
    {:reply, :ok, db}
  end

  def handle_call({:update_preference, id, pref}, _from, db) do
    Exqlite.Basic.exec(db, "UPDATE users SET notification_preference = ? WHERE id = ?", [pref, id])
    {:reply, :ok, db}
  end

  def handle_call({:update_buffer_seconds, id, seconds}, _from, db) do
    # Clamp between 0 and 600 seconds (10 minutes)
    clamped = max(0, min(seconds, 600))
    Exqlite.Basic.exec(db, "UPDATE users SET buffer_seconds = ? WHERE id = ?", [clamped, id])
    {:reply, :ok, db}
  end

  def handle_call(:count_active_users, _from, db) do
    case Exqlite.Basic.exec(db, "SELECT COUNT(*) FROM users WHERE active = 1", []) do
      {:ok, _, %{rows: [[n]]}, _} ->
        count = if is_binary(n), do: String.to_integer(n), else: n
        {:reply, count, db}
      {:ok, %{rows: [[n]]}} -> 
        count = if is_binary(n), do: String.to_integer(n), else: n
        {:reply, count, db}
      result ->
        Logger.warning("Unexpected count result: #{inspect(result)}")
        {:reply, 0, db}
    end
  end
end
