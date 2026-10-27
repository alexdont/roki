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
      %{date: Date.add(@today, -days_ago), kind: kind, label: "x", type: "tv", id: 4242, title: "A Show", season: nil, episode: nil, anime: false},
      extra
    )
  end

  defp bell(user),
    do: for(n <- PhoenixKit.Notifications.recent_for_user(user.uuid, 20), do: PhoenixKit.Notifications.Render.render(n))

  test "the words and the link of each kind of release" do
    assert %{text: "New episode of A Show: S2E5 came out today", link: "/title/tv/4242", icon: "hero-play-circle"} =
             Releases.notice(event(:episode, 0, %{season: 2, episode: 5}), @today)

    assert Releases.notice(event(:episode, 1, %{episode: 6, anime: true}), @today).text ==
             "New episode of A Show: episode 6 came out yesterday"

    assert %{text: "A Film reached theaters today", link: "/title/movie/9"} =
             Releases.notice(event(:theatrical, 0, %{type: "movie", id: 9, title: "A Film"}), @today)

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
    assert bell(user) |> Enum.map(& &1.text) |> Enum.sort() == ["New episode of A Show: S1E1 came out today", "New episode of A Show: S1E2 came out yesterday"]
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
    assert Releases.notify_due(ann.uuid, [event(:episode, 0, %{season: 3, episode: 10})], @today) == 1
    assert length(bell(ann)) == 2
  end

  test "a film's theatrical and digital releases are two pieces of news" do
    user = register("releasefilm")
    film = %{type: "movie", id: 77, title: "A Film"}

    assert Releases.notify_due(user.uuid, [event(:theatrical, 0, film), event(:digital, 0, film)], @today) == 2
    assert Releases.notify_due(user.uuid, [event(:theatrical, 0, film), event(:digital, 0, film)], @today) == 0
  end
end
