defmodule PushServer.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PushServer.Repo,
      PushServer.Buffer,
      PushServer.Telemetry,
      PushServer.Worker.DeliveryWorker,
      PushServer.Worker.PingWorker,
      PushServer.Web.Endpoint,
    ]

    opts = [strategy: :one_for_one, name: PushServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
