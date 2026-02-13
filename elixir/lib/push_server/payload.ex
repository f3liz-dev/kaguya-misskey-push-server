defmodule PushServer.Payload do
  @moduledoc """
  Pure functions — no OTP, no side effects.

  Notification content is never written to disk or logged here.
  It exists in memory only long enough to be encrypted by WebPush.
  """

  # Misskey webhook body shape:
  # %{
  #   "type" => "mention" | "reply" | "renote" | "reaction" | "follow" | ...,
  #   "body" => %{
  #     "id" => "...",
  #     "userId" => "...",
  #     "user" => %{"name" => "...", "username" => "..."},
  #     "note" => %{"text" => "..."},   # for mention/reply/renote/quote
  #     "reaction" => "...",            # for reaction
  #   }
  # }

  @doc """
  Build a single push payload from a Misskey webhook body.
  Returns {:ok, payload} or {:error, :unexpected_shape}.
  """
  def build(params, preference) do
    case params do
      %{"type" => type, "body" => body} ->
        payload = %{
          title: title(type, body),
          body: body_text(type, body),
          tag: tag(type, body),
          silent: silent?(type, preference),
          renotify: false,
          data: %{type: type}
          # notification content not included in data —
          # title/body is enough, full content stays on Misskey
        }
        {:ok, payload}

      other ->
        # Log keys only, never content — for diagnosing shape changes
        # between Misskey versions without leaking notification data
        require Logger
        Logger.warning("unexpected webhook payload shape",
          keys: Map.keys(other),
          type_present: Map.has_key?(other, "type")
        )
        {:error, :unexpected_shape}
    end
  end

  @doc """
  Summarize multiple payloads into one calm grouped notification.
  Single payload passes through unchanged.
  """
  def summarize([single]), do: single

  def summarize(payloads) do
    counts = Enum.frequencies_by(payloads, & &1.type)

    body =
      counts
      |> Enum.map(fn {type, n} -> "#{n} #{label(type)}" end)
      |> Enum.join(", ")

    %{
      title: "#{length(payloads)} new notifications",
      body: body,
      tag: "summary",
      silent: true,   # summary is always silent — it's a report, not an alert
      renotify: false,
      data: %{type: "summary"}
    }
  end

  # --- Private: title per type ---

  defp title("mention", body),  do: "#{username(body)} mentioned you"
  defp title("reply", body),    do: "#{username(body)} replied"
  defp title("renote", body),   do: "#{username(body)} renoted your post"
  defp title("quote", body),    do: "#{username(body)} quoted your post"
  defp title("reaction", body), do: "#{username(body)} reacted #{reaction(body)}"
  defp title("follow", body),   do: "#{username(body)} followed you"
  defp title("receiveFollowRequest", body), do: "#{username(body)} wants to follow you"
  defp title("pollEnded", _),   do: "A poll you voted in ended"
  defp title(type, _),          do: "New notification (#{type})"

  # --- Private: body text per type ---

  defp body_text(type, body) when type in ["mention", "reply", "quote"] do
    note_text(body)
  end
  defp body_text("renote", body),   do: note_text(body)
  defp body_text("reaction", _),    do: ""
  defp body_text("follow", _),      do: ""
  defp body_text(_, _),             do: ""

  # --- Private: tag for grouping on device ---
  # Same tag = replaces previous notification of same type
  # Mentions stay unique (each gets its own tag) — they need distinct attention
  # Reactions/follows collapse into one notification

  defp tag("mention", body),  do: "mention-#{note_id(body)}"
  defp tag("reply", body),    do: "reply-#{note_id(body)}"
  defp tag("quote", body),    do: "quote-#{note_id(body)}"
  defp tag("reaction", _),    do: "reactions"
  defp tag("renote", _),      do: "renotes"
  defp tag("follow", _),      do: "follows"
  defp tag(type, _),          do: type

  # --- Private: silence rules ---
  # quiet:  always silent
  # normal: always silent (individual, not grouped)
  # aware:  sound for mentions/replies only

  defp silent?(_, "quiet"),   do: true
  defp silent?(_, "normal"),  do: true
  defp silent?(type, "aware") when type in ["mention", "reply"], do: false
  defp silent?(_, "aware"),   do: true
  defp silent?(_, _),         do: true  # unknown preference → quiet

  # --- Private: label for summary ---

  defp label("mention"),              do: "mentions"
  defp label("reply"),                do: "replies"
  defp label("renote"),               do: "renotes"
  defp label("quote"),                do: "quotes"
  defp label("reaction"),             do: "reactions"
  defp label("follow"),               do: "new followers"
  defp label("receiveFollowRequest"), do: "follow requests"
  defp label(other),                  do: other

  # --- Private: field extractors ---

  defp username(%{"user" => %{"name" => name}}) when is_binary(name) and name != "",
    do: name
  defp username(%{"user" => %{"username" => username}}),
    do: "@#{username}"
  defp username(_),
    do: "Someone"

  defp note_text(%{"note" => %{"text" => text}}) when is_binary(text),
    do: String.slice(text, 0, 100)
  defp note_text(_), do: ""

  defp note_id(%{"note" => %{"id" => id}}), do: id
  defp note_id(_), do: "unknown"

  defp reaction(%{"reaction" => r}) when is_binary(r), do: r
  defp reaction(_), do: ""
end
