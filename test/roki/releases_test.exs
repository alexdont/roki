defmodule Roki.ReleasesTest do
  use Roki.DataCase, async: false

  alias Roki.Releases

  @today ~D[2026-10-27]

  defp register(username) do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "#{username}@example.com",
        "password" => "a-long-enough-password-123",
        "username" => username
      })

    user
  end

  defp event(kind, days_ago, extra) do
    Map.merge(
      %{
        date: Date.add(@today, -days_ago),
        kind: kind,
        label: "x",
        type: "tv",
        id: 4242,
        title: "A Show",
        season: nil,
        episode: nil,
        anime: false
      },
      extra
    )
  end

  defp bell(user),
    do:
      for(
        n <- PhoenixKit.Notifications.recent_for_user(user.uuid, 20),
        do: PhoenixKit.Notifications.Render.render(n)
      )

  test "the words and the link of each kind of release" do
    assert %{
             text: "New episode of A Show: S2E5 came out today",
             link: "/title/tv/4242",
             icon: "hero-play-circle"
           } =
             Releases.notice(event(:episode, 0, %{season: 2, episode: 5}), @today)

    assert Releases.notice(event(:episode, 1, %{episode: 6, anime: true}), @today).text ==
             "New episode of A Show: episode 6 came out yesterday"

    assert %{text: "A Film reached theaters today", link: "/title/movie/9"} =
             Releases.notice(
               event(:theatrical, 0, %{type: "movie", id: 9, title: "A Film"}),
               @today
             )

    assert Releases.notice(event(:digital, 1, %{type: "movie", id: 9, title: "A Film"}), @today).text ==
             "A Film came out on digital yesterday"
  end

  test "what is dated today or yesterday is told; older, and not yet out, is not" do
    user = register("releasefan")

    events = [
      event(:episode, 0, %{season: 1, episode: 1}),
      event(:episode, 1, %{season: 1, episode: 2}),
      event(:episode, 2, %{season: 1, episode: 3}),
      event(:episode, -1, %{season: 1, episode: 4})
    ]

    assert Releases.notify_due(user.uuid, events, @today) == 2

    assert bell(user) |> Enum.map(& &1.text) |> Enum.sort() == [
             "New episode of A Show: S1E1 came out today",
             "New episode of A Show: S1E2 came out yesterday"
           ]
  end

  test "each release is told once to each person, however often the schedule is read" do
    ann = register("releaseann")
    bob = register("releasebob")
    events = [event(:episode, 0, %{season: 3, episode: 9})]

    assert Releases.notify_due(ann.uuid, events, @today) == 1
    assert Releases.notify_due(ann.uuid, events, @today) == 0
    # The same episode is news for another person who saved the show.
    assert Releases.notify_due(bob.uuid, events, @today) == 1
    assert length(bell(ann)) == 1
    assert length(bell(bob)) == 1

    # Another episode of the same show is new again.
    assert Releases.notify_due(ann.uuid, [event(:episode, 0, %{season: 3, episode: 10})], @today) ==
             1

    assert length(bell(ann)) == 2
  end

  test "a film's theatrical and digital releases are two pieces of news" do
    user = register("releasefilm")
    film = %{type: "movie", id: 77, title: "A Film"}

    assert Releases.notify_due(
             user.uuid,
             [event(:theatrical, 0, film), event(:digital, 0, film)],
             @today
           ) == 2

    assert Releases.notify_due(
             user.uuid,
             [event(:theatrical, 0, film), event(:digital, 0, film)],
             @today
           ) == 0
  end

  test "a season after the first is announced once, only before it starts" do
    user = register("seasonfan")

    events = [
      event(:episode, -30, %{season: 3, episode: 1}),
      event(:episode, -37, %{season: 3, episode: 2}),
      # Season 2 is already airing, season 1 is the first: neither is an announcement.
      event(:episode, 5, %{season: 2, episode: 4}),
      event(:episode, -1, %{season: 1, episode: 1}),
      # Anime has no season numbers.
      event(:episode, -9, %{episode: 3, anime: true})
    ]

    assert Releases.announce_seasons(user.uuid, events, @today) == 1

    assert [
             %{
               text: "Season 3 of A Show starts Nov 26",
               link: "/title/tv/4242",
               icon: "hero-calendar-days"
             }
           ] = bell(user)

    # Told once, however often it is looked at.
    assert Releases.announce_seasons(user.uuid, events, @today) == 0
    assert length(bell(user)) == 1
  end

  test "the week ahead is one summary on a Sunday, once a week, and nothing when nothing comes" do
    user = register("weekfan")
    sunday = ~D[2026-11-01]

    ahead = fn days, kind, extra ->
      event(kind, -days, Map.merge(%{date: Date.add(sunday, days)}, extra))
    end

    events = [
      ahead.(1, :episode, %{season: 1, episode: 1, title: "Alpha"}),
      ahead.(3, :episode, %{season: 1, episode: 2, title: "Alpha"}),
      ahead.(4, :episode, %{season: 2, episode: 1, title: "Beta"}),
      ahead.(6, :theatrical, %{type: "movie", id: 5, title: "A Film"}),
      # Not this week.
      ahead.(9, :episode, %{season: 1, episode: 3, title: "Gamma"})
    ]

    # Not a Sunday: nothing.
    assert Releases.week_ahead(user.uuid, events, ~D[2026-10-31]) == 0
    assert bell(user) == []

    assert Releases.week_ahead(user.uuid, events, sunday) == 1

    assert [
             %{
               text: "Your week ahead: 3 new episodes (Alpha, Beta) and 1 film",
               link: "/u/weekfan/calendar"
             }
           ] = bell(user)

    assert Releases.week_ahead(user.uuid, events, sunday) == 0

    # A quiet week says nothing, and does not try again that Sunday.
    quiet = register("weekquiet")
    assert Releases.week_ahead(quiet.uuid, [], sunday) == 0
    assert bell(quiet) == []
  end

  test "the summary's words" do
    assert Releases.digest_text([event(:episode, 0, %{title: "A"})], []) ==
             "Your week ahead: 1 new episode (A)"

    many = for t <- ~w(A B C D), do: event(:episode, 0, %{title: t})
    assert Releases.digest_text(many, []) == "Your week ahead: 4 new episodes (A, B, C…)"

    assert Releases.digest_text([], [event(:theatrical, 0, %{}), event(:digital, 0, %{})]) ==
             "Your week ahead: 2 films"
  end

  test "each kind can be switched off, and then nothing of it is told or used up" do
    user = register("quietfan")
    Roki.Notify.set(user.uuid, "release", false)
    Roki.Notify.set(user.uuid, "season", false)
    Roki.Notify.set(user.uuid, "digest", false)

    assert Releases.notify_due(user.uuid, [event(:episode, 0, %{season: 1, episode: 1})], @today) ==
             0

    assert Releases.announce_seasons(
             user.uuid,
             [event(:episode, -20, %{season: 4, episode: 1})],
             @today
           ) == 0

    assert Releases.week_ahead(
             user.uuid,
             [event(:episode, -2, %{date: ~D[2026-11-03], season: 1, episode: 1})],
             ~D[2026-11-01]
           ) == 0

    assert bell(user) == []

    # Switched back on, the same news is still news: nothing was spent while it was off.
    Roki.Notify.set(user.uuid, "release", true)

    assert Releases.notify_due(user.uuid, [event(:episode, 0, %{season: 1, episode: 1})], @today) ==
             1
  end
end
