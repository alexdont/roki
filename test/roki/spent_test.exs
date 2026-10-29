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
      seasons: %{{"tv", 110_316} => %{1 => 8, 2 => 2}}
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
end
