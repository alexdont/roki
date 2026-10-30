defmodule RokiWeb.HomeRowsTest do
  @moduledoc """
  The home page on a wide screen: one scrolling row each for films, shows and anime, the score in
  the top left of each poster and no caption under it. (The phone keeps its grid; the real layout is
  measured by `test/e2e/mood_layout.js`.)
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  defp item(id, type, vote),
    do: %{id: id, type: type, title: "Title #{id}", poster: nil, vote: vote, year: "2026"}

  defp shelf(items, loading? \\ false),
    do: %{items: items, page: 1, more?: true, loading?: loading?}

  defp rows(shelves) do
    render_component(&RokiWeb.FeaturedLive.shelf_rows/1,
      shelves: shelves,
      seen: MapSet.new(),
      upcoming: %{},
      cached_titles: nil
    )
  end

  setup do
    {:ok,
     html:
       rows(%{
         movies: shelf([item(1, "movie", 7.5), item(2, "movie", 6.0)]),
         shows: shelf([item(3, "tv", 8.2)]),
         anime: shelf([])
       })}
  end

  test "a row each for films, shows and anime, each its own scroller", %{html: html} do
    for kind <- ~w(movies shows anime) do
      assert html =~ ~s(id="row-#{kind}")
    end

    assert length(Regex.scan(~r/phx-hook="ShelfRow"/, html)) == 3
    assert length(Regex.scan(~r/data-row-scroller/, html)) == 3
    assert html =~ "Trending Movies" and html =~ "Trending Shows" and html =~ "Anime Airing Now"
  end

  test "See All goes to each list, and the chevrons are the row's own", %{html: html} do
    for href <- ~w(/movies /shows /anime), do: assert(html =~ ~s(href="#{href}"))
    assert length(Regex.scan(~r/data-row-next/, html)) == 3
    assert length(Regex.scan(~r/data-row-prev/, html)) == 3
    # Only on a wide screen.
    assert html =~ ~r/class="hidden [^"]*lg:block"/
  end

  test "the score is in the top left of a poster, with no caption under it", %{html: html} do
    assert html =~
             ~r/absolute left-1.5 top-1.5 flex items-center gap-1[^>]*>\s*<span[^>]*>★<\/span>7.5/

    assert html =~ "8.2"
    refute html =~ ~s(class="truncate text-sm font-medium")
  end

  test "a row still on its way shows placeholders, not a gap" do
    html = rows(%{movies: shelf([], true), shows: shelf([], true), anime: shelf([], true)})
    assert length(Regex.scan(~r/animate-pulse/, html)) == 27
  end

  test "a poster gives the top left to a watched tick and the score moves down" do
    html =
      render_component(&RokiWeb.PosterComponents.poster/1,
        item: item(9, "movie", 7.1),
        seen: true,
        compact: true,
        rating_corner: :top_left
      )

    refute html =~ "left-1.5 top-1.5 flex items-center gap-1"
    assert html =~ "bottom-1.5 right-1.5"
  end
end
