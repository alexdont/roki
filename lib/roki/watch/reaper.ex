defmodule Roki.Watch.Reaper do
  @moduledoc """
  Stops conversions nobody is watching. laev's remux worker keeps ffmpeg running for two hours
  whatever happens to the page, and a re-encode of a 4K release takes every core the whole time:
  a closed tab, or a video that never became ready, left it burning.

  `touch/1` is called each time the stream controller serves a file of a conversion; every minute
  the ones not asked for in ten are stopped (their finished segments stay on disk as a cache).
  """
  use GenServer

  @table __MODULE__
  @every :timer.minutes(1)
  @idle_s 10 * 60

  def start_link(_), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "A conversion was just asked for."
  def touch(id) do
    :ets.insert(@table, {id, System.monotonic_time(:second)})
    :ok
  rescue
    ArgumentError -> :ok
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set])
    Process.send_after(self(), :sweep, @every)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    now = System.monotonic_time(:second)

    for id <- running() do
      case :ets.lookup(@table, id) do
        # First seen: the clock starts now, so a conversion that just began is never cut short.
        [] -> :ets.insert(@table, {id, now})
        [{_, at}] when now - at > @idle_s -> stop(id)
        _ -> :ok
      end
    end

    Process.send_after(self(), :sweep, @every)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp stop(id) do
    Laev.Remux.stop(id)
    :ets.delete(@table, id)
  end

  defp running do
    Registry.select(Laev.Remux.Registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  rescue
    _ -> []
  end
end
