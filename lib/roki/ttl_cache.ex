defmodule Roki.TTLCache do
  @moduledoc """
  A small in-memory cache with an expiry per entry and a hard size cap, for
  answers that cost an upstream request: search pages, TMDB collections.

  `fetch/3` is single-flight — if several people ask for the same cold key at
  once, one computes it and the rest wait for that answer instead of each making
  the same request. Only `{:ok, _}` results are kept, so a TMDB hiccup is never
  remembered. Entries live in ETS (reads never touch the owning process); a
  sweep each minute drops the expired and, past `@max` entries, the soonest to
  expire — so a stream of unique queries cannot grow memory without bound.
  """
  use GenServer

  @table __MODULE__
  @max 2_000
  @sweep_ms 60_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @doc "The cached `{:ok, value}` for `key`, else compute it with `fun` (kept `ttl_s` seconds when it is `{:ok, _}`)."
  def fetch(key, ttl_s, fun) when is_function(fun, 0) do
    case lookup(key) do
      {:ok, _} = hit ->
        hit

      :miss ->
        :global.trans({{__MODULE__, key}, self()}, fn ->
          case lookup(key) do
            {:ok, _} = hit ->
              hit

            :miss ->
              case fun.() do
                {:ok, _} = ok ->
                  :ets.insert(@table, {key, now() + ttl_s, ok})
                  ok

                other ->
                  other
              end
          end
        end)
    end
  end

  @doc "Is a live answer held for `key`? (Never computes.)"
  def cached?(key), do: match?({:ok, _}, lookup(key))

  defp lookup(key) do
    case :ets.lookup(@table, key) do
      [{^key, expires, value}] -> if expires > now(), do: value, else: :miss
      [] -> :miss
    end
  end

  @doc "Number of entries held (expired ones included until the next sweep)."
  def size, do: :ets.info(@table, :size)

  @doc false
  def clear, do: :ets.delete_all_objects(@table)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, read_concurrency: true])
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:sweep, state) do
    sweep()
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, state}
  end

  @doc false
  def sweep(max \\ @max) do
    cutoff = now()
    :ets.select_delete(@table, [{{:_, :"$1", :_}, [{:"=<", :"$1", cutoff}], [true]}])

    excess = :ets.info(@table, :size) - max

    if excess > 0 do
      @table
      |> :ets.select([{{:"$1", :"$2", :_}, [], [{{:"$2", :"$1"}}]}])
      |> Enum.sort()
      |> Enum.take(excess)
      |> Enum.each(fn {_expires, key} -> :ets.delete(@table, key) end)
    end

    :ok
  end

  defp now, do: System.system_time(:second)
end
