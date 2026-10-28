defmodule RokiWeb.KotatsuProxyController do
  @moduledoc """
  Streams chapter-page images from the kotatsu sidecar to the
  browser: browser → this route → sidecar `/sources/:name/image` →
  source CDN. The sidecar leg carries the parser's Referer/cookie
  headers (many manga CDNs 403 hotlinked requests), so reader `<img>`
  tags must point HERE, never at upstream CDN URLs.
  """
  use RokiWeb, :controller

  alias Roki.Manga.MangaSource.Kotatsu

  def image(conn, %{"source" => source, "url" => url})
      when is_binary(source) and is_binary(url) do
    result =
      Kotatsu.base_request()
      |> Req.Request.put_private(:plug_conn, conn)
      |> Req.get(
        url: "/sources/#{URI.encode(source)}/image",
        params: [url: url],
        receive_timeout: 60_000,
        into: &stream_chunk/2
      )

    case result do
      {:ok, %Req.Response{} = resp} ->
        case Req.Response.get_private(resp, :conn) do
          %Plug.Conn{} = streamed ->
            streamed

          _ ->
            if resp.status == 200 do
              # 200 with an empty body — nothing was streamed.
              send_resp(conn, 200, "")
            else
              conn |> put_status(502) |> json(%{error: "upstream image fetch failed"})
            end
        end

      {:error, _reason} ->
        conn |> put_status(502) |> json(%{error: "manga source backend unreachable"})
    end
  end

  def image(conn, _params) do
    conn |> put_status(400) |> json(%{error: "source and url are required"})
  end

  # Req streaming callback: on the first chunk of a 200, open the
  # chunked response with the upstream content type and a long cache
  # lifetime (page image URLs are stable); then feed chunks through.
  # Non-200 upstream halts so the outer clause can respond 502.
  defp stream_chunk({:data, data}, {req, resp}) do
    case Req.Response.get_private(resp, :conn) || init_conn(req, resp) do
      :error ->
        {:halt, {req, resp}}

      %Plug.Conn{} = conn ->
        case Plug.Conn.chunk(conn, data) do
          {:ok, conn} -> {:cont, {req, Req.Response.put_private(resp, :conn, conn)}}
          {:error, _} -> {:halt, {req, Req.Response.put_private(resp, :conn, conn)}}
        end
    end
  end

  defp init_conn(req, resp) do
    if resp.status == 200 do
      content_type =
        resp
        |> Req.Response.get_header("content-type")
        |> List.first() || "image/jpeg"

      req
      |> Req.Request.get_private(:plug_conn)
      |> Plug.Conn.put_resp_header("content-type", content_type)
      |> Plug.Conn.put_resp_header("cache-control", "public, max-age=604800, immutable")
      |> Plug.Conn.send_chunked(200)
    else
      :error
    end
  end
end
