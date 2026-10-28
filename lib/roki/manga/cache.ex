defmodule Roki.Manga.Cache do
  @moduledoc """
  The small cache the site scrapers were written against, carried over from the old reader with
  them: a chapter list or a page list for a few hours, keyed by whatever the caller passes.

  It caches what the function returns, errors included — deliberately, so a site that is down
  does not get hammered — and a caller that cares re-asks on the next call.
  """
  use GenServer

  @table __MODULE__

  def start_link(_opts) do
    GenServer.start_link(__MODULE__, [], name: __MODULE__)
  end

  def fetch(key, ttl_ms, fun) do
    now = System.monotonic_time(:millisecond)

    case :ets.whereis(@table) do
      :undefined ->
        fun.()

      _ref ->
        case :ets.lookup(@table, key) do
          [{^key, value, expiry}] when expiry > now ->
            value

          _ ->
            value = fun.()
            :ets.insert(@table, {key, value, now + ttl_ms})
            value
        end
    end
  end

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :public, :set, read_concurrency: true])
    {:ok, %{}}
  end
end
