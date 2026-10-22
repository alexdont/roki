defmodule RokiWeb.PosterCachedTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  @item %{type: "movie", id: 7, title: "A", poster: nil, year: "2020"}

  test "a poster of a title with cached sources says so" do
    html =
      render_component(&RokiWeb.PosterComponents.poster/1,
        item: @item,
        cached_titles: MapSet.new([{"movie", 7}])
      )

    assert html =~ "cached"
  end

  test "others, and pages that know nothing, show no tag" do
    for set <- [MapSet.new([{"movie", 8}]), nil] do
      refute render_component(&RokiWeb.PosterComponents.poster/1, item: @item, cached_titles: set) =~
               "cached"
    end
  end

  test "a title in progress says where you stopped, and how much is left" do
    item = Map.merge(@item, %{resume_at: 3579, runtime: 4779})
    html = render_component(&RokiWeb.PosterComponents.poster/1, item: item)

    assert html =~ "59:39"
    assert html =~ "20 min left"
    assert html =~ ~s(data-peek-resume="Continue from 59:39)
  end

  test "without a runtime only the place is shown; before half a minute nothing is" do
    html =
      render_component(&RokiWeb.PosterComponents.poster/1, item: Map.put(@item, :resume_at, 3779))

    assert html =~ "1:02:59"
    refute html =~ "min left"

    refute render_component(&RokiWeb.PosterComponents.poster/1, item: @item) =~ "data-peek-resume"
  end

  test "time helpers" do
    assert RokiWeb.PosterComponents.clock(59) == "0:59"
    assert RokiWeb.PosterComponents.clock(3600) == "1:00:00"
    assert RokiWeb.PosterComponents.left(%{resume_at: 100, runtime: 7300}) == "2 h 0 min left"
  end

  test "episodes and seasons done are drawn on the poster, and the caption can go" do
    ep = Map.merge(@item, %{type: "tv", note: " · 7/13 episodes"})
    html = render_component(&RokiWeb.PosterComponents.poster/1, item: ep, compact: true)
    assert html =~ "7"
    assert html =~ "13"
    assert html =~ "episodes"
    assert html =~ ~s(data-peek-progress="7 of 13 episodes watched")
    assert html =~ ~s(data-peek="tv/7")
    refute html =~ "text-base-content/60"

    seasons = Map.put(ep, :note, "1/3 seasons watched")
    html = render_component(&RokiWeb.PosterComponents.poster/1, item: seasons, compact: true)
    assert html =~ "seasons"
    assert html =~ "width: 33%"
  end

  test "outside the shelf the caption stays" do
    html = render_component(&RokiWeb.PosterComponents.poster/1, item: @item)
    assert html =~ "2020"
  end

  test "a compact poster with no progress shows its rating on the poster instead of a caption" do
    html =
      render_component(&RokiWeb.PosterComponents.poster/1,
        item: Map.put(@item, :vote, 7.46),
        compact: true
      )

    assert html =~ "★ 7.5"
    refute html =~ "2020"
  end

  test "the cached mark is a small dot with a tooltip, not a label" do
    html =
      render_component(&RokiWeb.PosterComponents.poster/1,
        item: @item,
        cached_titles: MapSet.new([{"movie", 7}])
      )

    refute html =~ "⚡ cached"
    assert html =~ ~s(title="Sources cached)
  end
end
