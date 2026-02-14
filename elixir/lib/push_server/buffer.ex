defmodule PushServer.Buffer do
  @moduledoc """
  In-memory notification buffer using ETS.
  Stateless across restarts, which is fine since notifications are transient (~10m).
  """
  use GenServer

  @table :pending_notifications

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def insert(user_id, payload, deliver_at) do
    case :ets.info(@table, :name) do
      :undefined ->
        :ok

      _ ->
        # ID is a simple ref for in-memory uniqueness
        id = make_ref()
        :ets.insert(@table, {id, user_id, payload, deliver_at, DateTime.utc_now()})
        :ok
    end
  end

  def get_due() do
    now = DateTime.utc_now()

    case :ets.info(@table, :name) do
      :undefined ->
        []

      _ ->
        # Match all, filter in memory (it's a small toy project)
        :ets.tab2list(@table)
        |> Enum.filter(fn {_, _, _, deliver_at, _} -> DateTime.compare(deliver_at, now) != :gt end)
    end
  end

  def delete(ids) do
    case :ets.info(@table, :name) do
      :undefined -> :ok
      _ -> Enum.each(ids, &:ets.delete(@table, &1))
    end

    :ok
  end

  def buffer_size() do
    case :ets.info(@table, :size) do
      :undefined -> 0
      size -> size
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, nil}
  end
end
