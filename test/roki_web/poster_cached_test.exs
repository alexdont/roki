defmodule RokiWeb.PosterCachedTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  @item %{type: "movie", id: 7, title: "A", poster: nil, year: "2020"}

  test "a poster never marks cached sources: the play button does" do
    for set <- [MapSet.new([{"movie", 7}]), MapSet.new([{"movie", 8}]), nil] do
      html =
        render_component(&RokiWeb.PosterComponents.poster/1, item: @item, cached_titles: set)

      refute html =~ "cached"
      refute html =~ "⚡"
    end
  end

  test "a watched poster has the eye in its corner, unless the page leaves it out" do
    watched = Map.put(@item, :vote, 7.4)

    with_mark =
      render_component(&RokiWeb.PosterComponents.poster/1,
        item: watched,
        seen: true,
        compact: true
      )

    assert with_mark =~ "hero-eye-solid"
    assert with_mark =~ "opacity-50"

    # The cards on the home page and the grids: greyed out says it; the score takes the corner.
    bare =
      render_component(&RokiWeb.PosterComponents.poster/1,
        item: watched,
        seen: true,
        compact: true,
        rating_corner: :top_left,
        mark?: false
      )

    refute bare =~ "hero-eye-solid"
    assert bare =~ "opacity-50"
    assert bare =~ "★"
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

  test "the number says seasons but the bar follows episodes once they are known" do
    show = Map.merge(@item, %{type: "tv", note: " · 1/3 seasons watched"})

    before = render_component(&RokiWeb.PosterComponents.poster/1, item: show, compact: true)
    assert before =~ "width: 33%"

    known = Map.merge(show, %{ep_done: 8, ep_total: 22})
    html = render_component(&RokiWeb.PosterComponents.poster/1, item: known, compact: true)
    assert html =~ "seasons"
    assert html =~ "width: 36%"
    assert html =~ ~s(data-peek-progress="1 of 3 seasons watched · 8 of 22 episodes")
  end

  test "a title that is not out yet gets a red glow with its date and how far off it is" do
    date = Date.add(Date.utc_today(), 57)
    text = "Not out yet: #{Calendar.strftime(date, "%-d %b %Y")} (in 57 days)"

    html =
      render_component(&RokiWeb.PosterComponents.poster/1,
        item: @item,
        upcoming: %{{"movie", 7} => date}
      )

    assert html =~ "from-error"
    assert html =~ ~s(title="#{text}")
    assert html =~ ~s(data-peek-due="#{text}")

    refute render_component(&RokiWeb.PosterComponents.poster/1,
             item: @item,
             upcoming: %{{"movie", 8} => date}
           ) =~ "from-error"
  end

  test "tomorrow and today are said as words" do
    for {offset, word} <- [{1, "(tomorrow)"}, {0, "(today)"}] do
      html =
        render_component(&RokiWeb.PosterComponents.poster/1,
          item: @item,
          upcoming: %{{"movie", 7} => Date.add(Date.utc_today(), offset)}
        )

      assert html =~ word
    end
  end
end
