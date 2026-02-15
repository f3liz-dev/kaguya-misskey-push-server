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
      
      # Use buffer_seconds for collection time (0-600s), default to 60s
      buffer_seconds = Map.get(user, "buffer_seconds", 60)
      deliver_at = DateTime.utc_now() |> DateTime.add(buffer_seconds, :second)
      
      Logger.info("Webhook received: user_id=#{user_id} type=#{conn.body_params["type"]} buffer=#{buffer_seconds}s")
      :telemetry.execute([:push_server, :webhook, :arrival], %{count: 1}, %{type: conn.body_params["type"]})
      PushServer.Buffer.insert(user_id, payload, deliver_at)
      send_resp(conn, 200, "ok")
    else
      _ -> send_resp(conn, 200, "ok") # Always 200 for Misskey
    end
  end

  post "/register" do
    Logger.info("Register request received")
    with {:ok, body} <- validate_register(conn.body_params),
         :ok <- PushServer.Repo.insert_user(body) do
      Logger.info("Registration successful for user: #{body.id} (Misskey ID: #{body.webhook_user_id})")
      send_json(conn, 200, %{ok: true, id: body.id})
    else
      {:error, :invalid} -> 
        Logger.warning("Registration failed: invalid request body")
        send_json(conn, 400, %{error: "invalid request"})
      {:error, :db_error} -> 
        Logger.error("Registration failed: database error")
        send_json(conn, 500, %{error: "database error"})
      _ -> 
        Logger.error("Registration failed: unknown error")
        send_json(conn, 400, %{error: "invalid request"})
    end
  end

  delete "/unregister" do
    id = conn.body_params["user_id"] || conn.body_params["id"]
    secret_header = get_req_header(conn, "x-misskey-hook-secret") |> List.first()

    with not is_nil(id) <- true,
         {:ok, user} when not is_nil(user) <- PushServer.Repo.get_user(id),
         true <- secret_header == user["webhook_secret"] do
      PushServer.Repo.delete_user(id)
      send_json(conn, 200, %{ok: true})
    else
      false -> send_json(conn, 400, %{error: "missing id"})
      _ -> send_json(conn, 403, %{error: "unauthorized"})
    end
  end

  patch "/settings" do
    id = conn.body_params["user_id"] || conn.body_params["id"]
    secret_header = get_req_header(conn, "x-misskey-hook-secret") |> List.first()
    
    delay = conn.body_params["delay_minutes"]
    pref = conn.body_params["notification_preference"]
    buffer = conn.body_params["buffer_seconds"]

    with not is_nil(id) <- true,
         {:ok, user} when not is_nil(user) <- PushServer.Repo.get_user(id),
         true <- secret_header == user["webhook_secret"] do
      
      if delay, do: PushServer.Repo.update_delay(id, delay)
      if pref, do: PushServer.Repo.update_preference(id, pref)
      if buffer, do: PushServer.Repo.update_buffer_seconds(id, buffer)
      
      send_json(conn, 200, %{ok: true})
    else
      false -> send_json(conn, 400, %{error: "missing id"})
      _ -> send_json(conn, 403, %{error: "unauthorized"})
    end
  end

  get "/health" do
    # Safely get metrics, default to 0 if not ready
    active_users = try do
      PushServer.Repo.count_active_users()
    rescue
      _ -> 0
    end
    
    buffered_notifications = try do
      PushServer.Buffer.get_due() |> length()
    rescue
      _ -> 0
    end
    
    send_json(conn, 200, %{
      status: "ok",
      active_users: active_users,
      buffered_notifications: buffered_notifications
    })
  end

  match _, do: send_resp(conn, 404, "not found")

  defp validate_register(p) do
    required = ["misskey_origin", "webhook_user_id", "webhook_secret", "push_subscription"]
    missing = Enum.filter(required, fn key -> !Map.has_key?(p, key) end)
    
    if Enum.empty?(missing) do
      buffer_seconds = case p["buffer_seconds"] do
        val when is_integer(val) -> max(0, min(val, 600))
        _ -> 60
      end

      # Generate a random public ID for the webhook URL
      id = :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
      
      {:ok, %{
        id: id,
        misskey_origin: p["misskey_origin"],
        webhook_user_id: p["webhook_user_id"],
        webhook_secret: p["webhook_secret"],
        push_subscription: p["push_subscription"],
        notification_preference: p["notification_preference"] || "quiet",
        delay_minutes: p["delay_minutes"] || 1,
        buffer_seconds: buffer_seconds
      }}
    else
      Logger.warning("Missing required fields: #{inspect(missing)}")
      {:error, :invalid}
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
