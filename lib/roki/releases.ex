defmodule Roki.Releases do
  @moduledoc """
  Tells people when something they saved comes out: a new episode of a show or anime on their
  Saved list, a saved film reaching theaters or digital.

  Every few hours each connected account's release calendar (`Roki.Calendar`: the schedules of
  everything they saved, read once for everyone who saved it) is looked at, and anything that is
  dated today or yesterday goes into their bell (`Roki.Social.notify_release/2`). Yesterday as
  well as today, because a check can be late. Each episode or release is told once per person
  (`roki_release_notified`), so reading the same schedule again an hour later says nothing new.
  An account whose calendar cannot be read right now (a source is down, the lookup budget is
  spent) is simply tried again at the next round.
  """
  use GenServer
  require Logger

  alias Roki.{Repo, Social}

  @first_ms 15 * 60 * 1000
  @every_ms 3 * 3600 * 1000
  # Between accounts, so the calendar's lookup budget is not spent in one burst.
  @gap_ms 2_000

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    Process.send_after(self(), :check, @first_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:check, state) do
    # Apart from this process: one account failing must not stop the clock.
    Task.Supervisor.start_child(Roki.TaskSupervisor, fn ->
      told = Enum.sum(for uuid <- Roki.Warm.accounts(), do: (Process.sleep(@gap_ms); check(uuid)))
      Logger.info("releases: #{told} new notifications")
    end)

    Process.send_after(self(), :check, @every_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Look at one account's calendar and tell them what is out. Returns how many were told."
  def check(uuid, today \\ Date.utc_today()) do
    case Roki.Calendar.load({:releases, uuid}, uuid) do
      {:ok, %{events: events}} -> notify_due(uuid, events, today)
      _ -> 0
    end
  rescue
    e ->
      Logger.warning("releases #{uuid}: #{Exception.message(e)}")
      0
  end

  @doc """
  Tell `uuid` about the events (`Roki.Calendar` events) dated today or yesterday that they have
  not been told of. Returns how many were told.
  """
  def notify_due(uuid, events, today \\ Date.utc_today()) do
    events
    |> Enum.filter(&due?(&1, today))
    |> Enum.count(fn event -> claim(uuid, event) and Social.notify_release(uuid, notice(event, today)) == :ok end)
  end

  defp due?(%{date: %Date{} = date, kind: kind}, today) when kind in [:episode, :digital, :theatrical],
    do: Date.diff(today, date) in 0..1

  defp due?(_event, _today), do: false

  # First to claim an event for a person is the one who tells them.
  defp claim(uuid, event) do
    %{num_rows: n} =
      Repo.query!(
        """
        insert into roki_release_notified (user_uuid, type, id, season, episode, kind)
        values ($1, $2, $3, $4, $5, $6) on conflict do nothing
        """,
        [Ecto.UUID.dump!(uuid), event.type, event.id, event.season || 0, event.episode || 0, Atom.to_string(event.kind)]
      )

    n == 1
  end

  @doc "What the bell says, and where it goes, for one event: `%{text:, icon:, link:}`."
  def notice(event, today \\ Date.utc_today()) do
    day = if event.date == today, do: "today", else: "yesterday"

    {text, icon} =
      case event.kind do
        :episode -> {"New episode of #{event.title}: #{episode(event)} came out #{day}", "hero-play-circle"}
        :theatrical -> {"#{event.title} reached theaters #{day}", "hero-film"}
        :digital -> {"#{event.title} came out on digital #{day}", "hero-film"}
      end

    %{text: text, icon: icon, link: "/title/#{event.type}/#{event.id}"}
  end

  defp episode(%{season: s, episode: e}) when is_integer(s) and is_integer(e), do: "S#{s}E#{e}"
  defp episode(%{episode: e}) when is_integer(e), do: "episode #{e}"
  defp episode(%{label: label}), do: label
end
