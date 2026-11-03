defmodule Roki.Watch.Trace do
  @moduledoc """
  A trace of finding and starting a release, for following one Play from the click to the
  picture (or to where it went round in circles): one line per step, `<time> [<run>] <what>`, in
  a file of its own — `/var/log/watch-trace.log` (`config :roki, watch_trace:`; nil turns it
  off). `<run>` ties the lines of one search together.

      tail -f /var/log/watch-trace.log

  Its own file, not the logger: laev's application start removes the logger's handlers (it is a
  terminal app, `Laev.Log.install/0`), so nothing reaches the server log from inside this app.
  Cheap (a line appended), so it is always on; the file is cut back when it passes 4 MB.
  """

  @max_bytes 4 * 1024 * 1024

  @doc "One line of the trace for the run `token`."
  def log(token, event, details \\ []) do
    with path when is_binary(path) <-
           Application.get_env(:roki, :watch_trace, "/var/log/watch-trace.log") do
      parts = for {k, v} <- details, v != nil, do: "#{k}=#{fmt(v)}"
      time = DateTime.utc_now() |> DateTime.truncate(:millisecond) |> DateTime.to_iso8601()
      line = Enum.join(["#{time} [#{run(token)}] #{event}" | parts], " ")

      with {:ok, %{size: size}} when size > @max_bytes <- File.stat(path),
           do: File.rename(path, path <> ".1")

      File.write(path, [line, "\n"], [:append])
    end

    :ok
  rescue
    _ -> :ok
  end

  @doc "A release, briefly: its hash's start, resolution and the head of its name."
  def release(%{} = s) do
    name = (s[:name] || s[:title] || "") |> to_string() |> String.slice(0, 60)
    "#{String.slice(to_string(s[:hash] || "?"), 0, 8)}/#{s[:resolution] || "?"}/#{name}"
  end

  def release(other), do: inspect(other)

  def run(nil), do: "-"
  # `{page process, page token}`: the token counts per page, the process tells pages apart.
  def run(token), do: :erlang.phash2(token) |> Integer.to_string(36) |> String.downcase()

  defp fmt(v) when is_binary(v), do: inspect(v)
  defp fmt(v) when is_list(v), do: "[" <> Enum.map_join(v, ",", &fmt_item/1) <> "]"
  defp fmt(v), do: inspect(v, limit: 12, printable_limit: 80)

  defp fmt_item(v) when is_binary(v), do: v
  defp fmt_item(v), do: inspect(v, limit: 6)
end
