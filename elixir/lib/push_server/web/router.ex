defmodule PushServer.Web.Router do
  use Plug.Router
  require Logger

  plug Plug.Parsers, parsers: [:json], json_decoder: Jason
  plug :cors
  plug :match
  plug :dispatch

  defp cors(conn, _opts) do
    conn
    |> put_resp_header("access-control-allow-origin", "*")
    |> put_resp_header("access-control-allow-methods", "POST, GET, PATCH, DELETE, OPTIONS")
    |> put_resp_header("access-control-allow-headers", "Authorization, Content-Type, X-Misskey-Hook-Secret")
    |> put_resp_header("access-control-max-age", "86400")
    |> handle_options()
  end

  defp handle_options(%{method: "OPTIONS"} = conn) do
    conn |> send_resp(204, "") |> halt()
  end
  defp handle_options(conn), do: conn

  post "/webhook/:user_id" do
    user_id = conn.params["user_id"]
    secret_header = get_req_header(conn, "x-misskey-hook-secret") |> List.first()

    with {:ok, user} when not is_nil(user) <- PushServer.Repo.get_user(user_id),
         true <- user["active"] == 1,
         true <- secret_header == user["webhook_secret"],
         {:ok, payload} <- PushServer.Payload.build(conn.body_params, user["notification_preference"]) do
      
      delay = if user["supporter"] == 1, do: user["delay_minutes"], else: max(user["delay_minutes"], 1)
      deliver_at = DateTime.utc_now() |> DateTime.add(delay * 60, :second)
      
      :telemetry.execute([:push_server, :webhook, :arrival], %{count: 1}, %{type: conn.body_params["type"]})
      PushServer.Buffer.insert(user_id, payload, deliver_at)
      send_resp(conn, 200, "ok")
    else
      _ -> send_resp(conn, 200, "ok") # Always 200 for Misskey
    end
  end

  post "/register" do
    with {:ok, body} <- validate_register(conn.body_params),
         :ok <- PushServer.Repo.insert_user(body) do
      send_json(conn, 200, %{ok: true})
    else
      _ -> send_json(conn, 400, %{error: "invalid request"})
    end
  end

  delete "/unregister" do
    if id = conn.body_params["user_id"] do
      PushServer.Repo.delete_user(id)
      send_json(conn, 200, %{ok: true})
    else
      send_json(conn, 400, %{error: "missing user_id"})
    end
  end

  patch "/settings" do
    user_id = conn.body_params["user_id"]
    delay = conn.body_params["delay_minutes"]
    pref = conn.body_params["notification_preference"]

    if delay, do: PushServer.Repo.update_delay(user_id, delay)
    if pref, do: PushServer.Repo.update_preference(user_id, pref)
    
    send_json(conn, 200, %{ok: true})
  end

  get "/health" do
    send_json(conn, 200, %{
      status: "ok",
      active_users: PushServer.Repo.count_active_users(),
      buffered_notifications: length(PushServer.Buffer.get_due())
    })
  end

  match _, do: send_resp(conn, 404, "not found")

  defp validate_register(p) do
    required = ["id", "misskey_origin", "webhook_user_id", "webhook_secret", "push_subscription"]
    if Enum.all?(required, &Map.has_key?(p, &1)) do
      {:ok, %{
        id: p["id"],
        misskey_origin: p["misskey_origin"],
        webhook_user_id: p["webhook_user_id"],
        webhook_secret: p["webhook_secret"],
        push_subscription: p["push_subscription"],
        notification_preference: p["notification_preference"] || "quiet",
        delay_minutes: p["delay_minutes"] || 1
      }}
    else
      {:error, :invalid}
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
