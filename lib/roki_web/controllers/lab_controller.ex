defmodule RokiWeb.LabController do
  @moduledoc """
  The player lab (`/lab/player.html`): an experiment in the browser doing everything — pulling
  the release itself, demuxing it, and putting it into a form its own media engine plays, with
  the server doing nothing (or, for a host that forbids cross-origin reads, relaying bytes and
  nothing more). For the site's owner only; nothing here is part of the site yet.
  """
  use RokiWeb, :controller

  @samples %{"h264" => "test-h264.mkv", "eac3" => "test-eac3.mkv", "vp9" => "test-vp9.mkv"}
  @sample_dir "/tmp/lab"
  # Hosts the relay will read from: the debrid services' download servers, nothing else (it is
  # not an open proxy).
  @hosts ~w(real-debrid.com tb-cdn.io torbox.app)

  @doc "A test file made with ffmpeg, served with byte ranges as a debrid host would."
  def sample(conn, %{"name" => name}) do
    # The three made ones by their short names; any other `.mkv` the operator put in the lab's
    # directory (pieces of real releases) by its file name.
    file = @samples[name] || (Regex.match?(~r/^[a-z0-9._-]+$/i, name) and "#{name}.mkv")

    with :ok <- owner(conn),
         true <-
           (is_binary(file) and File.exists?(Path.join(@sample_dir, file))) ||
             {:error, :not_found} do
      Fmp4.RangeFile.send(conn, Path.join(@sample_dir, file), "video/x-matroska")
    else
      {:error, :forbidden} -> send_resp(conn, 403, "owner only")
      _ -> send_resp(conn, 404, "no such sample")
    end
  end

  @doc """
  Bytes of a release, as they are, with the browser's `Range` passed through: for a host that
  sends no CORS headers (Real-Debrid), so the browser can still read it directly. No decoding,
  no buffering beyond a chunk; the server's part is its bandwidth.
  """
  def bytes(conn, %{"u" => url}) do
    with :ok <- owner(conn), true <- allowed?(url) || {:error, :host} do
      range = get_req_header(conn, "range")
      headers = for v <- range, do: {"range", v}
      Process.put(:lab_conn, nil)

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
              c = Process.get(:lab_conn) || open(conn, resp)

              case Plug.Conn.chunk(c, data) do
                {:ok, c} ->
                  Process.put(:lab_conn, c)
                  {:cont, {req, resp}}

                {:error, _} ->
                  {:halt, {req, resp}}
              end
            end
          )

        Process.get(:lab_conn) || open(conn, resp)
      rescue
        e ->
          if Process.get(:lab_conn),
            do: Process.get(:lab_conn),
            else: send_resp(conn, 502, "upstream: #{Exception.message(e)}")
      end
    else
      {:error, :forbidden} -> send_resp(conn, 403, "owner only")
      {:error, :host} -> send_resp(conn, 400, "not a debrid host")
    end
  end

  def bytes(conn, _params), do: send_resp(conn, 400, "u= missing")

  @doc "The automatic run's report from a device, kept (`roki_kept`, kind `lab-report`) to be read here."
  def report(conn, params) do
    with :ok <- owner(conn) do
      id =
        "#{System.os_time(:second)}-#{:crypto.strong_rand_bytes(3) |> Base.encode16(case: :lower)}"

      Roki.Kept.put(
        "lab-report",
        id,
        Map.take(params, ~w(at ua platform width height managedMediaSource caps results))
      )

      json(conn, %{id: id})
    else
      _ -> send_resp(conn, 403, "owner only")
    end
  end

  @doc "Real releases to run (fresh debrid links put in `/tmp/lab/links.json` by the operator)."
  def links(conn, _params) do
    with :ok <- owner(conn) do
      case File.read(Path.join(@sample_dir, "links.json")) do
        {:ok, json} -> conn |> put_resp_content_type("application/json") |> send_resp(200, json)
        _ -> json(conn, [])
      end
    else
      _ -> send_resp(conn, 403, "owner only")
    end
  end

  @doc "The last reports, newest first."
  def reports(conn, params) do
    with :ok <- owner(conn) do
      n = min(String.to_integer(params["n"] || "5"), 50)

      rows =
        Roki.Repo.query!(
          "select key, data, fetched_at from roki_kept where kind = 'lab-report' order by fetched_at desc limit $1",
          [n]
        ).rows
        |> Enum.map(fn [key, data, at] ->
          %{id: key, at: at, report: if(is_binary(data), do: Jason.decode!(data), else: data)}
        end)

      json(conn, rows)
    else
      _ -> send_resp(conn, 403, "owner only")
    end
  end

  # The upstream answer's status and the headers a player needs, then chunks.
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

  defp allowed?(url) do
    case URI.parse(url) do
      %URI{scheme: "https", host: host} when is_binary(host) ->
        Enum.any?(@hosts, &(host == &1 or String.ends_with?(host, "." <> &1)))

      _ ->
        false
    end
  end

  defp owner(conn) do
    user = conn.assigns[:phoenix_kit_current_user]
    owner = Roki.Media.owner_uuid()
    if user && owner && user.uuid == owner, do: :ok, else: {:error, :forbidden}
  end
end
