defmodule PushServer.MixProject do
  use Mix.Project

  def project do
    [
      app: :push_server,
      version: "0.1.0",
      elixir: "~> 1.16",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      releases: [
        push_server: [
          include_executables_for: [:unix],
          strip_beams: false
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

      # OpenTelemetry
      {:opentelemetry, "~> 1.4"},
      {:opentelemetry_api, "~> 1.3"},
      {:opentelemetry_exporter, "~> 1.7"},
      {:opentelemetry_cowboy, "~> 0.3"},
      {:opentelemetry_req, "~> 0.2"},
    ]
  end
end
