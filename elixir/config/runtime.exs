import Config

config :opentelemetry,
  resource: [
    service: [name: "push-server-elixir", version: "0.1.0"]
  ]
