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

    # The chevrons are edge strips as tall as the posters, always there to be hit when there is more
    # to scroll to (not appearing only once the pointer is in the row), and above an opened card: a
    # pointer on one never opens a poster.
    assert html =~ ~r/data-row-next[^>]*z-30 hidden w-14/s
    assert html =~ "group-data-[end=false]/row:flex"
    refute html =~ "rounded-full bg-black/55"
    # The rows are on every width now: a phone swipes them.
    refute html =~ ~r/class="hidden space-y-9/
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

  describe "the card that opens on a poster" do
    test "carries what the hook needs: the key, the player slot, Play, save and more", %{
      html: html
    } do
      assert html =~ ~s(data-key="movie/1")
      assert html =~ ~s(data-key="tv/3")
      # The card is one template for the page (the layout); each poster carries what fills it.
      assert html =~ ~s(data-title="Title 1")
      assert html =~ ~s(data-play-href="/sources/movie/1?auto=1")
      # A show's Play is its page, where "continue" is worked out.
      refute html =~ "/sources/tv/3"

      card = render_component(&RokiWeb.PosterComponents.card_template/1, %{})
      assert card =~ ~r/<template[^>]*id="card-template"/
      # The player is made by the hook, and the page must never touch it again.
      assert card =~ ~r/data-card-trailer[^>]*phx-update="ignore"/
      assert card =~ "data-card-overview"
      assert card =~ "data-card-more"
    end

    test "save is a button for someone signed in and a way to log in for a visitor" do
      shelves = %{movies: shelf([item(1, "movie", 7.5)]), shows: shelf([]), anime: shelf([])}

      render = fn signed_in? ->
        render_component(&RokiWeb.FeaturedLive.shelf_rows/1,
          shelves: shelves,
          seen: MapSet.new(),
          upcoming: %{},
          cached_titles: nil,
          signed_in?: signed_in?
        )
      end

      # The one card carries both; the poster says which the hook shows.
      assert render.(true) =~ ~s(data-signed="true")
      assert render.(false) =~ ~s(data-signed="false")
      card = render_component(&RokiWeb.PosterComponents.card_template/1, %{})
      assert card =~ ~r/data-signed-only[^>]*data-card-save/s
      assert card =~ ~r/data-signed-only[^>]*data-card-watched/s
      assert card =~ ~r/data-guest-only[^>]*href="\/phoenix_kit\/users\/log-in"/s
    end

    test "the rows keep the old hover card off their posters, and the card that opens is no taller",
         %{
           html: html
         } do
      assert html =~ "data-card-row"
      # The card that opens is exactly as tall as the poster (the hook places it `inset-0` in a
      # row): no gap grows under a row.
      refute html =~ "-bottom-16"
      refute html =~ "data-card-panel"
    end
  end

  describe "the Lists row" do
    defp list(i, watched \\ nil),
      do: %{
        slug: "list-#{i}",
        name: "List #{i}",
        kind: :curated,
        count: 50,
        watched: watched,
        keys: []
      }

    defp lists_html(lists, total, posters \\ %{}, more? \\ false) do
      render_component(&RokiWeb.FeaturedLive.lists_row/1,
        lists: lists,
        total: total,
        posters: posters,
        more?: more?
      )
    end

    test "is a scrolling row of its own with a tile that opens the rest" do
      html = lists_html(Enum.map(1..12, &list/1), 70)

      assert html =~ ~s(id="row-lists")
      assert html =~ ~s(phx-hook="ShelfRow")
      assert html =~ "data-row-scroller"
      assert length(Regex.scan(~r/href="\/lists\/list-\d+"/, html)) == 12
      assert html =~ "All 70 lists"
      assert html =~ "See All 70"
      assert html =~ ~s(href="/lists")
    end

    test "says whether there are more to ask for, and what to ask for them as" do
      html = lists_html(Enum.map(1..6, &list/1), 70, %{}, true)
      assert html =~ ~s(data-kind="lists")
      assert html =~ ~s(data-more="true")

      done = lists_html(Enum.map(1..6, &list/1), 6, %{}, false)
      assert done =~ ~s(data-more="false")
    end

    test "draws a list's posters when the site has them, and its progress when it is known" do
      html =
        lists_html([list(1, 25)], 1, %{"list-1" => ["https://image.tmdb.org/t/p/w342/a.jpg"]})

      assert html =~ "a.jpg"
      assert html =~ "25/50 watched"
      assert html =~ "width: 50%"
    end

    test "has no posters or progress line to show for a list with neither" do
      html = lists_html([list(1)], 1)
      refute html =~ "<img"
      refute html =~ "width: "
    end
  end
end
