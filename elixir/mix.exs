defmodule PushServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :push_server,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      # Compiler optimizations
      consolidate_protocols: Mix.env() == :prod,
      compilers: Mix.compilers(),
      # Build optimizations
      build_embedded: Mix.env() == :prod,
      releases: [
        push_server: [
          include_executables_for: [:unix],
          strip_beams: Mix.env() == :prod,
          # Skip unnecessary files in release
          include_erts: true,
          quiet: true
        ]
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :os_mon],
      mod: {PushServer.Application, []}
    ]
  end

  defp deps do
    [
      # HTTP server
      {:plug_cowboy, "~> 2.7"},
      {:jason, "~> 1.4"},

      # SQLite
      {:exqlite, "~> 0.23"},

      # HTTP client (for web push dispatch)
      {:req, "~> 0.5"},

      # Monitoring
      {:telemetry_metrics, "~> 1.0"},
      {:telemetry_poller, "~> 1.0"},
      {:telemetry_metrics_prometheus, "~> 1.1"}
    ]
  end
end
