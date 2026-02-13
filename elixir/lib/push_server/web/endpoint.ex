defmodule PushServer.Web.Endpoint do
  @moduledoc """
  HTTP server setup.

  max_keepalive is the soft cap — limits concurrent persistent connections.
  When full, new connections queue at Nginx rather than overwhelming BEAM.
  Nginx's keepalive directive controls the pool size on its side.
  """

  def child_spec(_) do
    port = System.get_env("PORT", "4000") |> String.to_integer()

    Plug.Cowboy.child_spec(
      scheme: :http,
      plug: PushServer.Web.Router,
      options: [
        port: port,
        protocol_options: [
          # Soft cap: limits concurrent keepalive connections
          # When this fills, new requests queue at Nginx
          # Nginx then either waits or falls back to Node.js
          max_keepalive: 100,

          # Request timeout — prevents slow clients from holding connections
          request_timeout: 5_000,

          # Idle timeout — release connections from idle Misskey instances
          idle_timeout: 30_000,
        ]
      ]
    )
  end
end
