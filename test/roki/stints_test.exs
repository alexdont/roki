defmodule Roki.StintsTest do
  @moduledoc """
  Watching as sessions, read back out of laev's tick log: how the lines fold, how a session
  that crosses midnight is divided, and what a window holds.
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

    # Where roki keeps an account's laev state, pointed at a directory of this test's own —
    # the same arrangement the other laev-backed tests use.
    root = Path.join(System.tmp_dir!(), "laev-#{System.unique_integer([:positive])}")
    prior = Application.get_env(:roki, :laev_dir)
    Application.put_env(:roki, :laev_dir, root)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:roki, :laev_dir, prior),
        else: Application.delete_env(:roki, :laev_dir)

      File.rm_rf(root)
    end)

    dir = Path.join(root, user.uuid)
    File.mkdir_p!(Path.join(dir, "ticks"))

    %{uuid: user.uuid, dir: dir}
  end

  # Writing the log by hand rather than through `Laev.Stints.tick/3`: these tests are about
  # what roki reads, and the lines are laev's documented format.
  defp log(dir, lines, device \\ "aaaa") do
    body = for {at, key, seconds} <- lines, do: "#{DateTime.to_unix(at)} #{key} #{seconds}\n"
    File.write!(Path.join([dir, "ticks", "#{device}.log"]), body)
  end

  @at ~U[2026-10-28 20:00:00Z]

  test "a line is a session, and a gap makes another", ctx do
    log(ctx.dir, [
      {@at, "tv-110316-s1e1", 1800},
      {DateTime.add(@at, 4 * 3600), "tv-110316-s1e2", 600}
    ])

    assert [first, second] = Stints.sessions(ctx.uuid)
    assert first.key == {"tv", 110_316}
    assert first.seconds == 1800
    assert second.seconds == 600
  end

  test "episodes of one show in one evening are one session", ctx do
    log(ctx.dir, [
      {@at, "tv-110316-s1e1", 1500},
      {DateTime.add(@at, 60), "tv-110316-s1e2", 1500}
    ])

    assert [one] = Stints.sessions(ctx.uuid)
    assert one.seconds == 3000
    assert one.keys == ["tv-110316-s1e1", "tv-110316-s1e2"]
  end

  test "a film and a show in the same evening are two sessions", ctx do
    log(ctx.dir, [{@at, "tv-110316-s1e1", 600}, {DateTime.add(@at, 60), "movie-603", 600}])

    assert [%{key: {"tv", 110_316}}, %{key: {"movie", 603}}] =
             Enum.sort_by(Stints.sessions(ctx.uuid), & &1.key)
             |> Enum.sort_by(&elem(&1.key, 0), :desc)
  end

  test "a session that crosses midnight is divided between the days it touches", ctx do
    # 23:30 to 00:30, an hour of it watched.
    log(ctx.dir, [{~U[2026-10-29 00:30:00Z], "tv-110316-s1e1", 3600}])

    days = Stints.days(ctx.uuid)

    assert Enum.sort(Map.keys(days)) == [~D[2026-10-28], ~D[2026-10-29]]
    assert days[~D[2026-10-28]] + days[~D[2026-10-29]] == 3600
  end

  test "a day is the viewer's day", ctx do
    log(ctx.dir, [{~U[2026-10-28 23:30:00Z], "movie-603", 600}])

    assert Stints.days(ctx.uuid) == %{~D[2026-10-28] => 600}
    assert Stints.days(ctx.uuid, 7200) == %{~D[2026-10-29] => 600}
  end

  test "every device's log is read", ctx do
    log(ctx.dir, [{@at, "movie-603", 600}], "mac")
    log(ctx.dir, [{DateTime.add(@at, 4 * 3600), "movie-603", 300}], "phone")

    assert Stints.days(ctx.uuid) == %{~D[2026-10-28] => 900}
  end

  test "what a window holds is exact, with the sessions and episodes that make it up", ctx do
    log(ctx.dir, [
      {~U[2026-10-20 20:00:00Z], "tv-110316-s1e1", 600},
      {~U[2026-10-28 20:00:00Z], "tv-110316-s1e2", 1200},
      {~U[2026-10-28 22:00:00Z], "movie-603", 300}
    ])

    today = ~D[2026-10-29]

    assert [show, film] = Stints.recent(ctx.uuid, 7, 0, today)
    assert show.key == {"tv", 110_316}
    assert show.seconds == 1200
    assert show.sessions == 1
    assert show.episodes == 1
    assert film.seconds == 300

    # A fortnight reaches the earlier evening, which is another session and another episode.
    assert [show | _] = Stints.recent(ctx.uuid, 14, 0, today)
    assert show.seconds == 1800
    assert show.sessions == 2
    assert show.episodes == 2
  end

  test "per title, for the days a title's own date no longer has to claim", ctx do
    log(ctx.dir, [{@at, "tv-110316-s1e1", 1800}, {~U[2026-10-20 20:00:00Z], "movie-603", 600}])

    assert Stints.by_title(ctx.uuid) == %{
             {"tv", 110_316} => %{~D[2026-10-28] => 1800},
             {"movie", 603} => %{~D[2026-10-20] => 600}
           }
  end

  test "the day view gets them as the records it already draws", ctx do
    log(ctx.dir, [{@at, "tv-110316-s1e1", 1800}])

    assert [%Stint.Record{} = r] = Stints.records(ctx.uuid)
    assert r.item == "watch:tv/110316"
    assert r.seconds == 1800
    assert r.meta["episodes"] == ["tv-110316-s1e1"]
    assert Stint.clamp_to_date(r, ~D[2026-10-28], utc_offset: 0) != nil
  end

  test "a junk line is skipped and nothing else is lost", ctx do
    File.write!(
      Path.join([ctx.dir, "ticks", "aaaa.log"]),
      "#{DateTime.to_unix(@at)} movie-603 600\nnot a line at all\n#{DateTime.to_unix(@at) + 60} movie-603 60\n"
    )

    assert [one] = Stints.sessions(ctx.uuid)
    assert one.seconds == 660
  end
end
