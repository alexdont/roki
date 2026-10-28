defmodule Roki.Releases do
  @moduledoc """
  Tells people when something they saved or follow comes out: a new episode of a show or anime,
  a saved film reaching theaters or digital. Also when a new season gets a date, and on Sundays a
  summary of the week ahead.

  *Saved* is their Saved list; *following* is what they are partway through or caught up on
  (`roki_watched`, status in progress or up to date). Every few hours each connected account's
  release calendar (`Roki.Calendar`: the schedules of all of it, read once for everyone who has
  that title) is looked at, and anything dated today or yesterday goes into their bell
  (`Roki.Social.notify_release/2`). Yesterday as well as today, because a check can be late. Each
  piece of news is told once per person (`roki_release_notified`), so reading the same schedule
  again an hour later says nothing new. Each kind can be switched off (`Roki.Notify`). An account
  whose calendar cannot be read right now (a source is down, the lookup budget is spent) is simply
  tried again at the next round.
  """
  use GenServer
  require Logger

  alias Roki.{Notify, Repo, Social}

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
      told =
        Enum.sum(
          for uuid <- Roki.Warm.accounts(),
              do:
                (
                  Process.sleep(@gap_ms)
                  check(uuid)
                )
        )

      Logger.info("releases: #{told} new notifications")
    end)

    Process.send_after(self(), :check, @every_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Look at one account's calendar and tell them what is out. Returns how many were told."
  def check(uuid, today \\ Date.utc_today()) do
    case Roki.Calendar.load({:releases, uuid}, uuid) do
      {:ok, %{events: saved_events, saved: saved}} ->
        events =
          Enum.sort_by(
            saved_events ++ followed_events(uuid, saved),
            &Date.to_gregorian_days(&1.date)
          )

        notify_due(uuid, events, today) + announce_seasons(uuid, events, today) +
          week_ahead(uuid, events, today)

      _ ->
        0
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
    if Notify.wants?(uuid, "release") do
      events
      |> Enum.filter(&due?(&1, today))
      |> Enum.count(fn event ->
        claim(uuid, event) and Social.notify_release(uuid, notice(event, today)) == :ok
      end)
    else
      0
    end
  end

  # What they follow without having saved: partway through, or caught up with, a show or anime.
  defp followed_events(uuid, saved) do
    %{rows: rows} =
      Repo.query!(
        """
        select distinct tmdb_id, title from roki_watched
         where user_uuid = $1 and tmdb_type = 'tv' and tmdb_id is not null and status in ('progress', 'up_to_date')
        """,
        [Ecto.UUID.dump!(uuid)]
      )

    entries =
      for [id, title] <- rows,
          not Map.has_key?(saved, {"tv", id}),
          do: %{"type" => "tv", "tmdb_id" => id, "title" => title}

    case Roki.Calendar.events_for({:releases, uuid}, uuid, entries) do
      {:ok, events} -> events
      _ -> []
    end
  end

  @doc """
  Tell `uuid` when a season after the first gets its first date and has not started yet
  ("Season 3 of A Show starts Jan 12"). Once per show and season. Returns how many were told.
  """
  def announce_seasons(uuid, events, today \\ Date.utc_today()) do
    if Notify.wants?(uuid, "season") do
      events
      |> Enum.filter(
        &(&1.kind == :episode and &1.type == "tv" and is_integer(&1.season) and &1.season >= 2)
      )
      |> Enum.group_by(&{&1.id, &1.season, &1.title})
      |> Enum.count(fn {{id, season, title}, episodes} ->
        premiere = episodes |> Enum.map(& &1.date) |> Enum.min(Date)

        Date.compare(premiere, today) == :gt and claim(uuid, "tv", id, season, 0, "season") and
          Social.notify_system(
            uuid,
            "season",
            "Season #{season} of #{title} starts #{Calendar.strftime(premiere, "%b %-d")}",
            "hero-calendar-days",
            "/title/tv/#{id}"
          ) == :ok
      end)
    else
      0
    end
  end

  @doc """
  On a Sunday, one summary of the coming week ("Your week ahead: 5 new episodes …"), once per
  week; nothing when nothing is coming. Returns how many were told (0 or 1).
  """
  def week_ahead(uuid, events, today \\ Date.utc_today()) do
    {year, week} = :calendar.iso_week_number(Date.to_erl(today))

    if Date.day_of_week(today) == 7 and Notify.wants?(uuid, "digest") and
         claim(uuid, "digest", year * 100 + week, 0, 0, "digest") do
      coming =
        Enum.filter(
          events,
          &(&1.kind in [:episode, :digital, :theatrical] and Date.diff(&1.date, today) in 1..7)
        )

      episodes = Enum.filter(coming, &(&1.kind == :episode))
      films = coming -- episodes

      if coming == [] do
        0
      else
        username = PhoenixKit.Users.Auth.get_user(uuid) |> then(&(&1 && &1.username))

        if Social.notify_system(
             uuid,
             "digest",
             digest_text(episodes, films),
             "hero-calendar-days",
             if(username, do: "/#{username}/calendar", else: "/")
           ) == :ok,
           do: 1,
           else: 0
      end
    else
      0
    end
  end

  @doc false
  def digest_text(episodes, films) do
    shows = episodes |> Enum.map(& &1.title) |> Enum.uniq()

    names =
      shows
      |> Enum.take(3)
      |> Enum.join(", ")
      |> then(&if(length(shows) > 3, do: &1 <> "…", else: &1))

    parts =
      Enum.reject(
        [
          episodes != [] &&
            "#{length(episodes)} new #{if length(episodes) == 1, do: "episode", else: "episodes"} (#{names})",
          films != [] && "#{length(films)} #{if length(films) == 1, do: "film", else: "films"}"
        ],
        &(&1 == false)
      )

    "Your week ahead: " <> Enum.join(parts, " and ")
  end

  defp due?(%{date: %Date{} = date, kind: kind}, today)
       when kind in [:episode, :digital, :theatrical],
       do: Date.diff(today, date) in 0..1

  defp due?(_event, _today), do: false

  # First to claim an event for a person is the one who tells them.
  defp claim(uuid, event),
    do:
      claim(
        uuid,
        event.type,
        event.id,
        event.season || 0,
        event.episode || 0,
        Atom.to_string(event.kind)
      )

  @doc false
  def claim(uuid, type, id, season, episode, kind) do
    %{num_rows: n} =
      Repo.query!(
        """
        insert into roki_release_notified (user_uuid, type, id, season, episode, kind)
        values ($1, $2, $3, $4, $5, $6) on conflict do nothing
        """,
        [Ecto.UUID.dump!(uuid), type, id, season, episode, kind]
      )

    n == 1
  end

  @doc "What the bell says, and where it goes, for one event: `%{text:, icon:, link:}`."
  def notice(event, today \\ Date.utc_today()) do
    day = if event.date == today, do: "today", else: "yesterday"

    {text, icon} =
      case event.kind do
        :episode ->
          {"New episode of #{event.title}: #{episode(event)} came out #{day}", "hero-play-circle"}

        :theatrical ->
          {"#{event.title} reached theaters #{day}", "hero-film"}

        :digital ->
          {"#{event.title} came out on digital #{day}", "hero-film"}
      end

    %{text: text, icon: icon, link: "/title/#{event.type}/#{event.id}"}
  end

  defp episode(%{season: s, episode: e}) when is_integer(s) and is_integer(e), do: "S#{s}E#{e}"
  defp episode(%{episode: e}) when is_integer(e), do: "episode #{e}"
  defp episode(%{label: label}), do: label
end
