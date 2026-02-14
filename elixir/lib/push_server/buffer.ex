defmodule PushServer.Buffer do
  @moduledoc """
  In-memory notification buffer using ETS.
  Stateless across restarts, which is fine since notifications are transient (~10m).
  """
  use GenServer

  @table :pending_notifications

  def start_link(_), do: GenServer.start_link(__MODULE__, [], name: __MODULE__)

  def insert(user_id, payload, deliver_at) do
    # ID is a simple ref for in-memory uniqueness
    id = make_ref()
    :ets.insert(@table, {id, user_id, payload, deliver_at, DateTime.utc_now()})
    :ok
  end

  def get_due() do
    now = DateTime.utc_now()
    # Match all, filter in memory (it's a small toy project)
    :ets.tab2list(@table)
    |> Enum.filter(fn {_, _, _, deliver_at, _} -> DateTime.compare(deliver_at, now) != :gt end)
  end

  def delete(ids) do
    Enum.each(ids, &:ets.delete(@table, &1))
    :ok
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:set, :public, :named_table, read_concurrency: true])
    {:ok, nil}
  end
end
