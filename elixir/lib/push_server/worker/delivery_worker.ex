defmodule PushServer.Worker.DeliveryWorker do
  @moduledoc """
  The only GenServer in the system. One job: deliver pending notifications.

  State: nil — this process is stateless. All state lives in SQLite.
  If this process crashes and restarts, it just resumes from SQLite.
  Nothing is lost.

  Every @poll_interval_ms it:
    1. Writes a heartbeat (so /health can detect if we're dead)
    2. Queries pending_notifications WHERE deliver_at <= now
    3. Groups rows by user_id
    4. Summarizes each user's pending payloads into one calm notification
    5. Sends via WebPush
    6. Deletes delivered rows
    7. Handles failures (retry_count, deactivate on 410)
  """
  use GenServer

  require Logger

  # Check every 10 seconds — worst case a notification is 10s late
  # beyond the user's configured delay. Acceptable.
  @poll_interval_ms 10_000
  @max_retries 5

  # --- Public API ---

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  # --- GenServer callbacks ---

  @impl true
  def init(_) do
    # Schedule first poll immediately
    schedule_poll(0)
    {:ok, nil}
  end

  @impl true
  # State is nil — we never use it.
  # All state is in SQLite. This is intentional.
  def handle_info(:poll, nil) do
    # Heartbeat first — if everything below crashes, at least
    # the heartbeat written before shows we were alive
    PushServer.Repo.update_heartbeat()

    # Check memory pressure before processing
    # This is the soft cap — if RAM is high, we slow down
    case memory_pressure() do
      :ok ->
        process_due_notifications()
      :high ->
        Logger.warning("memory pressure high, slowing delivery poll")
        # Still heartbeat, just don't process this tick
        :ok
    end

    # Clean up rows that have failed too many times
    PushServer.Repo.delete_stale_pending(max_retries: @max_retries)

    schedule_poll(@poll_interval_ms)
    {:noreply, nil}
  end

  # --- Private ---

  defp process_due_notifications do
    case PushServer.Repo.get_due_notifications() do
      {:ok, []} ->
        :ok

      {:ok, rows} ->
        rows
        |> Enum.group_by(& &1["user_id"])
        |> Enum.each(&deliver_to_user/1)

      {:error, reason} ->
        Logger.error("failed to query pending notifications", reason: inspect(reason))
    end
  end

  defp deliver_to_user({user_id, rows}) do
    # Get user for push subscription
    # (already joined in query, but we need the full record)
    case PushServer.Repo.get_user(user_id) do
      {:ok, nil} ->
        # User was deleted — clean up their pending rows
        ids = Enum.map(rows, & &1["id"])
        PushServer.Repo.delete_pending(ids)

      {:ok, user} ->
        push_subscription = Jason.decode!(user["push_subscription"])

        # Decode and summarize payloads
        payloads = Enum.map(rows, fn row ->
          Jason.decode!(row["payload"])
        end)

        summary = PushServer.Payload.summarize(payloads)
        ids = Enum.map(rows, & &1["id"])

        case PushServer.WebPush.send(push_subscription, summary) do
          :ok ->
            PushServer.Repo.delete_pending(ids)
            Logger.debug("delivered #{length(payloads)} notifications",
              user_id: user_id)

          {:error, :gone} ->
            # Push subscription expired — deactivate user
            # They need to re-register their push subscription
            Logger.info("push subscription expired, deactivating user",
              user_id: user_id)
            PushServer.Repo.deactivate_user(user_id)
            PushServer.Repo.delete_pending(ids)

          {:error, reason} ->
            # Temporary failure — increment retry, try again next poll
            Logger.warning("push delivery failed, will retry",
              user_id: user_id,
              reason: inspect(reason),
              retry_count: rows |> hd() |> Map.get("retry_count", 0)
            )
            PushServer.Repo.increment_retry(ids)
        end

      {:error, reason} ->
        Logger.error("failed to get user for delivery",
          user_id: user_id,
          reason: inspect(reason))
    end
  end

  # Memory pressure check using :os_mon
  # :os_mon is included in extra_applications in mix.exs
  defp memory_pressure do
    case :memsup.get_memory_data() do
      {total, allocated, _worst} when total > 0 ->
        ratio = allocated / total
        if ratio > 0.85, do: :high, else: :ok
      _ ->
        :ok  # can't read memory data — assume ok
    end
  end

  defp schedule_poll(delay) do
    Process.send_after(self(), :poll, delay)
  end
end
