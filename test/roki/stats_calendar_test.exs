defmodule Roki.StatsCalendarTest do
  use ExUnit.Case, async: true

  alias Roki.{Calendar, Stats, TTLCache}

  describe "day log parsing" do
    test "plain lines add up per day" do
      acc = Stats.add_log(%{}, "2026-10-22 5\n2026-10-22 5\n2026-10-21 60\n")
      assert acc[~D[2026-10-22]] == 10
      assert acc[~D[2026-10-21]] == 60
    end

    test "a fused line is split, not read as one huge number" do
      acc = Stats.add_log(%{}, "2026-10-22 12026-10-22 2\n2026-10-22 5\n")
      assert acc[~D[2026-10-22]] == 1 + 2 + 5
    end

    test "several entries fused together" do
      acc = Stats.add_log(%{}, "2026-10-16 52026-10-16 52026-10-16 5")
      assert acc[~D[2026-10-16]] == 15
    end

    test "folded per-day totals and junk lines" do
      acc = Stats.add_log(%{}, "2026-09-26 11007\nnot a log line\n2026-09-27 1477\n")
      assert acc == %{~D[2026-09-26] => 11007, ~D[2026-09-27] => 1477}
    end

    test "an impossible single value is dropped" do
      assert Stats.add_log(%{}, "2026-10-22 99999999") == %{}
    end
  end

  describe "heatmap" do
    test "whole Monday-to-Sunday weeks, today last, the future blank" do
      weeks = Stats.heatmap(%{Laev.Days.today() => 3600}, 4)
      assert length(weeks) == 4
      assert Enum.all?(weeks, &(length(&1) == 7))
      assert Date.day_of_week(elem(hd(hd(weeks)), 0)) == 1

      cells = List.flatten(weeks)
      today = Laev.Days.today()
      assert {^today, 3600} = Enum.find(cells, fn {d, _} -> d == today end)
      assert Enum.all?(cells, fn {d, s} -> Date.compare(d, today) == :gt == is_nil(s) end)
    end
  end

  describe "stats ranges" do
    test "a title belongs to a window by when it was last watched; undated ones only to all time" do
      now = 1_000_000_000
      day = 86_400

      titles = [
        %{title: "recent", last_seen: now - 2 * day},
        %{title: "last month", last_seen: now - 20 * day},
        %{title: "old", last_seen: now - 200 * day},
        %{title: "imported", last_seen: nil}
      ]

      names = fn days -> titles |> Stats.within(days, now) |> Enum.map(& &1.title) end
      assert names.(7) == ["recent"]
      assert names.(30) == ["recent", "last month"]
      assert names.(183) == ["recent", "last month"]
      assert length(names.(nil)) == 4
    end
  end

  describe "runtime cache repair" do
    @tag :tmp_dir
    test "a cache that is mostly 'unknown' is cleared of them; anime lengths and real ones stay",
         %{tmp_dir: dir} do
      path = Path.join(dir, "runtimes.json")

      File.write!(
        path,
        Jason.encode!(%{
          "movie-1" => "unknown",
          "movie-2" => "unknown",
          "movie-3" => 7200,
          "tv-4" => "unknown",
          "mal-5" => 1440
        })
      )

      assert {:healed, 3} = Laev.Scope.run(Laev.Scope.new(dir), &Stats.heal_runtimes/0)
      assert path |> File.read!() |> Jason.decode!() == %{"movie-3" => 7200, "mal-5" => 1440}
    end

    @tag :tmp_dir
    test "a healthy cache — a few genuinely unlisted runtimes — is left alone", %{tmp_dir: dir} do
      path = Path.join(dir, "runtimes.json")
      cache = Map.new(1..20, &{"movie-#{&1}", 6000}) |> Map.put("movie-99", "unknown")
      File.write!(path, Jason.encode!(cache))

      assert :ok = Laev.Scope.run(Laev.Scope.new(dir), &Stats.heal_runtimes/0)
      assert path |> File.read!() |> Jason.decode!() == cache
    end

    @tag :tmp_dir
    test "no TMDB key means no measuring (and so nothing to poison)", %{tmp_dir: dir} do
      scope = Laev.Scope.new(dir, %{tmdb_key: nil})
      prior = Application.get_env(:laev, :tmdb_key)
      Application.delete_env(:laev, :tmdb_key)
      on_exit(fn -> if prior, do: Application.put_env(:laev, :tmdb_key, prior) end)

      assert {:error, :no_tmdb_key} = Laev.Scope.run(scope, &Stats.build/0)
      refute File.exists?(Path.join(dir, "runtimes.json"))
    end
  end

  describe "calendar pulse" do
    defp ev(date, label),
      do: %{
        date: date,
        label: label,
        kind: :episode,
        type: "tv",
        id: 1,
        title: label,
        anime: false
      }

    test "yesterday dropped, the next week upcoming with days until" do
      today = ~D[2026-10-22]

      events = [
        ev(~D[2026-10-20], "older"),
        ev(~D[2026-10-21], "yesterday's"),
        ev(~D[2026-10-22], "today's"),
        ev(~D[2026-10-25], "in three"),
        ev(~D[2026-10-29], "a week out"),
        ev(~D[2026-10-30], "too far")
      ]

      {dropped, upcoming} = Calendar.pulse(events, today)
      assert Enum.map(dropped, & &1.label) == ["yesterday's"]

      assert Enum.map(upcoming, &{&1.label, &1.days}) == [
               {"today's", 0},
               {"in three", 3},
               {"a week out", 7}
             ]
    end

    test "relative day wording" do
      assert Calendar.relative(0) == "today"
      assert Calendar.relative(1) == "tomorrow"
      assert Calendar.relative(3) == "in 3 days"
      assert Calendar.relative(-1) == "yesterday"
      assert Calendar.relative(-9) == "9 days ago"
    end
  end

  test "TTLCache.cached?/1 reports a live entry without computing one" do
    key = {:cached?, System.unique_integer()}
    refute TTLCache.cached?(key)
    TTLCache.fetch(key, 60, fn -> {:ok, 1} end)
    assert TTLCache.cached?(key)
  end
end
