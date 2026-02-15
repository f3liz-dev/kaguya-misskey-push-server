defmodule PushServer.Worker.DeliveryWorker do
  @moduledoc """
  Polls the in-memory Buffer and dispatches via WebPush.
  """
  use GenServer
  require Logger

  @poll_interval_ms 10_000

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  @impl true
  def init(_) do
    schedule_poll(0)
    {:ok, nil}
  end

  @impl true
  def handle_info(:poll, state) do
    process_due_notifications()
    schedule_poll(@poll_interval_ms)
    {:noreply, state}
  end

  defp process_due_notifications do
    PushServer.Buffer.get_due()
    |> Enum.group_by(fn {_, user_id, _, _, _} -> user_id end)
    |> Enum.each(&deliver_to_user/1)
  end

  defp deliver_to_user({user_id, rows}) do
    case PushServer.Repo.get_user(user_id) do
      {:ok, user} when not is_nil(user) ->
        payloads = Enum.map(rows, fn {_, _, payload, _, _} -> payload end)
        summary = PushServer.Payload.summarize(payloads, user_id)
        subscription = Jason.decode!(user["push_subscription"])

        case PushServer.WebPush.send(subscription, summary) do
          :ok ->
            Logger.info("Notification delivered: user_id=#{user_id} count=#{length(rows)}")
            :telemetry.execute([:push_server, :delivery, :success], %{count: 1})
            cleanup(rows)
          {:error, :gone} ->
            :telemetry.execute([:push_server, :delivery, :failure], %{count: 1}, %{reason: "gone"})
            Logger.info("subscription expired", user_id: user_id)
            PushServer.Repo.deactivate_user(user_id)
            cleanup(rows)
          {:error, reason} ->
            :telemetry.execute([:push_server, :delivery, :failure], %{count: 1}, %{reason: inspect(reason)})
            Logger.warning("delivery failed", 
              user_id: user_id, 
              reason: inspect(reason),
              endpoint: subscription["endpoint"],
              has_keys: Map.has_key?(subscription, "keys")
            )
            # In a toy project, we'll just let them stay in buffer or drop if too old
        end

      _ ->
        cleanup(rows)
    end
  end

  defp cleanup(rows) do
    ids = Enum.map(rows, fn {id, _, _, _, _} -> id end)
    PushServer.Buffer.delete(ids)
  end

  defp schedule_poll(delay), do: Process.send_after(self(), :poll, delay)
end
