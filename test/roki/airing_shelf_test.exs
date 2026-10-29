defmodule Roki.AiringShelfTest do
  @moduledoc """
  A show is not caught up while its season is still airing.

  Laev counts a season as watched through once the episodes that have *aired* are watched, so a
  show with six of eight episodes out and six marked was "caught up" and sank down the list, with
  two episodes to come that the viewer was following it for. VisionQuest, 2026.
  """
  use ExUnit.Case, async: false

  alias Roki.Laev, as: RLaev

  @today ~D[2026-10-29]

  # A TMDB card, as laev keeps one.
  defp card(opts \\ []) do
    %{
      "id" => Keyword.get(opts, :id, 4242),
      "name" => "Airing Show",
      "status" => Keyword.get(opts, :status, "Returning Series"),
      "first_air_date" => "2026-10-13",
      "last_air_date" => Keyword.get(opts, :last, "2026-10-27"),
      "seasons" =>
        Keyword.get(opts, :seasons, [
          %{"season_number" => 1, "episode_count" => 8, "air_date" => "2026-10-13"}
        ])
    }
  end

  defp aired(map), do: fn season -> Map.get(map, season) end

  describe "airing?/3" do
    test "a season that has begun, has episodes to come, and had one lately, is airing" do
      assert RLaev.airing?(card(), aired(%{1 => 6}), @today)
    end

    test "a season with every episode out is not" do
      refute RLaev.airing?(card(), aired(%{1 => 8}), @today)
    end

    test "more out than TMDB counts is not (its count lags a finished season)" do
      refute RLaev.airing?(card(), aired(%{1 => 9}), @today)
    end

    test "a season laev has never looked at is not known to be airing" do
      refute RLaev.airing?(card(), aired(%{}), @today)
    end

    test "a season that has not begun is not airing: that is a show between seasons" do
      season_two = [
        %{"season_number" => 1, "episode_count" => 8, "air_date" => "2026-03-01"},
        %{"season_number" => 2, "episode_count" => 8, "air_date" => "2027-01-10"}
      ]

      # Season one is complete; season two, announced, has not started.
      refute RLaev.airing?(
               card(seasons: season_two, last: "2026-04-20"),
               aired(%{1 => 8, 2 => 0}),
               @today
             )
    end

    test "an announced season with no date is not airing either" do
      seasons = [
        %{"season_number" => 1, "episode_count" => 8, "air_date" => "2026-03-01"},
        %{"season_number" => 2, "episode_count" => 8, "air_date" => nil}
      ]

      refute RLaev.airing?(card(seasons: seasons, last: "2026-04-20"), aired(%{1 => 8}), @today)
    end

    test "specials are not a season" do
      seasons = [
        %{"season_number" => 0, "episode_count" => 5, "air_date" => "2026-01-01"},
        %{"season_number" => 1, "episode_count" => 8, "air_date" => "2026-10-13"}
      ]

      refute RLaev.airing?(card(seasons: seasons), aired(%{0 => 1, 1 => 8}), @today)
    end

    test "a season quiet for four months is on a break or is not coming back, not airing" do
      refute RLaev.airing?(card(last: "2026-06-01"), aired(%{1 => 6}), @today)
      # …but three weeks of quiet is a gap between episodes.
      assert RLaev.airing?(card(last: "2026-10-08"), aired(%{1 => 6}), @today)
    end

    test "a card with no last air date is not known to be airing" do
      refute RLaev.airing?(Map.delete(card(), "last_air_date"), aired(%{1 => 6}), @today)
    end

    test "any one season still airing is enough" do
      seasons = [
        %{"season_number" => 1, "episode_count" => 8, "air_date" => "2026-03-01"},
        %{"season_number" => 2, "episode_count" => 10, "air_date" => "2026-10-13"}
      ]

      assert RLaev.airing?(card(seasons: seasons), aired(%{1 => 8, 2 => 6}), @today)
    end
  end

  describe "shift_tally/2" do
    @tally %{behind: 21, caught_up: 5, held: 2, series_finished: 9, anime_finished: 3}

    test "moves shows from caught up to in progress, and nothing else" do
      assert RLaev.shift_tally(@tally, 2) ==
               %{behind: 23, caught_up: 3, held: 2, series_finished: 9, anime_finished: 3}
    end

    test "with nothing moved it is the tally as laev has it" do
      assert RLaev.shift_tally(@tally, 0) == @tally
    end

    test "never counts below zero" do
      assert RLaev.shift_tally(%{@tally | caught_up: 1}, 3).caught_up == 0
    end
  end

  describe "the shelf" do
    setup do
      dir = Path.join(System.tmp_dir!(), "airing-shelf-#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)
      %{scope: Laev.Scope.new(dir, %{tmdb_key: "test"}), dir: dir}
    end

    # `marked` of the season's episodes marked watched; `out` of them aired; `total` in the season.
    defp show(scope, id, opts) do
      marked = Keyword.fetch!(opts, :marked)

      Laev.Scope.run(scope, fn ->
        Laev.Cards.put_many(%{
          {"tv", id} =>
            card(
              id: id,
              last: Keyword.get(opts, :last, "2026-10-27"),
              status: Keyword.get(opts, :status, "Returning Series"),
              seasons: [
                %{
                  "season_number" => 1,
                  "episode_count" => Keyword.get(opts, :total, 8),
                  "air_date" => "2026-10-13"
                }
              ]
            )
        })

        Laev.Seasons.put(id, 1, Keyword.get(opts, :out, 6))
        Laev.Seasons.put_aired_seasons(id, 1)

        for n <- 1..marked//1 do
          Laev.Position.set_watched(%{type: "tv", tmdb_id: id, season: 1, episode: n}, true)
        end
      end)
    end

    defp shelf(scope) do
      Laev.Scope.run(scope, fn ->
        {rows, moved} = RLaev.shelf_rows()

        placed =
          Enum.reduce(rows, {:behind, %{}}, fn
            marker, {_s, acc} when marker in [:caught_up, :on_hold] ->
              {marker, acc}

            row, {sec, acc} when is_map(row) ->
              {sec, Map.put(acc, row.id, {sec, String.trim(row[:note] || "")})}

            _, state ->
              state
          end)
          |> elem(1)

        {placed, moved}
      end)
    end

    test "a show with every aired episode watched and two still to come stays in progress", %{
      scope: scope
    } do
      show(scope, 4242, marked: 6, out: 6, total: 8)

      {placed, moved} = shelf(scope)

      assert placed[4242] == {:behind, "· 6/8 episodes watched"}
      assert moved == 1
    end

    # The premise, and the way out of this module: when laev itself stops filing a show whose season
    # is still airing as caught up, this fails — and the correction here (`Roki.Laev.shelf_rows/0`,
    # `shift_tally/2`, `airing?/3`) has done its job and can be deleted.
    test "laev on its own still files that same show as caught up", %{scope: scope} do
      show(scope, 4242, marked: 6, out: 6, total: 8)

      sections =
        Laev.Scope.run(scope, fn ->
          for %{id: 4242} = row <- Laev.Shelf.rows(), is_map(row), do: Laev.Shelf.section_of(row)
        end)

      assert sections == [:caught_up],
             "laev now keeps a show with episodes still to come in progress: delete the correction in Roki.Laev"
    end

    test "and so does the one a step behind it, which always did", %{scope: scope} do
      show(scope, 4242, marked: 5, out: 6, total: 8)

      {placed, moved} = shelf(scope)

      assert placed[4242] == {:behind, "· 5/8 episodes watched"}
      assert moved == 0
    end

    test "a show whose season has finished airing and is watched through is caught up", %{
      scope: scope
    } do
      show(scope, 4242, marked: 8, out: 8, total: 8)

      {placed, moved} = shelf(scope)

      assert {:caught_up, note} = placed[4242]
      assert note =~ "caught up"
      assert moved == 0
    end

    test "a show on a long break, watched through to its last episode, is caught up", %{
      scope: scope
    } do
      show(scope, 4242, marked: 6, out: 6, total: 8, last: "2026-05-01")

      {placed, moved} = shelf(scope)

      assert {:caught_up, _} = placed[4242]
      assert moved == 0
    end

    test "the show's own mark still takes it off the watchlist, which is what completed means", %{
      scope: scope
    } do
      show(scope, 4242, marked: 6, out: 6, total: 8)

      Laev.Scope.run(scope, fn ->
        Laev.Position.set_watched(%{type: "tv", tmdb_id: 4242, season: nil, episode: nil}, true)
      end)

      {placed, _moved} = shelf(scope)

      refute Map.has_key?(placed, 4242)
    end
  end

  describe "Roki.Watch.over?/2" do
    # `episodes/3`'s shape: [{season number, [episode]}]
    defp eps(list), do: for(aired? <- list, do: %{aired?: aired?})

    defp title(status, seasons \\ [%{number: 1, air_date: "2026-03-01"}]),
      do: %{status: status, seasons: seasons}

    test "a series that ended, with every episode out, is over" do
      assert Roki.Watch.over?(title("Ended"), [{1, eps([true, true, true])}])
      assert Roki.Watch.over?(title("Canceled"), [{1, eps([true, true])}])
    end

    test "a series still returning is never over, however much of it is watched" do
      refute Roki.Watch.over?(title("Returning Series"), [{1, eps([true, true, true])}])
      refute Roki.Watch.over?(title("In Production"), [{1, eps([true])}])
    end

    test "one with an episode still to air is not over, whatever TMDB calls it" do
      refute Roki.Watch.over?(title("Ended"), [{1, eps([true, true, false])}])
    end

    test "one with another season announced is not over" do
      seasons = [%{number: 1, air_date: "2026-03-01"}, %{number: 2, air_date: "2027-03-01"}]
      refute Roki.Watch.over?(title("Ended", seasons), [{1, eps([true, true])}])
    end

    test "specials do not count as a season to come" do
      seasons = [%{number: 0, air_date: nil}, %{number: 1, air_date: "2026-03-01"}]
      assert Roki.Watch.over?(title("Ended", seasons), [{1, eps([true, true])}])
    end

    test "a season with no episodes listed is not known to be finished" do
      refute Roki.Watch.over?(title("Ended"), [{1, []}])
    end
  end
end
