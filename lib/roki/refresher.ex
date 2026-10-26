defmodule Roki.Refresher do
  @moduledoc """
  Keeps the site's own copies current without a page having to: ten minutes after the server
  starts, and every six hours after that, every connected account is warmed (`Roki.Warm`) —
  new finished titles into the table, ratings copied from TMDB and MyAnimeList, titles,
  seasons, recommendations and pictures kept for anything new. A profile or a title page then
  only ever reads what is here; the outside is asked in the background, on this clock.
  """
  use GenServer
  require Logger

  @first_ms 10 * 60 * 1000
  @every_ms 6 * 3600 * 1000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    Process.send_after(self(), :warm, @first_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:warm, state) do
    # Apart from this process: a failure in one account's copy must not stop the clock.
    Task.Supervisor.start_child(Roki.TaskSupervisor, fn ->
      results = Roki.Warm.all()
      Logger.info("refresher: #{length(results)} accounts warmed")
    end)

    Process.send_after(self(), :warm, @every_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}
end
