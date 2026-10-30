defmodule RokiWeb.SeasonButtonTest do
  @moduledoc """
  The button beside the season picker. It drew the season as watched (solid green, "Season
  watched") the moment every episode that had *aired* was ticked, so VisionQuest — eight episodes,
  six out — showed its season as completed when he ticked the sixth, two episodes early.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest, only: [rendered_to_string: 1]

  alias RokiWeb.TitleLive

  # A season of `total` episodes of which the first `out` have aired.
  defp season(total, out) do
    for n <- 1..total do
      %{
        number: n,
        local: n,
        name: "Episode #{n}",
        aired?: n <= out,
        air_date: "2026-10-#{String.pad_leading("#{n}", 2, "0")}",
        minutes: 50,
        still: nil,
        overview: nil
      }
    end
  end

  defp watched(count), do: MapSet.new(if(count == 0, do: [], else: 1..count))

  describe "season_state/2" do
    test "is complete only when every episode of the season is out and watched" do
      assert TitleLive.season_state(season(8, 8), watched(8)) == :complete
    end

    test "is up to date when everything out is watched and episodes are still to come" do
      # The case: six of eight out, six ticked.
      assert TitleLive.season_state(season(8, 6), watched(6)) == :up_to_date
      assert TitleLive.season_state(season(10, 1), watched(1)) == :up_to_date
    end

    test "is open while anything that is out is not watched" do
      assert TitleLive.season_state(season(8, 6), watched(5)) == :open
      assert TitleLive.season_state(season(8, 8), watched(7)) == :open
      assert TitleLive.season_state(season(8, 6), watched(0)) == :open
    end

    test "is open for a season with nothing out yet, however it is asked" do
      assert TitleLive.season_state(season(8, 0), watched(0)) == :open
      assert TitleLive.season_state([], watched(0)) == :open
      assert TitleLive.season_state(nil, watched(0)) == :open
    end

    test "ticking a later episode first does not make an earlier gap disappear" do
      assert TitleLive.season_state(season(8, 6), MapSet.new([2, 3, 4, 5, 6])) == :open
    end
  end

  describe "what the button says" do
    test "a finished season is watched, and unmarking is offered" do
      assert TitleLive.season_title(:complete, 0) == "Season watched — click to unmark"
      assert TitleLive.season_aria(:complete, 0) == "Unmark season watched"
    end

    test "an up-to-date season says that more is coming, and how many" do
      title = TitleLive.season_title(:up_to_date, 2)

      assert title =~ "Up to date"
      assert title =~ "2 still to air"
      refute title =~ "Season watched"
    end

    test "an open season offers the whole season, or the part of it that is out" do
      assert TitleLive.season_title(:open, 0) == "Mark the whole season watched"
      assert TitleLive.season_title(:open, 2) == "Mark the episodes that are out as watched"
    end
  end

  describe "the component" do
    defp render(episodes, watched_count) do
      sec = %{key: "1", season: 1, label: "Miniseries", total: length(episodes), mal: nil}

      %{
        title: %{title: "VisionQuest"},
        season: 1,
        episodes: episodes,
        watched: watched(watched_count),
        sections: [sec],
        section: sec,
        season_counts: %{},
        cached: MapSet.new(),
        title_id: 213_375,
        can_play?: true,
        rating: %{state: :loading, value: nil, provider: :tmdb},
        __changed__: nil
      }
      |> TitleLive.episodes()
      |> rendered_to_string()
    end

    defp button(html), do: hd(Regex.run(~r/<button[^>]*phx-click="toggle_season"[^>]*>/s, html))

    test "six of eight ticked: not solid green, not 'Season watched', and no tick on the season" do
      html = render(season(8, 6), 6)
      button = button(html)

      assert button =~ ~s(data-season="up_to_date")
      assert button =~ "btn-outline"
      # Green, but only as an outline: solid green is for a season that is done.
      assert button =~ "btn-success"
      refute button =~ "Season watched"
      assert button =~ "2 still to air"
      # The season in the picker carries a green eye only once it is complete.
      refute html =~ "text-success"
    end

    test "all eight out and ticked: solid green, and the season is ticked in the picker" do
      html = render(season(8, 8), 8)

      assert button(html) =~ ~s(data-season="complete")
      refute button(html) =~ "btn-outline"
      assert button(html) =~ "btn-success"
      assert html =~ "hero-eye-solid h-5 w-5 shrink-0 text-success"
    end

    test "five of eight ticked: neither" do
      html = render(season(8, 6), 5)

      assert button(html) =~ ~s(data-season="open")
      refute button(html) =~ "btn-success"
      refute html =~ "text-success"
    end

    test "an episode that has not aired has no tick button of its own" do
      html = render(season(8, 6), 6)

      # Six rows can be ticked; the two that are not out yet are marked as such and cannot be.
      assert length(Regex.scan(~r/phx-click="toggle_episode"/, html)) == 6
      assert html =~ "not out yet"
    end
  end
end
