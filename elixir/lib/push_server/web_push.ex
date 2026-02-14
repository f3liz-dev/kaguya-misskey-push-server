defmodule PushServer.WebPush do
  @moduledoc """
  Pure functions — VAPID signing + AES-128-GCM payload encryption.

  Implements RFC 8291 (Message Encryption for Web Push)
  and RFC 8292 (VAPID for Web Push).
  """

  require Logger

  @max_record_size 4096

  def vapid_public_key, do: System.fetch_env!("VAPID_PUBLIC_KEY")
  def vapid_private_key, do: System.fetch_env!("VAPID_PRIVATE_KEY")
  def vapid_subject, do: System.fetch_env!("VAPID_SUBJECT")

  @doc """
  Encrypt payload and POST to push endpoint.
  """
  def send(push_subscription, payload) when is_map(push_subscription) do
    endpoint = push_subscription["endpoint"]
    p256dh   = push_subscription["keys"]["p256dh"]
    auth     = push_subscription["keys"]["auth"]

    body_json = Jason.encode!(payload)

    try do
      encrypted = encrypt(body_json, p256dh, auth)
      headers   = vapid_headers(endpoint)

      case Req.post(endpoint,
        body: encrypted,
        headers: Map.merge(headers, %{
          "content-type"     => "application/octet-stream",
          "content-encoding" => "aes128gcm",
          "ttl"              => "86400"
        }),
        receive_timeout: 10_000
      ) do
        {:ok, %{status: s}} when s in [200, 201] ->
          :ok
        {:ok, %{status: 410}} ->
          {:error, :gone}
        {:ok, %{status: s}} ->
          Logger.warning("push endpoint unexpected status", status: s)
          {:error, {:status, s}}
        {:error, reason} ->
          Logger.warning("push endpoint request failed", reason: inspect(reason))
          {:error, reason}
      end
    rescue
      e -> 
        Logger.error("encryption or dispatch failed", 
          error: Exception.message(e),
          stacktrace: Exception.format_stacktrace(__STACKTRACE__),
          endpoint: endpoint
        )
        {:error, :encryption_failed}
    end
  end

  # --- VAPID headers (RFC 8292) ---

  defp vapid_headers(endpoint) do
    origin     = URI.parse(endpoint) |> then(&"#{&1.scheme}://#{&1.host}")
    expiration = System.os_time(:second) + 12 * 3600

    header = b64url(Jason.encode!(%{"typ" => "JWT", "alg" => "ES256"}))
    claims = b64url(Jason.encode!(%{
      "aud" => origin,
      "exp" => expiration,
      "sub" => vapid_subject()
    }))

    signing_input = "#{header}.#{claims}"

    private_key = import_vapid_private_key(vapid_private_key())
    signature   = :crypto.sign(:ecdsa, :sha256,
      signing_input, [private_key, :prime256v1])

    raw_sig = der_to_raw_sig(signature)
    jwt = "#{signing_input}.#{b64url_bytes(raw_sig)}"

    %{
      "authorization" => "vapid t=#{jwt}, k=#{vapid_public_key()}"
    }
  end

  defp import_vapid_private_key(b64), do: b64 |> b64decode() |> :binary.bin_to_list()

  defp der_to_raw_sig(der) do
    {:ECDSASignature, r, s} = :public_key.der_decode(:ECDSASignature, der)
    r_bin = :binary.encode_unsigned(r) |> pad_to(32)
    s_bin = :binary.encode_unsigned(s) |> pad_to(32)
    r_bin <> s_bin
  end

  defp pad_to(bin, size) when byte_size(bin) < size,
    do: :binary.copy(<<0>>, size - byte_size(bin)) <> bin
  defp pad_to(bin, _size), do: bin

  # --- AES-128-GCM encryption (RFC 8291) ---

  defp encrypt(plaintext, p256dh_b64, auth_b64) do
    auth_secret    = b64decode(auth_b64)
    receiver_pub   = b64decode(p256dh_b64)

    {sender_pub_raw, sender_priv} = :crypto.generate_key(:ecdh, :prime256v1)

    shared_secret = :crypto.compute_key(:ecdh, receiver_pub, sender_priv, :prime256v1)
    salt = :crypto.strong_rand_bytes(16)

    prk = :crypto.mac(:hmac, :sha256, auth_secret, shared_secret)
    ikm = :crypto.mac(:hmac, :sha256, prk, "WebPush: info\0" <> receiver_pub <> sender_pub_raw <> <<1>>)
          |> binary_part(0, 32)

    cek   = hkdf(salt, ikm, "Content-Encoding: aes128gcm\0", 16)
    nonce = hkdf(salt, ikm, "Content-Encoding: nonce\0", 12)

    padded = plaintext <> <<2>>
    {ciphertext, tag} = :crypto.crypto_one_time_aead(:aes_128_gcm, cek, nonce, padded, <<>>, true)

    record_size = <<@max_record_size::unsigned-big-integer-32>>
    key_len     = <<byte_size(sender_pub_raw)::unsigned-integer-8>>

    salt <> record_size <> key_len <> sender_pub_raw <> ciphertext <> tag
  end

  defp hkdf(salt, ikm, info, length) do
    prk = :crypto.mac(:hmac, :sha256, salt, ikm)
    :crypto.mac(:hmac, :sha256, prk, info <> <<1>>) |> binary_part(0, length)
  end

  defp b64url(str), do: Base.encode64(str, padding: false) |> String.replace("+", "-") |> String.replace("/", "_")
  defp b64url_bytes(bin), do: Base.encode64(bin, padding: false) |> String.replace("+", "-") |> String.replace("/", "_")
  defp b64decode(str), do: str |> String.replace("-", "+") |> String.replace("_", "/") |> Base.decode64!(padding: false)
end
