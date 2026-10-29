defmodule Roki.DetailTest do
  @moduledoc """
  Everything the stats popup says: what was timed and what was only known, which dates are
  recorded and where each came from, and the line past which a skipped figure can be believed.
  """
  use Roki.DataCase

  alias Roki.{Detail, Stats}

  @cutoff Stats.believable_from()
  # Before and after the line, by a margin that cannot be argued with.
  @old @cutoff - 10 * 86_400
  @recent @cutoff + 3600

  setup do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "detail@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "detailuser"
      })

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
    for sub <- ["positions", "played", "ticks"], do: File.mkdir_p!(Path.join(dir, sub))

    %{uuid: user.uuid, dir: dir}
  end

  # A position file, an optional measurement beside it, and laev's record of when it changed.
  defp put(ctx, name, position, played \\ nil) do
    File.write!(Path.join([ctx.dir, "positions", name]), position)
    if played, do: File.write!(Path.join([ctx.dir, "played", name]), played)
  end

  defp changed(ctx, times) do
    positions =
      for {name, at} <- times, into: %{} do
        {name, %{"data" => "x", "deleted" => false, "updated_at" => at}}
      end

    File.write!(Path.join(ctx.dir, "sync.json"), Jason.encode!(%{"positions" => positions}))
  end

  describe "watching a show" do
    # The shape of a real one: the whole show marked, six episodes marked, three really played.
    setup ctx do
      put(ctx, "tv-225634", "seen")
      for e <- 1..6, do: put(ctx, "tv-225634-s1e#{e}", "seen")
      put(ctx, "tv-225634-s1e7", "done", "3005 0")
      put(ctx, "tv-225634-s1e8", "done", "2774 93")
      put(ctx, "tv-225634-s1e9", "done", "2898 205")

      times =
        for(e <- 1..6, into: %{}, do: {"tv-225634-s1e#{e}", 1000})
        |> Map.merge(%{
          "tv-225634" => 5000,
          "tv-225634-s1e7" => 2000,
          "tv-225634-s1e8" => 3000,
          "tv-225634-s1e9" => 4000
        })

      changed(ctx, times)
      %{detail: Detail.watching(ctx.uuid, {"tv", 225_634})}
    end

    test "counts what was timed and what was only marked", %{detail: d} do
      assert d.timed == 3005 + 2774 + 2898
      assert d.played_count == 3
      assert d.marked_count == 6
    end

    test "lists the whole-show mark first, then the episodes in order", %{detail: d} do
      assert Enum.map(d.episodes, & &1.label) ==
               ["The whole show" | for(e <- 1..9, do: "S1 E#{e}")]
    end

    test "dates it from what finished, since no session was recorded", %{detail: d} do
      assert d.session_count == 0
      assert d.started == %{at: 2000, how: :finish}
      assert d.last == %{at: 4000, how: :finish}
    end

    test "says it was marked complete by the whole-show mark, and when", %{detail: d} do
      assert d.marked == %{at: 5000, how: :title, state: :marked}
    end

    test "does not pick up a different title that shares the start of its id", %{
      uuid: uuid,
      dir: dir
    } do
      File.write!(Path.join([dir, "positions", "tv-22563"]), "seen")

      assert Detail.watching(uuid, {"tv", 22_563}).episodes |> length() == 1
      assert Detail.watching(uuid, {"tv", 2256}).episodes == []
    end
  end

  describe "skipped time, and when it can be believed" do
    test "a play from before the line is unsure, not skipped", ctx do
      put(ctx, "movie-1561726", "done", "2027 4853")
      changed(ctx, %{"movie-1561726" => @old})

      d = Detail.watching(ctx.uuid, {"movie", 1_561_726})

      assert d.skipped == nil
      assert d.unsure == 4853
      assert d.timed == 2027
    end

    test "a play from after it is believed", ctx do
      put(ctx, "movie-1561726", "done", "6000 120")
      changed(ctx, %{"movie-1561726" => @recent})

      d = Detail.watching(ctx.uuid, {"movie", 1_561_726})

      assert d.skipped == 120
      assert d.unsure == 0
    end

    test "a title that skipped nothing says zero, which is not the same as not knowing", ctx do
      put(ctx, "movie-1561726", "done", "6000 0")
      changed(ctx, %{"movie-1561726" => @recent})

      assert Detail.watching(ctx.uuid, {"movie", 1_561_726}).skipped == 0
    end

    test "old and recent plays of one show are kept apart", ctx do
      put(ctx, "tv-1-s1e1", "done", "1000 900")
      put(ctx, "tv-1-s1e2", "done", "1000 60")
      changed(ctx, %{"tv-1-s1e1" => @old, "tv-1-s1e2" => @recent})

      d = Detail.watching(ctx.uuid, {"tv", 1})

      assert d.skipped == 60
      assert d.unsure == 900
    end

    test "Stats.plays draws the same line", ctx do
      put(ctx, "movie-1", "done", "2027 4853")
      put(ctx, "movie-2", "done", "6000 120")
      changed(ctx, %{"movie-1" => @old, "movie-2" => @recent})

      plays = Laev.Scope.run(Laev.Scope.new(ctx.dir), &Stats.plays/0)

      assert %{skipped: nil, unsure: 4853, timed: 2027} = plays[{"movie", 1}]
      assert %{skipped: 120, unsure: 0, timed: 6000} = plays[{"movie", 2}]
    end
  end

  describe "sessions" do
    test "come from laev's tick log, and date the title when they exist", ctx do
      put(ctx, "tv-110316-s1e1", "done", "1500 0")
      changed(ctx, %{"tv-110316-s1e1" => 9999})

      File.write!(
        Path.join([ctx.dir, "ticks", "aaaa.log"]),
        "1793000000 tv-110316-s1e1 1500\n1793900000 tv-110316-s1e2 600\n"
      )

      d = Detail.watching(ctx.uuid, {"tv", 110_316})

      assert d.session_count == 2
      assert d.longest == 1500
      # Newest first, because that is the one you want.
      assert [%{seconds: 600}, %{seconds: 1500}] = d.sessions
      assert d.started == %{at: 1_793_000_000 - 1500, how: :session}
      assert d.last == %{at: 1_793_900_000, how: :session}
    end
  end

  describe "a title with nothing recorded" do
    test "answers with nothing in it rather than failing", ctx do
      d = Detail.watching(ctx.uuid, {"movie", 999_999_999})

      assert d.episodes == []
      assert d.timed == 0
      assert d.started == nil and d.last == nil and d.marked == nil
      assert d.session_count == 0
    end
  end

  describe "reading" do
    setup ctx do
      {:ok, _} =
        Roki.Manga.Library.save_manga(ctx.uuid, %{
          source: "mangafreak",
          slug: "overgeared",
          title: "Overgeared",
          cover_url: "https://example.invalid/o.jpg"
        })

      Roki.Repo.query!(
        "update saved_manga set reading_seconds = 8412, reading_seconds_adjusted = 8340, reading_seconds_offsite = 95460, last_chapter = '331', total_chapters = 342"
      )

      {:ok, bin} = Ecto.UUID.dump(ctx.uuid)

      Roki.Repo.query!(
        "insert into reading_activity (user_id, date, source, slug, title, reading_seconds, chapters_read, inserted_at, updated_at) values " <>
          "($1, '2026-03-22', 'mangafreak', 'overgeared', 'Overgeared', 600, 3, now(), now()), " <>
          "($1, '2026-07-20', 'mangafreak', 'overgeared', 'Overgeared', 900, 5, now(), now())",
        [bin]
      )

      Roki.Repo.query!(
        "insert into library_events (user_id, source, slug, event, chapter, happened_at) values " <>
          "($1, 'mangafreak', 'overgeared', 'started', '1', '2026-03-22 10:00:00'), " <>
          "($1, 'mangafreak', 'overgeared', 'caught_up', '331', '2026-07-20 10:00:00')",
        [bin]
      )

      %{detail: Detail.reading(ctx.uuid, "mangafreak", "overgeared")}
    end

    test "splits what was read here from what was entered by hand", %{detail: d} do
      assert d.on_site == 8340
      assert d.off_site == 95_460
      refute d.approximate?
    end

    test "gives progress and the days it was read on", %{detail: d} do
      assert d.last_chapter == "331"
      assert d.total_chapters == 342
      assert d.days_read == 2
      assert d.first_day == ~D[2026-03-22]
      assert d.last_day == ~D[2026-07-20]
    end

    test "gives the reader's own milestones, and nil for the one that has not happened", %{
      detail: d
    } do
      assert is_integer(d.started)
      assert is_integer(d.caught_up_at)
      assert d.completed_at == nil
      refute d.completed?
    end

    test "a series that is not saved gives nothing", ctx do
      assert Detail.reading(ctx.uuid, "mangafreak", "not-a-series") == nil
    end
  end

  describe "the popup's keys" do
    test "go there and back" do
      assert Detail.decode(Detail.encode(%{kind: :tv, key: {"tv", 110_316}})) ==
               {:watching, {"tv", 110_316}}

      assert Detail.decode(Detail.encode(%{kind: :anime, key: {"mal", 51_553}})) ==
               {:watching, {"mal", 51_553}}

      assert Detail.decode(Detail.encode(%{kind: :manga, key: {"mangafreak", "overgeared"}})) ==
               {:reading, "mangafreak", "overgeared"}
    end

    test "refuse anything that is not one" do
      for junk <- [
            "",
            "nonsense",
            "tv:",
            "tv:abc",
            "tv:12x",
            "book:5",
            "manga:onlysource",
            nil,
            5
          ] do
        assert Detail.decode(junk) == nil, "decoded #{inspect(junk)}"
      end
    end
  end
end
