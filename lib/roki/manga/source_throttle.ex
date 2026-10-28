defmodule Roki.Manga.SourceThrottle do
  @moduledoc """
  Per-source-per-user rate limiting for outgoing API calls.
  The GenServer only enforces delay between requests — actual API calls
  run in the caller's process so slow responses don't block the queue.
  """

  use GenServer

  @delays %{"mangalib" => 1500, "default" => 500}
  @idle_timeout :timer.minutes(5)

  def start_link({source, _user_id} = key) do
    GenServer.start_link(__MODULE__, source, name: via(key))
  end

  def throttled_fetch(source, user_id, cache_key, ttl, fun) do
    case Roki.Manga.Cache.fetch(cache_key, ttl, fn -> :miss end) do
      :miss ->
        key = {source, user_id}
        ensure_started(key)
        :ok = GenServer.call(via(key), :acquire, 30_000)

        # Re-check cache after acquiring (another request may have populated it while queued)
        case Roki.Manga.Cache.fetch(cache_key, ttl, fn -> :miss end) do
          :miss ->
            result = fun.()

            case result do
              {:ok, _} = ok ->
                now = System.monotonic_time(:millisecond)
                :ets.insert(Roki.Manga.Cache, {cache_key, ok, now + ttl})

              _ ->
                :ok
            end

            result

          cached ->
            cached
        end

      cached ->
        cached
    end
  end

  defp via(key), do: {:via, Registry, {__MODULE__.Registry, key}}

  defp ensure_started(key) do
    case Registry.lookup(__MODULE__.Registry, key) do
      [{_pid, _}] ->
        :ok

      [] ->
        DynamicSupervisor.start_child(
          __MODULE__.Supervisor,
          {__MODULE__, key}
        )

        :ok
    end
  end

  @impl true
  def init(source) do
    {:ok, %{source: source, last_request: System.monotonic_time(:millisecond) - 5000}, @idle_timeout}
  end

  @impl true
  def handle_call(:acquire, _from, state) do
    state = enforce_delay(state)
    {:reply, :ok, state, @idle_timeout}
  end

  @impl true
  def handle_info(:timeout, state) do
    {:stop, :normal, state}
  end

  defp enforce_delay(%{source: source, last_request: last} = state) do
    delay = Map.get(@delays, source, @delays["default"])
    now = System.monotonic_time(:millisecond)
    wait = delay - (now - last)
    if wait > 0, do: :timer.sleep(wait)

    %{state | last_request: System.monotonic_time(:millisecond)}
  end
end
