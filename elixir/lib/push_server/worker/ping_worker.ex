defmodule PushServer.Worker.PingWorker do
  @moduledoc """
  Sends a daily "ping" notification to all active users.
  If the push service returns 410 Gone, the registration is deactivated.
  """
  use GenServer
  require Logger

  # Run once every 24 hours
  @interval_ms 24 * 60 * 60 * 1000

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    # Schedule first run (e.g., after 5 minutes to not overwhelm startup)
    Process.send_after(self(), :run_ping, 5 * 60 * 1000)
    {:ok, nil}
  end

  @impl true
  def handle_info(:run_ping, state) do
    Logger.info("PingWorker: Starting daily validity check...")
    perform_pings()
    
    # Schedule next run
    Process.send_after(self(), :run_ping, @interval_ms)
    {:noreply, state}
  end

  defp perform_pings do
    users = fetch_active_users()
    Logger.info("PingWorker: Pinging #{length(users)} active users")

    users
    |> Enum.each(fn user ->
      # Small delay between pings to avoid rate limits
      Process.sleep(100)
      ping_user(user)
    end)
  end

  defp ping_user(user) do
    user_id = user["id"]
    payload = PushServer.Payload.ping(user_id)
    subscription = Jason.decode!(user["push_subscription"])

    case PushServer.WebPush.send(subscription, payload) do
      :ok ->
        :ok
      {:error, :gone} ->
        Logger.info("PingWorker: Subscription expired for user #{user_id}, deactivating")
        PushServer.Repo.deactivate_user(user_id)
      {:error, reason} ->
        Logger.debug("PingWorker: Ping failed for user #{user_id}: #{inspect(reason)}")
        :ok
    end
  rescue
    e ->
      Logger.error("PingWorker: Error pinging user #{user["id"]}: #{Exception.message(e)}")
  end

  defp fetch_active_users do
    # We need a new Repo function or use a raw query if Repo is a GenServer
    # For now, let's assume we can get them from Repo
    case PushServer.Repo.get_all_active() do
      {:ok, users} -> users
      _ -> []
    end
  end
end
