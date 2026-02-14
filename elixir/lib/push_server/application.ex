defmodule PushServer.Application do
  use Application

  @impl true
  def start(_type, _args) do
    children = [
      PushServer.Telemetry,
      PushServer.Repo,
      PushServer.Buffer,
      PushServer.Worker.DeliveryWorker,
      PushServer.Web.Endpoint,
    ]

    opts = [strategy: :one_for_one, name: PushServer.Supervisor]
    Supervisor.start_link(children, opts)
  end
end
