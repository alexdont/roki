defmodule Roki.StintsTest do
  @moduledoc """
  Watching as sessions: what a tick does, how a session that crosses midnight is divided, and
  which episodes a session covered.
  """
  use Roki.DataCase

  alias Roki.Stints

  setup do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "stints@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "stintsuser"
      })

    %{uuid: user.uuid}
  end

  defp tick(uuid, ctx, seconds, at) do
    Stint.track(uuid, Stints.item(ctx), seconds, at: at, meta: meta(ctx))
  end

  defp meta(ctx) do
    %{"title" => ctx[:title], "season" => ctx[:season], "episode" => ctx[:episode]}
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
    |> Map.new()
  end

  @show %{type: "tv", tmdb_id: 110_316, title: "Alice in Borderland", season: 1, episode: 1}

  test "ticks close together are one session, and a long silence starts another", %{uuid: uuid} do
    at = ~U[2026-10-28 20:00:00Z]

    for n <- 0..5, do: tick(uuid, @show, 60, DateTime.add(at, n * 60))
    # Well past the 120-second gap: a new evening.
    tick(uuid, @show, 60, DateTime.add(at, 4 * 3600))

    assert [first, second] = Stints.all(uuid)
    assert first.seconds == 360
    assert second.seconds == 60
    assert first.meta["title"] == "Alice in Borderland"
  end

  test "the title, not the episode, is the session", %{uuid: uuid} do
    at = ~U[2026-10-28 20:00:00Z]
    tick(uuid, @show, 60, at)
    tick(uuid, %{@show | episode: 2}, 60, DateTime.add(at, 60))

    assert [one] = Stints.all(uuid)
    assert one.seconds == 120
    # Meta follows the playhead, so it says where the session got to.
    assert one.meta["episode"] == 2
  end

  test "a session that crosses midnight is divided between the days it touches", %{uuid: uuid} do
    # 23:30 to 00:30, an hour of it watched: half an hour each side.
    tick(uuid, @show, 1800, ~U[2026-10-28 23:59:00Z])
    tick(uuid, @show, 1800, ~U[2026-10-29 00:30:00Z])

    days = Stints.days(uuid)

    assert Map.keys(days) |> Enum.sort() == [~D[2026-10-28], ~D[2026-10-29]]
    assert days[~D[2026-10-28]] + days[~D[2026-10-29]] == 3600
  end

  test "a day is the viewer's day", %{uuid: uuid} do
    # 23:30 UTC is half past one the next morning in Tallinn.
    tick(uuid, @show, 600, ~U[2026-10-28 23:30:00Z])

    assert Stints.days(uuid) == %{~D[2026-10-28] => 600}
    assert Stints.days(uuid, 7200) == %{~D[2026-10-29] => 600}
  end

  test "what a window holds is exact, with the sessions that make it up", %{uuid: uuid} do
    today = ~D[2026-10-29]
    # In the order they happened: a tick older than the session in progress extends it rather
    # than opening one behind it, which is Stint's own answer to a late report.
    tick(uuid, @show, 600, ~U[2026-10-20 20:00:00Z])
    tick(uuid, @show, 1200, ~U[2026-10-28 20:00:00Z])
    tick(uuid, %{type: "movie", tmdb_id: 603, title: "The Matrix"}, 300, ~U[2026-10-28 22:00:00Z])

    assert [show, film] = Stints.recent(uuid, 7, 0, today)
    assert show.key == {"tv", 110_316}
    assert show.seconds == 1200
    assert show.sessions == 1
    assert film.key == {"movie", 603}
    assert film.seconds == 300

    # A fortnight reaches the earlier evening too, and it is the same session count plus one.
    assert [show | _] = Stints.recent(uuid, 14, 0, today)
    assert show.seconds == 1800
    assert show.sessions == 2
  end

  test "an item that is not a watching stint is left alone", %{uuid: uuid} do
    Stint.track(uuid, "manga:mangadex/berserk", 600, at: ~U[2026-10-28 20:00:00Z])
    tick(uuid, @show, 600, ~U[2026-10-28 20:00:00Z])

    assert [one] = Stints.all(uuid)
    assert one.item == "watch:tv/110316"
    assert Stints.days(uuid) == %{~D[2026-10-28] => 600}
  end

  test "the episodes a session covered are the finishes inside it", %{uuid: uuid} do
    at = ~U[2026-10-28 20:00:00Z]
    # Twenty minutes of ticks, none more than the gap apart: one session.
    for n <- 0..20, do: tick(uuid, @show, 60, DateTime.add(at, n * 60))

    {:ok, bin} = Ecto.UUID.dump(uuid)

    for {episode, minutes} <- [{1, 8}, {2, 17}, {3, 400}] do
      Roki.Repo.query!(
        "insert into roki_activity (user_uuid, type, tmdb_id, season, episode, title, at, kind) " <>
          "values ($1, 'tv', 110316, 1, $2, 'Alice in Borderland', $3, 'finished')",
        [bin, episode, DateTime.add(at, minutes * 60) |> DateTime.to_naive()]
      )
    end

    [stint] = Stints.all(uuid)
    # The third finish is long after the session ended, so it is not part of it.
    assert Enum.map(Stints.episodes_in(uuid, stint), & &1.episode) == [1, 2]
  end
end
