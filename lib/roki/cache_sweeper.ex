defmodule Roki.CacheSweeper do
  @moduledoc """
  Keeps the conversion cache short-lived. laev keeps a finished conversion for a day so a replay
  reuses it, and an evening of browser viewing leaves tens of gigabytes behind; with 4K copied
  as it is, a few films would fill the cluster. This sweeps every quarter hour and removes any
  conversion nobody has fetched for six hours (laev and the stream route bump the directory's
  time on every request, so a film being watched is never older than its last segment).

  A conversion still running (laev's, or `Roki.Direct`'s) is left alone whatever its age.
  """
  use GenServer
  require Logger

  @ttl_s 6 * 60 * 60
  @every_ms 15 * 60 * 1000

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    Process.send_after(self(), :sweep, :timer.minutes(1))
    {:ok, %{}}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, @every_ms)
    {:noreply, state}
  end

  @doc "Where laev (and `Roki.Direct`) write conversions."
  def base, do: Path.join(System.tmp_dir!(), "realdebrid_remux")

  @doc """
  Remove the conversions under `base` not fetched for `ttl_s` seconds and not running.
  Returns `{removed, bytes}`.
  """
  def sweep(base \\ base(), ttl_s \\ @ttl_s, running \\ running()) do
    now = System.os_time(:second)

    result =
      case File.ls(base) do
        {:ok, ids} ->
          ids
          |> Enum.filter(fn id ->
            id not in running and now - last_fetch(Path.join(base, id)) > ttl_s
          end)
          |> Enum.reduce({0, 0}, fn id, {n, bytes} ->
            dir = Path.join(base, id)
            size = dir_size(dir)
            File.rm_rf(dir)
            {n + 1, bytes + size}
          end)

        _ ->
          {0, 0}
      end

    case result do
      {0, _} ->
        :ok

      {n, bytes} ->
        Logger.info("cache sweep: removed #{n} conversions, #{div(bytes, 1_000_000)} MB")
    end

    result
  end

  defp running, do: Laev.Remux.running() ++ Direct.running()

  # The same clock laev reads: the playlist marker when there is one, else the directory.
  defp last_fetch(dir) do
    Enum.find_value([Path.join(dir, "index.m3u8"), dir], System.os_time(:second), fn path ->
      case File.stat(path, time: :posix) do
        {:ok, %{mtime: m}} -> m
        _ -> nil
      end
    end)
  end

  defp dir_size(dir) do
    case File.ls(dir) do
      {:ok, names} ->
        Enum.reduce(names, 0, fn name, acc ->
          case File.stat(Path.join(dir, name)) do
            {:ok, %{size: s, type: :regular}} -> acc + s
            _ -> acc
          end
        end)

      _ ->
        0
    end
  end
end
