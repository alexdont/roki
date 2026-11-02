defmodule RokiWeb.NuvioController do
  @moduledoc """
  The Nuvio playback bridge.

  `/relay/nuvio?u=&t=` passes a file's bytes through the same relay the debrid player uses,
  with the request headers the provider required. `/nuvio/hls?u=&t=` fetches a playlist and
  rewrites every URI in it to a signed URL on this server, so a playlist that needs a
  `Referer`, a cookie or an `Origin` plays in a browser that cannot set one. Keys and init
  segments are passed through as they are; DRM is not touched, and a stream that needs a
  licence this server cannot obtain simply fails to play.
  """
  use RokiWeb, :controller

  alias RokiWeb.Relay

  def hls(conn, %{"u" => url, "t" => token}) do
    with {:ok, %{url: ^url, headers: headers}} <- Relay.nuvio_verify(token),
         {:ok, body, final} <- Relay.fetch_text(url, headers) do
      conn
      |> put_resp_content_type("application/vnd.apple.mpegurl")
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, rewrite(body, final, headers))
    else
      {:error, :bad_token} -> send_resp(conn, 403, "bad or old link")
      {:error, :blocked_url} -> send_resp(conn, 400, "not a public stream")
      {:error, reason} -> send_resp(conn, 502, "playlist: #{inspect(reason, limit: 2)}")
      _ -> send_resp(conn, 400, "u= and t= needed")
    end
  end

  def hls(conn, _params), do: send_resp(conn, 400, "u= and t= needed")

  @doc false
  # Every URI in a playlist goes back through this server. A child playlist goes through the
  # HLS endpoint (so its own URIs are rewritten too); a segment, key or init segment goes
  # through the byte relay.
  def rewrite(body, base, headers) when is_binary(body) do
    body
    |> String.split("\n")
    |> Enum.map(&rewrite_line(String.trim_trailing(&1, "\r"), base, headers))
    |> Enum.join("\n")
  end

  defp rewrite_line("", _base, _headers), do: ""

  defp rewrite_line("#" <> _ = line, base, headers) do
    if String.contains?(line, ~s(URI=")),
      do: rewrite_uri_attr(line, base, headers),
      else: line
  end

  defp rewrite_line(uri, base, headers) do
    absolute = base |> URI.merge(uri) |> URI.to_string()

    if playlist?(absolute) do
      hls_url(absolute, headers)
    else
      Relay.nuvio_url(absolute, headers)
    end
  end

  defp rewrite_uri_attr(line, base, headers) do
    Regex.replace(~r/URI="([^"]+)"/, line, fn _, uri ->
      absolute = base |> URI.merge(uri) |> URI.to_string()

      target =
        if playlist?(absolute),
          do: hls_url(absolute, headers),
          else: Relay.nuvio_url(absolute, headers)

      ~s(URI="#{target}")
    end)
  end

  defp playlist?(url) do
    uri = URI.parse(url)
    String.contains?(uri.path || "", "m3u8") or String.contains?(uri.query || "", "m3u8")
  end

  @doc "A signed address for a Nuvio HLS playlist, headers included in the token."
  def hls_url(url, headers) do
    "/nuvio/hls?" <> URI.encode_query(u: url, t: Relay.nuvio_sign(url, headers))
  end
end
