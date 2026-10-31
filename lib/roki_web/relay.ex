defmodule RokiWeb.Relay do
  @moduledoc """
  Bytes of a release passed through as they are, with the browser's `Range` request forwarded:
  for the player that does its own work on the viewer's device (`assets/js/study/local_player.js`)
  when the release's host sends no CORS headers (Real-Debrid), so the browser cannot read it
  directly. No decoding, no file, no buffering beyond a chunk — the server's part is its
  bandwidth. Only a debrid host (or PenguPlay's address) is read from (it is not an open proxy), and only for a link this
  server signed for a signed-in person (`sign/1`, `verify/1`).
  """
  import Plug.Conn

  # `pengu.uk` is PenguPlay's own address: its file links answer with a redirect to wherever the
  # file lives (often a host that sends no CORS headers), which this follows server-side.
  @hosts ~w(real-debrid.com tb-cdn.io torbox.app pengu.uk)
  @salt "release relay"
  @max_age 24 * 3600

  @doc "Whether the browser may read this host directly (it allows cross-origin reads)."
  def direct?(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) ->
        String.ends_with?(host, ".tb-cdn.io") or String.ends_with?(host, "torbox.app")

      _ ->
        false
    end
  end

  @doc "Whether the relay reads from this host at all."
  def allowed?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        Enum.any?(@hosts, &(host == &1 or String.ends_with?(host, "." <> &1)))

      _ ->
        false
    end
  end

  @doc "The address the browser reads a release at: the release's own when its host allows it, else this relay's."
  def url_for(url) when is_binary(url) do
    if direct?(url), do: url, else: "/relay?" <> URI.encode_query(u: url, t: sign(url))
  end

  def sign(url), do: Phoenix.Token.sign(RokiWeb.Endpoint, @salt, url)

  def verify(token, url) do
    case Phoenix.Token.verify(RokiWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, ^url} -> :ok
      _ -> {:error, :bad_token}
    end
  end

  @doc "Stream `url` to the connection, the request's `Range` forwarded, the answer's status and headers kept."
  def stream(conn, url) do
    asked = url
    url = resolved(url)
    headers = for v <- get_req_header(conn, "range"), do: {"range", v}
    Process.put(:relay_conn, nil)

    try do
      resp =
        Req.get!(url,
          headers: headers,
          retry: false,
          redirect: true,
          decode_body: false,
          compressed: false,
          receive_timeout: 60_000,
          into: fn {:data, data}, {req, resp} ->
            c = Process.get(:relay_conn) || open(conn, resp)

            case Plug.Conn.chunk(c, data) do
              {:ok, c} ->
                Process.put(:relay_conn, c)
                {:cont, {req, resp}}

              {:error, _} ->
                {:halt, {req, resp}}
            end
          end
        )

      # A cached address that has gone stale is looked up afresh next time.
      if resp.status >= 400, do: Roki.TTLCache.delete({:relay_final, asked})

      Process.get(:relay_conn) || open(conn, resp)
    rescue
      e -> Process.get(:relay_conn) || send_resp(conn, 502, "upstream: #{Exception.message(e)}")
    end
  end

  # Every read of a file — the first, and each seek outside what is buffered — comes here, and
  # PenguPlay's own address answers slowly (up to a second) just to say where the file is. Where it
  # ended up is kept for two minutes, so only the first read pays for it.
  defp resolved(url) do
    case URI.parse(url) do
      %URI{host: "pengu.uk"} ->
        case Roki.TTLCache.fetch({:relay_final, url}, 120, fn ->
               final = final_url(url, 5)
               if final == url, do: {:error, :unresolved}, else: {:ok, final}
             end) do
          {:ok, final} -> final
          _ -> url
        end

      _ ->
        url
    end
  end

  # A streamed download does not follow redirects, so find where a PenguPlay link ends up first:
  # a one-byte read per hop, the `Location` taken until something answers with bytes.
  defp final_url(url, hops) when hops > 0 do
    case URI.parse(url) do
      %URI{host: "pengu.uk"} ->
        case Req.get(url,
               headers: [{"range", "bytes=0-0"}],
               redirect: false,
               retry: false,
               decode_body: false,
               receive_timeout: 20_000
             ) do
          {:ok, %{status: s} = resp} when s in 301..308 ->
            case resp.headers["location"] do
              [loc | _] -> final_url(to_string(URI.merge(url, loc)), hops - 1)
              _ -> url
            end

          _ ->
            url
        end

      _ ->
        url
    end
  end

  defp final_url(url, _hops), do: url

  defp open(conn, resp) do
    conn
    |> copy_header(resp, "content-type", "video/x-matroska")
    |> copy_header(resp, "content-length")
    |> copy_header(resp, "content-range")
    |> copy_header(resp, "accept-ranges", "bytes")
    |> put_resp_header("cache-control", "private, no-store")
    |> send_chunked(resp.status)
  end

  defp copy_header(conn, resp, name, default \\ nil) do
    case resp.headers[name] do
      [v | _] -> put_resp_header(conn, name, v)
      _ when is_binary(default) -> put_resp_header(conn, name, default)
      _ -> conn
    end
  end
end
