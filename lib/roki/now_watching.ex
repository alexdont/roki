defmodule Roki.NowWatching do
  @moduledoc """
  Who is in the player right now, for the top of the Featured page's Activity row.

  Kept in memory only: it is a fact about this moment, not history. The watch page reports the
  playhead every few seconds (`report/5`, from `Roki.Watch.record_progress/6`); one entry per
  account, the latest title. An entry is dropped

    * when the page that reported it goes away (the process is monitored — closing the tab, a
      navigation, a lost connection), so a *paused* player that is still open stays listed as
      paused, and one that is closed does not;
    * when a *playing* one has not reported for `@stale_ms` (a page that froze or lost its
      network never says goodbye).

  Every change is broadcast on `topic/0` as `:now_watching`; pages ask `list/0` for the entries.
  Accounts that are for testing are not listed (see `Roki.Activity.silent?/1`).
  """

  use GenServer

  @topic "now_watching"
  @stale_ms 45_000
  @sweep_ms 15_000

  def topic, do: @topic

  def start_link(_), do: GenServer.start_link(__MODULE__, %{}, name: __MODULE__)

  @doc """
  The page `pid` is playing `what` (`Roki.Activity.describe_ctx/1`) at `position` seconds of
  `duration`; `paused?` when it has stopped. Never raises, never waits.
  """
  def report(uuid, pid, what, position, duration, paused?) when is_binary(uuid) do
    if Process.whereis(__MODULE__),
      do: GenServer.cast(__MODULE__, {:report, uuid, pid, what, position, duration, paused?})

    :ok
  end

  @doc "Everyone playing now: `[%{user, username, what, position, duration, paused?, at}]`, newest first."
  def list do
    if Process.whereis(__MODULE__), do: GenServer.call(__MODULE__, :list), else: []
  catch
    :exit, _ -> []
  end

  # ── server ─────────────────────────────────────────────────────────

  @impl true
  def init(_) do
    Process.send_after(self(), :sweep, @sweep_ms)
    {:ok, %{}}
  end

  @impl true
  def handle_cast({:report, uuid, pid, what, position, duration, paused?}, state) do
    if is_nil(state[uuid]) and silent?(uuid) do
      {:noreply, state}
    else
      old = state[uuid]
      ref = if old && old.pid == pid, do: old.ref, else: Process.monitor(pid)
      if old && old.pid != pid, do: Process.demonitor(old.ref, [:flush])

      entry = %{
        user: uuid,
        username: (old && old.username) || username(uuid),
        what: what,
        position: position,
        duration: duration,
        paused?: paused?,
        at: System.monotonic_time(:millisecond),
        pid: pid,
        ref: ref
      }

      changed? =
        is_nil(old) or old.what != what or old.paused? != paused? or
          trunc(old.position) != trunc(position)

      if changed?, do: broadcast()
      {:noreply, Map.put(state, uuid, entry)}
    end
  end

  @impl true
  def handle_call(:list, _from, state) do
    list =
      state
      |> Map.values()
      |> Enum.sort_by(& &1.at, :desc)
      |> Enum.map(&Map.drop(&1, [:pid, :ref]))

    {:reply, list, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _pid, _why}, state) do
    {gone, kept} = Map.split_with(state, fn {_u, e} -> e.ref == ref end)
    if gone != %{}, do: broadcast()
    {:noreply, kept}
  end

  def handle_info(:sweep, state) do
    now = System.monotonic_time(:millisecond)

    {gone, kept} =
      Map.split_with(state, fn {_u, e} -> not e.paused? and now - e.at > @stale_ms end)

    for {_u, e} <- gone, do: Process.demonitor(e.ref, [:flush])
    if gone != %{}, do: broadcast()
    Process.send_after(self(), :sweep, @sweep_ms)
    {:noreply, kept}
  end

  def handle_info(_, state), do: {:noreply, state}

  defp silent?(uuid) do
    Roki.Activity.silent?(uuid)
  rescue
    _ -> false
  end

  defp broadcast, do: Phoenix.PubSub.broadcast(Roki.PubSub, @topic, :now_watching)

  defp username(uuid) do
    with {:ok, bin} <- Ecto.UUID.dump(uuid),
         %{rows: [[name]]} <-
           Roki.Repo.query!(
             "select coalesce(nullif(username, ''), 'someone') from phoenix_kit_users where uuid = $1",
             [bin]
           ) do
      name
    else
      _ -> "someone"
    end
  rescue
    _ -> "someone"
  end
end
