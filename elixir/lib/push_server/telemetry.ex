defmodule PushServer.Telemetry do
  use Supervisor
  import Telemetry.Metrics

  def start_link(arg) do
    Supervisor.start_link(__MODULE__, arg, name: __MODULE__)
  end

  @impl true
  def init(_arg) do
    children = [
      # Telemetry poller for VM metrics (CPU, Memory, etc.)
      {:telemetry_poller, measurements: periodic_measurements(), period: 10_000},
      # Prometheus reporter - starts its own HTTP server on :9568/metrics
      {TelemetryMetricsPrometheus, metrics: metrics(), port: 9568}
    ]

    Supervisor.init(children, strategy: :one_for_one)
  end

  def metrics do
    [
      # VM Metrics
      last_value("vm.memory.total", unit: :byte),
      last_value("vm.total_run_queue_lengths.total"),
      last_value("vm.total_run_queue_lengths.cpu"),
      last_value("vm.total_run_queue_lengths.io"),

      # HTTP Metrics (Cowboy/Plug)
      counter("plug.stop.duration",
        tags: [:method, :route],
        unit: :native
      ),

      # Custom Business Metrics
      counter("push_server.webhook.arrival.count", tags: [:type]),
      counter("push_server.delivery.success.count"),
      counter("push_server.delivery.failure.count", tags: [:reason]),
      last_value("push_server.buffer.size.count"),
      last_value("push_server.repo.active_users.count")
    ]
  end

  defp periodic_measurements do
    [
      # A module, function and arguments to be invoked periodically.
      # This function must call :telemetry.execute/3.
      {__MODULE__, :measure_business_metrics, []}
    ]
  end

  def measure_business_metrics do
    :telemetry.execute([:push_server, :buffer, :size], %{count: PushServer.Buffer.buffer_size()})

    repo_count = if Process.whereis(PushServer.Repo), do: PushServer.Repo.count_active_users(), else: 0
    :telemetry.execute([:push_server, :repo, :active_users], %{count: repo_count})
  end
end
