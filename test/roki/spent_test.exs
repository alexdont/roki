defmodule Roki.SpentTest do
  @moduledoc """
  The one list the stats page is a filter over: which date an entry counts under, and what a
  window and a kind do to it.
  """
  use Roki.DataCase

  alias Roki.Spent

  @now 1_793_000_000
  @long_ago @now - 400 * 86_400

  defp stats(last_seen) do
    %{
      titles: [
        %{
          type: "mal",
          id: 5114,
          title: "Nagatoro",
          seconds: 3600,
          off: 0,
          anime: true,
          last_seen: last_seen
        },
        %{
          type: "movie",
          id: 603,
          title: "The Matrix",
          seconds: 7200,
          off: 0,
          anime: false,
          last_seen: last_seen
        }
      ]
    }
  end

  test "without a date of its own, an entry counts when it was last played" do
    [nagatoro, _] = Spent.watched(stats(@now))
    assert nagatoro.at == @now
    assert nagatoro.kind == :anime
  end

  test "a date set on the watched page is when it counts, not when it was played" do
    dates = %{{"mal", 5114} => @long_ago}
    [nagatoro, matrix] = Spent.watched(stats(@now), dates)

    # Backdated: it belongs where its owner put it.
    assert nagatoro.at == @long_ago
    # Untouched: still laev's answer.
    assert matrix.at == @now
  end

  test "so a backdated entry is out of the recent window, with its time" do
    entries = Spent.watched(stats(@now), %{{"mal", 5114} => @long_ago})

    week = Spent.within(entries, 7, @now)
    assert Enum.map(week, & &1.title) == ["The Matrix"]
    assert Spent.total(week) == 7200

    all = Spent.within(entries, nil, @now)
    assert Spent.total(all) == 10_800
    assert Spent.by_kind(all) == %{movie: 7200, tv: 0, anime: 3600, manga: 0}
  end

  test "a kind narrows the list and nothing else" do
    entries = Spent.watched(stats(@now))

    assert Enum.map(Spent.of_kind(entries, :anime), & &1.title) == ["Nagatoro"]
    assert Spent.of_kind(entries, :all) == entries
    assert Spent.of_kind(entries, :manga) == []
  end

  defp show(seconds) do
    %{
      titles: [
        %{
          type: "tv",
          id: 110_316,
          title: "Alice in Borderland",
          seconds: seconds,
          off: 0,
          anime: false,
          last_seen: @now
        }
      ],
      # Ten episodes all really played, their positions in the same 8:2 proportion.
      seasons: %{
        {"tv", 110_316} => %{
          1 => %{episodes: 8, marked: 0, seconds: 800},
          2 => %{episodes: 2, marked: 0, seconds: 200}
        }
      }
    }
  end

  test "a season given a date of its own becomes its own entry, with its share" do
    # Eight episodes of season one, two of season two: four fifths and one fifth.
    entries = Spent.watched(show(10_000), %{}, %{{"tv", 110_316, 1} => @long_ago})

    assert [s1, rest] = entries
    assert s1.title == "Alice in Borderland · S1"
    assert s1.at == @long_ago
    assert s1.seconds == 8000

    # What is left stays with the show, on the show's own date.
    assert rest.title == "Alice in Borderland"
    assert rest.at == @now
    assert rest.seconds == 2000

    # And the show still adds up to what laev said.
    assert Spent.total(entries) == 10_000
  end

  test "dating every season leaves nothing on the title" do
    entries =
      Spent.watched(show(10_000), %{}, %{
        {"tv", 110_316, 1} => @long_ago,
        {"tv", 110_316, 2} => @now
      })

    assert Enum.map(entries, & &1.title) == [
             "Alice in Borderland · S1",
             "Alice in Borderland · S2"
           ]

    assert Spent.total(entries) == 10_000
    assert Spent.total(Spent.within(entries, 7, @now)) == 2000
  end

  test "marked episodes take runtime, played episodes take what was measured" do
    # The real shape of a show someone watched years ago and is restarting: season one
    # marked by hand, which is where all of laev's `off` comes from, and two test plays
    # of nine minutes in season two. Dividing by episode count gave season two a fifth
    # of the marked hours — two hours of a show nobody had watched.
    stats = %{
      titles: [
        %{
          type: "tv",
          id: 110_316,
          title: "Alice in Borderland",
          seconds: 37_506,
          off: 36_960,
          anime: false,
          last_seen: @now
        }
      ],
      seasons: %{
        {"tv", 110_316} => %{
          1 => %{episodes: 8, marked: 8, seconds: 0},
          2 => %{episodes: 2, marked: 0, seconds: 610}
        }
      }
    }

    [s2, rest] = Spent.watched(stats, %{}, %{{"tv", 110_316, 2} => @now})

    assert s2.title == "Alice in Borderland · S2"
    assert s2.seconds == 546
    assert s2.off == 0

    assert rest.seconds == 36_960
    assert Spent.total([s2, rest]) == 37_506
  end

  test "a show nobody has dated by season is one entry as before" do
    assert [one] = Spent.watched(show(10_000), %{}, %{})
    assert one.title == "Alice in Borderland"
    assert one.seconds == 10_000
  end

  test "the heatmap puts a title on the date it counts under, not the day it played" do
    played_today = stats(@now)
    backdated = Spent.watched(played_today, %{{"mal", 5114} => @long_ago})

    days = Spent.days(backdated, %{})
    today = DateTime.from_unix!(@now) |> DateTime.to_date()
    then = DateTime.from_unix!(@long_ago) |> DateTime.to_date()

    # The film, which has no date of its own, stays where laev saw it.
    assert days[today] == 7200
    # The anime goes where its owner put it, with its hours.
    assert days[then] == 3600
  end

  test "reading keeps its own day-by-day log in the heatmap" do
    entries = Spent.watched(stats(@now))
    activity = %{~D[2026-03-01] => [%{seconds: 600}, %{seconds: 300}]}

    days = Spent.days(entries, activity)
    assert days[~D[2026-03-01]] == 900
  end

  test "reading and watching are the same shape, and add up together" do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "spent@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "spentuser"
      })

    {:ok, _} =
      Roki.Manga.Library.save_manga(user.uuid, %{
        source: "mangadex",
        slug: "berserk",
        title: "Berserk",
        cover_url: "https://example.invalid/b.jpg"
      })

    {:ok, bin} = Ecto.UUID.dump(user.uuid)
    Roki.Repo.query!("update saved_manga set reading_seconds = 1800 where user_id = $1", [bin])

    rows = Roki.Manga.Library.list_reading_stats(user.uuid)
    read = Spent.read(rows, %{}, nil)
    assert [%{kind: :manga, title: "Berserk", seconds: 1800}] = read

    both = Spent.sort(Spent.watched(stats(@now)) ++ read)
    assert Enum.map(both, & &1.title) == ["The Matrix", "Nagatoro", "Berserk"]
    assert Spent.total(both) == 12_600
  end

  describe "dated arcs" do
    # Off-site hours have no day of their own, so a window cannot hold them and all
    # of them sit in all time. A dated arc moves its share — and only its share.
    @arcs %{
      {"mangadex", "berserk"} => [
        %{title: "Berserk · Golden Age Arc", seconds: 3600, at: 1_500_000_000}
      ]
    }

    setup do
      rows = [
        %{
          source: "mangadex",
          slug: "berserk",
          title: "Berserk",
          reading_seconds: 1800,
          reading_seconds_adjusted: nil,
          reading_seconds_offsite: 7200,
          updated_at: ~N[2026-03-01 10:00:00]
        }
      ]

      %{rows: rows}
    end

    test "an arc with a date is its own entry, and the total does not move", %{rows: rows} do
      undated = Spent.read(rows, %{}, nil, @now)
      dated = Spent.read(rows, %{}, nil, @now, @arcs)

      assert Spent.total(undated) == Spent.total(dated)
      assert Spent.total(dated) == 9000

      assert Enum.sort(Enum.map(dated, &{&1.title, &1.seconds})) == [
               {"Berserk", 5400},
               {"Berserk · Golden Age Arc", 3600}
             ]
    end

    test "a window holds a dated arc only when the date is in it", %{rows: rows} do
      now = DateTime.to_unix(~U[2017-07-20 00:00:00Z])

      assert [%{title: "Berserk · Golden Age Arc"}] = Spent.read(rows, %{}, 30, now, @arcs)
      assert Spent.read(rows, %{}, 30, @now, @arcs) == []
    end

    test "the heatmap places a dated arc on its day" do
      days = Spent.days([], %{}, @arcs)
      assert days[~D[2017-07-14]] == 3600
    end
  end

  describe "days a title's hours are placed on" do
    test "what the sessions can place goes where it happened, and only the rest on the date" do
      stats = show(10_000)
      [entry] = Spent.watched(stats, %{{"tv", 110_316} => @now})

      # Three of the ten thousand seconds have days of their own.
      logged = %{
        {"tv", 110_316} => %{~D[2026-03-01] => 2000, ~D[2026-03-02] => 1000}
      }

      days = Spent.days([entry], %{}, %{}, logged)
      today = @now |> DateTime.from_unix!() |> DateTime.to_date()

      assert days[~D[2026-03-01]] == 2000
      assert days[~D[2026-03-02]] == 1000
      # The lump keeps only what no day is known for.
      assert days[today] == 7000
      assert Enum.sum(Map.values(days)) == 10_000
    end

    test "a title the sessions account for entirely leaves nothing on its date" do
      stats = show(10_000)
      [entry] = Spent.watched(stats, %{{"tv", 110_316} => @now})
      logged = %{{"tv", 110_316} => %{~D[2026-03-01] => 10_000}}

      days = Spent.days([entry], %{}, %{}, logged)

      assert days == %{~D[2026-03-01] => 10_000}
    end

    test "seasons spend one allowance between them, not one each" do
      entries =
        Spent.watched(show(10_000), %{}, %{
          {"tv", 110_316, 1} => @long_ago,
          {"tv", 110_316, 2} => @now
        })

      logged = %{{"tv", 110_316} => %{~D[2026-03-01] => 9000}}
      days = Spent.days(entries, %{}, %{}, logged)

      assert days[~D[2026-03-01]] == 9000
      assert Enum.sum(Map.values(days)) == 10_000
    end
  end

  describe "a window over a title with sessions" do
    @today @now |> DateTime.from_unix!() |> DateTime.to_date()
    @logged %{{"tv", 110_316} => %{@today => 2000, Date.add(@today, -40) => 5000}}
    @all_old %{{"tv", 110_316} => %{Date.add(@today, -40) => 5000}}

    test "holds exactly what the sessions put in it, not the title's whole history" do
      entries = Spent.watched(show(10_000))

      assert [one] = Spent.narrow(entries, 7, @now, @logged)
      assert one.title == "Alice in Borderland"
      assert one.seconds == 2000
      assert one.off == 0

      # A wider window reaches the earlier session too.
      assert [wider] = Spent.narrow(entries, 60, @now, @logged)
      assert wider.seconds == 7000
    end

    test "holds nothing when the sessions say nothing happened in it" do
      assert Spent.narrow(Spent.watched(show(10_000)), 7, @now, @all_old) == []
    end

    test "a measured title is one row however its seasons are dated" do
      entries =
        Spent.watched(show(10_000), %{}, %{
          {"tv", 110_316, 1} => @long_ago,
          {"tv", 110_316, 2} => @now
        })

      assert [one] = Spent.narrow(entries, 7, @now, @logged)
      assert one.title == "Alice in Borderland"
      assert one.seconds == 2000
    end

    test "a title with no sessions is narrowed as it always was" do
      entries = Spent.watched(show(10_000))

      assert [one] = Spent.narrow(entries, 7, @now, %{})
      assert one.seconds == 10_000
      # And a title last touched long ago is out of the window, as before.
      old = put_in(show(10_000), [:titles, Access.at(0), :last_seen], @long_ago)
      assert Spent.narrow(Spent.watched(old), 7, @now, %{}) == []
    end

    test "all time is all of it, sessions or not" do
      entries = Spent.watched(show(10_000))
      assert Spent.narrow(entries, nil, @now, @logged) == entries
    end
  end
end
