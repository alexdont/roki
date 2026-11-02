defmodule RokiWeb.Relay do
  @moduledoc """
  Bytes of a release passed through as they are, with the browser's `Range` request forwarded:
  for the player that does its own work on the viewer's device (`assets/js/study/local_player.js`)
  when the release's host sends no CORS headers (Real-Debrid), so the browser cannot read it
  directly. No decoding, no file, no buffering beyond a chunk — the server's part is its
  bandwidth.

  Two scopes of link exist, both signed by this server and both readable only by a signed-in
  person:

    * the original debrid/PenguPlay scope, restricted to the hosts in `@hosts`;
    * the Nuvio scope (`nuvio_url/2`), for a public HTTPS URL a validated Nuvio provider
      returned. It carries the headers that stream needs, and is checked against private,
      loopback and link-local addresses before anything is fetched.

  Redirects are followed here, one hop at a time, so a signed public link cannot redirect the
  server into its own network. Neither scope is an open proxy: `u` and `t` must both be
  present, match each other, and the token must be one this server signed recently.
  """
  import Plug.Conn

  # `pengu.uk` is PenguPlay's own address: its file links answer with a redirect to wherever the
  # file lives (often a host that sends no CORS headers), which this follows server-side.
  @hosts ~w(real-debrid.com tb-cdn.io torbox.app pengu.uk)
  @salt "release relay"
  @nuvio_salt "nuvio release relay"
  @max_age 24 * 3600
  @max_redirects 5

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

  # ── the Nuvio scope ────────────────────────────────────────────────

  @doc "A signed relay address for a public Nuvio stream, carrying its request headers."
  def nuvio_url(url, headers) when is_binary(url) do
    "/relay/nuvio?" <> URI.encode_query(u: url, t: nuvio_sign(url, headers))
  end

  def nuvio_sign(url, headers) do
    Phoenix.Token.sign(RokiWeb.Endpoint, @nuvio_salt, %{
      "u" => url,
      "h" => sanitize_headers(headers)
    })
  end

  @doc "Verify a Nuvio relay token: `{:ok, %{url:, headers:}}` or `{:error, reason}`."
  def nuvio_verify(token) do
    case Phoenix.Token.verify(RokiWeb.Endpoint, @nuvio_salt, token, max_age: @max_age) do
      {:ok, %{"u" => url, "h" => headers}} ->
        {:ok, %{url: url, headers: sanitize_headers(headers)}}

      {:ok, _} ->
        {:error, :bad_token}

      _ ->
        {:error, :bad_token}
    end
  end

  @doc "Whether a URL is a public HTTPS address (the Nuvio relay's precondition)."
  def public_https?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) and host != "" ->
        not Roki.Nuvio.private_host?(host) and dns_safe?(host)

      _ ->
        false
    end
  end

  # A literal check stops `127.0.0.1`; this stops a public name that resolves into the
  # server's own network. The answer is cached briefly, so a playlist's many segments do not
  # each pay for a lookup.
  defp dns_safe?(host) do
    case Roki.TTLCache.fetch({:relay_dns, host}, 60, fn ->
           {:ok, resolve_safe?(host)}
         end) do
      {:ok, safe} -> safe
      _ -> true
    end
  end

  defp resolve_safe?(host) do
    charlist = String.to_charlist(host)

    addrs =
      case :inet.getaddrs(charlist, :inet) do
        {:ok, list} -> list
        _ -> []
      end ++
        case :inet.getaddrs(charlist, :inet6) do
          {:ok, list} -> list
          _ -> []
        end

    addrs == [] or Enum.all?(addrs, &public_ip?/1)
  end

  defp public_ip?({a, b, _c, _d}) do
    not (a in [0, 10, 127] or (a == 169 and b == 254) or (a == 172 and b in 16..31) or
           (a == 192 and b == 168) or (a == 100 and b in 64..127))
  end

  defp public_ip?({0, 0, 0, 0, 0, 0, 0, 1}), do: false
  defp public_ip?({0xFC00, _, _, _, _, _, _, _}), do: false
  defp public_ip?({0xFD00, _, _, _, _, _, _, _}), do: false
  defp public_ip?({0xFE80, _, _, _, _, _, _, _}), do: false
  defp public_ip?(_), do: true

  defp sanitize_headers(headers) when is_map(headers) do
    headers
    |> Enum.filter(fn {k, v} ->
      is_binary(k) and is_binary(v) and
        String.downcase(k) not in ~w(host content-length connection transfer-encoding upgrade keep-alive cookie authorization proxy-authorization) and
        byte_size(v) <= 2_000 and
        not String.contains?(k, ["\n", "\r"]) and not String.contains?(v, ["\n", "\r"])
    end)
    |> Enum.take(30)
    |> Map.new()
  end

  defp sanitize_headers(_), do: %{}

  @doc "Stream `url` to the connection, the request's `Range` forwarded, the answer's status and headers kept."
  def stream(conn, url), do: stream(conn, url, %{})

  def stream(conn, url, headers) do
    Process.put(:relay_conn, nil)
    stream_follow(conn, resolved(url), sanitize_headers(headers), @max_redirects)
  end

  defp stream_follow(conn, url, headers, hops) do
    if hops < 0 or not public_https?(url) do
      send_resp(conn, 502, "upstream redirect blocked")
    else
      range = for v <- get_req_header(conn, "range"), do: {"range", v}

      resp =
        Req.get!(url,
          headers: header_list(headers) ++ range,
          retry: false,
          redirect: false,
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

      cond do
        resp.status in 301..308 and hops > 0 ->
          case resp.headers["location"] do
            [loc | _] ->
              next = url |> URI.merge(loc) |> URI.to_string()
              stream_follow(conn, next, headers, hops - 1)

            _ ->
              Process.get(:relay_conn) || open(conn, resp)
          end

        resp.status >= 400 ->
          Roki.TTLCache.delete({:relay_final, url})
          Process.get(:relay_conn) || open(conn, resp)

        true ->
          Process.get(:relay_conn) || open(conn, resp)
      end
    end
  rescue
    e -> Process.get(:relay_conn) || send_resp(conn, 502, "upstream: #{Exception.message(e)}")
  end

  @doc """
  Fetch a playlist (or any small text resource) for the Nuvio HLS proxy, following public
  redirects one hop at a time. `{:ok, body, final_url}` or `{:error, reason}`.
  """
  def fetch_text(url, headers, hops \\ 3) do
    with true <- hops >= 0,
         true <- public_https?(url),
         {:ok, %{status: status} = resp} <-
           Req.get(url,
             headers: header_list(sanitize_headers(headers)),
             retry: false,
             redirect: false,
             decode_body: false,
             compressed: false,
             receive_timeout: 20_000
           ) do
      cond do
        status in 301..308 ->
          case resp.headers["location"] do
            [loc | _] -> fetch_text(url |> URI.merge(loc) |> URI.to_string(), headers, hops - 1)
            _ -> {:error, :bad_redirect}
          end

        status == 200 and is_binary(resp.body) and byte_size(resp.body) <= 4_000_000 ->
          {:ok, resp.body, url}

        status == 200 ->
          {:error, :playlist_too_large}

        true ->
          {:error, {:http, status}}
      end
    else
      false -> {:error, :blocked_url}
      {:error, reason} -> {:error, reason}
      _ -> {:error, :bad_answer}
    end
  end

  defp header_list(headers), do: Enum.map(headers, fn {k, v} -> {k, v} end)

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
