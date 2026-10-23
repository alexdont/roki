defmodule RokiWeb.SyncApiController do
  @moduledoc """
  Laev CLI sync API — a dumb blob store, two routes on one path:

      GET   /laev/:token/:doc → 200 + stored bytes + ETag, or 404
      PUT   /laev/:token/:doc → store body verbatim, 200 + new ETag
                                If-Match stale     → 412, no overwrite
      PATCH /laev/:token/:doc → merge a partial bundle (LWW per record,
                                tombstones kept), 200 + merged ETag; no
                                If-Match — merges serialize server-side
      all                     : malformed token    → 401
                                not Laev-shaped    → 422
                                > 5 MB             → 413

  Open registration: any token matching the Laev format is a tenant
  (see `Roki.SyncStore.valid_token?/1`); the PUT body must sniff as
  Laev data so bots can't park junk here. The token rides in the path
  (the CLI bakes it into its base URL: `https://…/laev/<token>/watchlist`).
  The body is opaque JSON stored byte-for-byte —
  `RokiWeb.RawBodyReader` preserves the raw bytes past the
  endpoint's JSON parser; never read the parsed params.
  """
  use RokiWeb, :controller

  alias Roki.SyncStore, as: Store

  plug :check_token

  def show(conn, %{"doc" => doc}) do
    case Store.get(conn.assigns.laev_token, doc) do
      {:ok, body, etag} ->
        conn
        |> put_resp_header("etag", quote_etag(etag))
        |> put_resp_content_type("application/json")
        |> send_resp(200, body)

      :not_found ->
        # Never invent content — an empty store is a 404, not "{}".
        send_resp(conn, 404, "")
    end
  end

  def put(conn, %{"doc" => doc}) do
    body = raw_body(conn)

    cond do
      body == nil ->
        send_resp(conn, 400, "")

      byte_size(body) > Store.max_bytes() ->
        send_resp(conn, 413, "")

      not Store.plausible_document?(body) ->
        send_resp(conn, 422, "")

      true ->
        case Store.put(conn.assigns.laev_token, doc, body, if_match(conn)) do
          {:ok, etag} ->
            conn
            |> put_resp_header("etag", quote_etag(etag))
            |> send_resp(200, "")

          :precondition_failed ->
            send_resp(conn, 412, "")
        end
    end
  end

  def merge(conn, %{"doc" => doc}) do
    body = raw_body(conn)

    cond do
      body == nil ->
        send_resp(conn, 400, "")

      byte_size(body) > Store.max_bytes() ->
        send_resp(conn, 413, "")

      not Store.plausible_document?(body) ->
        send_resp(conn, 422, "")

      true ->
        # plausible_document? guarantees this decodes to a map.
        {:ok, patch} = Jason.decode(body)

        case Store.merge(conn.assigns.laev_token, doc, patch) do
          {:ok, etag} ->
            conn
            |> put_resp_header("etag", quote_etag(etag))
            |> send_resp(200, "")

          {:error, :invalid} ->
            send_resp(conn, 422, "")
        end
    end
  end

  # Raw bytes stashed by RawBodyReader when a parser consumed the body
  # (application/json); for pass-through content types (octet-stream)
  # the body is still unread and we read it here.
  defp raw_body(conn) do
    case conn.private[:laev_raw_body] do
      nil ->
        case Plug.Conn.read_body(conn, length: Store.max_bytes() + 1) do
          {:ok, body, _conn} -> body
          _ -> nil
        end

      iodata ->
        IO.iodata_to_binary(iodata)
    end
  end

  defp if_match(conn) do
    case get_req_header(conn, "if-match") do
      [value | _] ->
        value
        |> String.trim()
        |> String.replace_prefix("W/", "")
        |> String.trim("\"")

      [] ->
        nil
    end
  end

  defp quote_etag(etag), do: ~s("#{etag}")

  defp check_token(conn, _opts) do
    token = conn.path_params["token"]

    if Store.valid_token?(token) do
      assign(conn, :laev_token, token)
    else
      conn |> send_resp(401, "") |> halt()
    end
  end
end
