defmodule PushServer.Application do
  @moduledoc """
  Supervision tree — three children, each with one job:

    Repo           → SQLite connection, schema setup
    DeliveryWorker → polls pending_notifications, sends push
    Endpoint       → HTTP server (webhook receiver, registration, health)

  Strategy: :one_for_one — each child is independent.
  A crashing DeliveryWorker does not affect the HTTP server, and vice versa.
  """
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PushServer.Repo,
      PushServer.Worker.DeliveryWorker,
      PushServer.Web.Endpoint,
    ]

    opts = [
      strategy: :one_for_one,
      name: PushServer.Supervisor,
      # 3 crashes in 10 seconds → supervisor gives up
      # systemd then restarts the whole process
      max_restarts: 3,
      max_seconds: 10
    ]

    Supervisor.start_link(children, opts)
  end
end
