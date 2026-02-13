defmodule PushServer.Web.Router do
  @moduledoc """
  HTTP router — four endpoints, each with one job:

    POST /webhook/:user_id      receive Misskey webhook, insert to SQLite
    POST /register              register user + push subscription
    DELETE /unregister          remove user and their pending notifications
    PATCH /settings             update delay, preference
    GET  /health                system health check
  """
  use Plug.Router

  require Logger

  plug Plug.Parsers,
    parsers: [:json],
    json_decoder: Jason

  plug :match
  plug :dispatch

  # --- Webhook receiver ---
  # Fast path: verify, insert, return 200. No business logic here.

  post "/webhook/:user_id" do
    secret_header =
      conn
      |> get_req_header("x-misskey-hook-secret")
      |> List.first()

    with {:ok, user}  <- get_active_user(conn.params["user_id"]),
         :ok          <- verify_secret(secret_header, user["webhook_secret"]),
         {:ok, payload} <- PushServer.Payload.build(
           conn.body_params, user["notification_preference"]),
         deliver_at   <- compute_deliver_at(user),
         {:ok}        <- PushServer.Repo.insert_pending(
           user["id"], payload, deliver_at),
         _            <- PushServer.Repo.update_last_webhook_at(user["id"]) do

      send_resp(conn, 200, "ok")
    else
      {:error, :not_found} ->
        # Unknown user — return 200 to stop Misskey retrying
        # (this webhook is for a user who unregistered)
        send_resp(conn, 200, "ok")

      {:error, :secret_mismatch} ->
        Logger.warning("webhook secret mismatch",
          user_id: conn.params["user_id"])
        # Return 200 — don't leak that the user exists
        send_resp(conn, 200, "ok")

      {:error, :missing_secret} ->
        Logger.warning("webhook missing secret header",
          user_id: conn.params["user_id"])
        send_resp(conn, 200, "ok")

      {:error, :unexpected_shape} ->
        # Payload.build already logged this with key names
        # Return 200 — Misskey retrying won't fix a shape mismatch
        send_resp(conn, 200, "ok")

      {:error, reason} ->
        Logger.error("webhook handler error",
          user_id: conn.params["user_id"],
          reason: inspect(reason))
        # Return 500 — triggers Nginx fallback to Node.js
        send_resp(conn, 500, "error")
    end
  end

  # --- Registration ---
  # Client calls Misskey directly to create webhook, then calls this
  # with the webhook_secret and push_subscription. No token ever sent here.

  post "/register" do
    with {:ok, body}   <- validate_register(conn.body_params),
         {:ok}         <- PushServer.Repo.insert_user(body) do

      send_json(conn, 200, %{ok: true})
    else
      {:error, :invalid} ->
        send_json(conn, 400, %{error: "missing required fields"})
      {:error, reason} ->
        Logger.error("registration failed", reason: inspect(reason))
        send_json(conn, 500, %{error: "registration failed"})
    end
  end

  # --- Unregister ---

  delete "/unregister" do
    user_id = conn.body_params["user_id"]

    if is_nil(user_id) do
      send_json(conn, 400, %{error: "missing user_id"})
    else
      PushServer.Repo.delete_user(user_id)
      send_json(conn, 200, %{ok: true})
    end
  end

  # --- Settings update ---
  # User can adjust delay (1-10 min) and notification preference.
  # Supporter flag is set server-side only (not via this endpoint).

  patch "/settings" do
    user_id = conn.body_params["user_id"]

    with {:ok, user} <- get_active_user(user_id) do
      delay      = conn.body_params["delay_minutes"]
      preference = conn.body_params["notification_preference"]

      cond do
        # Delay validation
        !is_nil(delay) and not valid_delay?(delay, user["supporter"] == 1) ->
          send_json(conn, 400, %{
            error: "delay_minutes must be 1-10 (0 requires supporter status)"
          })

        # Preference validation
        !is_nil(preference) and preference not in ["quiet", "normal", "aware"] ->
          send_json(conn, 400, %{
            error: "notification_preference must be quiet, normal, or aware"
          })

        true ->
          results = [
            if(delay, do: PushServer.Repo.update_delay(user_id, delay), else: {:ok}),
            if(preference, do: PushServer.Repo.update_preference(user_id, preference), else: {:ok})
          ]
          if Enum.any?(results, &match?({:error, _}, &1)) do
            Logger.error("settings update partially failed", user_id: user_id)
            send_json(conn, 500, %{error: "update failed"})
          else
            send_json(conn, 200, %{ok: true})
          end
      end
    else
      {:error, :not_found} -> send_json(conn, 404, %{error: "user not found"})
      {:error, reason} ->
        Logger.error("settings update failed", reason: inspect(reason))
        send_json(conn, 500, %{error: "update failed"})
    end
  end

  # --- Health check ---
  # Used by uptime monitors and your own visibility.
  # Check this when something feels wrong.

  get "/health" do
    heartbeat_age = case PushServer.Repo.get_heartbeat() do
      {:ok, %{"last_at" => last_at}} ->
        {:ok, dt, _} = DateTime.from_iso8601(last_at)
        DateTime.diff(DateTime.utc_now(), dt, :second)
      _ ->
        nil
    end

    worker_ok = case heartbeat_age do
      nil -> false
      age -> age < 30  # if heartbeat is >30s old, worker is likely dead
    end

    checks = %{
      db: db_reachable?(),
      delivery_worker: worker_ok,
      delivery_worker_heartbeat_seconds_ago: heartbeat_age,
      pending_stale_count: PushServer.Repo.count_stale_pending(),
      active_users: PushServer.Repo.count_active_users(),
    }

    status = if checks.db and checks.delivery_worker, do: 200, else: 503
    send_json(conn, status, checks)
  end

  match _ do
    send_resp(conn, 404, "not found")
  end

  # --- Private helpers ---

  defp get_active_user(nil), do: {:error, :not_found}
  defp get_active_user(user_id) do
    case PushServer.Repo.get_user(user_id) do
      {:ok, nil}  -> {:error, :not_found}
      {:ok, %{"active" => 0}} -> {:error, :not_found}
      {:ok, user} -> {:ok, user}
      {:error, r} -> {:error, r}
    end
  end

  defp verify_secret(nil, _expected),
    do: {:error, :missing_secret}
  defp verify_secret(received, expected) when received == expected,
    do: :ok
  defp verify_secret(_, _),
    do: {:error, :secret_mismatch}

  defp compute_deliver_at(user) do
    # supporter with delay_minutes = 0 → immediate
    # free user → minimum 1 minute
    delay =
      if user["supporter"] == 1 do
        user["delay_minutes"]
      else
        max(user["delay_minutes"], 1)
      end

    DateTime.utc_now() |> DateTime.add(delay * 60, :second)
  end

  defp valid_delay?(delay, supporter) do
    cond do
      not is_integer(delay)          -> false
      delay == 0 and not supporter   -> false
      delay < 0                      -> false
      delay > 10                     -> false
      true                           -> true
    end
  end

  defp validate_register(params) do
    required = ["id", "misskey_origin", "webhook_user_id",
                "webhook_secret", "push_subscription"]

    if Enum.all?(required, &Map.has_key?(params, &1)) do
      {:ok, %{
        id: params["id"],
        misskey_origin: params["misskey_origin"],
        webhook_user_id: params["webhook_user_id"],
        webhook_secret: params["webhook_secret"],
        push_subscription: params["push_subscription"],
        notification_preference: params["notification_preference"] || "quiet",
        delay_minutes: params["delay_minutes"] || 1
      }}
    else
      {:error, :invalid}
    end
  end

  defp db_reachable? do
    case PushServer.Repo.count_active_users() do
      n when is_integer(n) -> true
      _ -> false
    end
  end

  defp send_json(conn, status, body) do
    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(body))
  end
end
