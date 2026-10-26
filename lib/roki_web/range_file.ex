defmodule RokiWeb.RangeFile do
  @moduledoc """
  Serves a file to a video element with HTTP range requests, including a file that is still
  being written.

  A browser plays a plain MP4 by asking for byte ranges (Safari starts with `bytes=0-1` to learn
  the size), so a file has to answer `206` with `Content-Range`. A file still growing has no
  total yet: its ranges are answered with `*` for the total, and a request past what exists so
  far waits a little for the writer to catch up before giving up with `416`.
  """
  import Plug.Conn

  @wait_ms 20_000
  @chunk 1_048_576

  def send(conn, path, content_type, opts \\ []) do
    growing? = Keyword.get(opts, :growing?, false)
    size = file_size(path)

    conn =
      conn
      |> put_resp_content_type(content_type)
      |> put_resp_header("accept-ranges", "bytes")
      |> put_resp_header("cache-control", "no-store")

    case range(get_req_header(conn, "range"), size) do
      nil when growing? ->
        # No range asked: the whole file, as it grows, without a length.
        conn |> send_chunked(200) |> stream_from(path, 0, nil)

      nil ->
        send_file(conn, 200, path)

      {from, to} ->
        {from, to, size} = clamp(path, from, to, size, growing?)

        if from == nil do
          conn
          |> put_resp_header("content-range", "bytes */#{if growing?, do: "*", else: size}")
          |> send_resp(416, "")
        else
          total = if growing?, do: "*", else: Integer.to_string(size)

          conn
          |> put_resp_header("content-range", "bytes #{from}-#{to}/#{total}")
          |> put_resp_header("content-length", Integer.to_string(to - from + 1))
          |> send_file(206, path, from, to - from + 1)
        end
    end
  end

  defp file_size(path) do
    case File.stat(path) do
      {:ok, %{size: size}} -> size
      _ -> 0
    end
  end

  # `bytes=a-b`, `bytes=a-`, `bytes=-n` → `{from, to}` with `to` possibly past the end.
  defp range([header | _], size) do
    case Regex.run(~r/^bytes=(\d*)-(\d*)$/, header) do
      [_, "", n] when n != "" -> {max(size - String.to_integer(n), 0), size - 1}
      [_, a, ""] -> {String.to_integer(a), nil}
      [_, a, b] -> {String.to_integer(a), String.to_integer(b)}
      _ -> nil
    end
  end

  defp range(_, _size), do: nil

  # A finished file answers what it has. A growing one is asked for a part not written yet now
  # and then; the writer is given a little time before the request fails.
  defp clamp(path, from, to, size, growing?) do
    cond do
      from < size ->
        # A growing file is answered a piece at a time, so the browser asks again as it fills.
        top = if growing?, do: min(size - 1, from + @chunk - 1), else: size - 1
        {from, min(to || top, top), size}

      growing? ->
        wait_for(path, from, System.monotonic_time(:millisecond) + @wait_ms)
        |> case do
          {:ok, size} -> clamp(path, from, to, size, true)
          :timeout -> {nil, nil, size}
        end

      true ->
        {nil, nil, size}
    end
  end

  defp wait_for(path, from, deadline) do
    size = file_size(path)

    cond do
      size > from -> {:ok, size}
      System.monotonic_time(:millisecond) > deadline -> :timeout
      true -> Process.sleep(200) && wait_for(path, from, deadline)
    end
  end

  defp stream_from(conn, path, pos, _until) do
    size = file_size(path)

    cond do
      pos < size ->
        {:ok, f} = File.open(path, [:read, :binary])
        {:ok, data} = :file.pread(f, pos, min(size - pos, @chunk))
        File.close(f)

        case chunk(conn, data) do
          {:ok, conn} -> stream_from(conn, path, pos + byte_size(data), nil)
          {:error, _} -> conn
        end

      true ->
        conn
    end
  end
end
