defmodule RokiWeb.CategoryLiveTest do
  use RokiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  alias Roki.Browse

  defp seed(kind, n, ids, more?) do
    items =
      for i <- ids, do: %{id: i, type: "movie", title: "Title #{i}", poster: nil, year: "2020"}

    Roki.Featured.seed(kind, n, items, more?)
  end

  test "popular is the Featured list, on a page of its own, with Load more adding a page", %{
    conn: conn
  } do
    seed(:movies, 1, 1..20, true)
    seed(:movies, 2, 21..40, false)

    {:ok, view, _} = live(conn, "/movies")
    render_async(view, 3000)
    html = render_async(view, 3000)

    assert html =~ "Title 1<" or html =~ "Title 1\""
    refute html =~ "Title 21"
    # No button: the end of the list asks for the next page as it comes into view.
    refute html =~ "Load more"
    assert has_element?(view, "#grid-more[phx-hook=InfiniteScroll][data-active=true]")
    # Each title opens into the card the home page's rows have (its own hook, around the grid).
    assert has_element?(view, "#grid-cards[phx-hook=GridCards] #grid[phx-hook=FillGrid]")
    assert has_element?(view, ~s|#grid [data-card][data-key="movie/1"] [data-card-panel]|)

    render_hook(view, "more", %{})
    html = render_async(view, 3000)
    assert html =~ "Title 21"
    refute has_element?(view, "#grid-more")
  end

  test "the order and the grid size are controls at the top", %{conn: conn} do
    seed(:shows, 1, 1..3, false)
    {:ok, view, html} = live(conn, "/shows")

    for label <- ~w(Popular Newest Oldest), do: assert(html =~ label)
    assert html =~ "Top rated"
    assert has_element?(view, ~s(button[aria-label="Large posters"]))

    render_click(element(view, ~s(button[aria-label="Large posters"])))
    assert_push_event(view, "roki:grid", %{size: "l"})
    assert render(view) =~ "lg:grid-cols-4"
  end

  test "the order is read from the address, never turned into an atom from the input" do
    assert Browse.sort("oldest") == :oldest
    assert Browse.sort("top") == :top
    assert Browse.sort("nonsense") == :popular
    assert Browse.sort(nil) == :popular
  end

  test "the other orders ask TMDB for what is out, with enough votes for the order to mean something" do
    today = ~D[2026-10-22]

    movies = Browse.params(:movies, :oldest, 3, today)
    assert movies[:sort_by] == "primary_release_date.asc"
    assert movies[:"primary_release_date.lte"] == "2026-10-22"
    assert movies[:"vote_count.gte"] == 300
    assert movies[:page] == 3

    anime = Browse.params(:anime, :newest, 1, today)
    assert anime[:sort_by] == "first_air_date.desc"
    assert anime[:with_genres] == 16
    assert anime[:with_original_language] == "ja"

    assert Browse.params(:shows, :top, 1, today)[:sort_by] == "vote_average.desc"
    assert Browse.path(:movies) == "/discover/movie"
    assert Browse.path(:anime) == "/discover/tv"
  end

  test "a genre narrows what TMDB is asked for, in each kind's own terms; popular becomes TMDB's own popularity" do
    today = ~D[2026-10-22]

    assert Browse.params(:movies, :top, 1, today, "horror")[:with_genres] == "27"

    # Shows and anime have no Horror genre: the keyword stands in for it, with no empty genre list.
    shows = Browse.params(:shows, :popular, 1, today, "horror")
    assert shows[:with_keywords] == 315_058
    refute Keyword.has_key?(shows, :with_genres)
    anime = Browse.params(:anime, :popular, 1, today, "horror")
    assert anime[:with_keywords] == 315_058 and anime[:with_genres] == 16
    assert Browse.params(:shows, :newest, 1, today, "scifi")[:with_genres] == "10765"
    # Anime is Animation first, then the genre.
    assert Browse.params(:anime, :newest, 1, today, "action")[:with_genres] == "16,10759"
    assert Browse.params(:anime, :newest, 1, today, nil)[:with_genres] == 16
    assert Browse.params(:movies, :popular, 1, today, "comedy")[:sort_by] == "popularity.desc"
  end

  test "the genre menu is on every kind's page, offers only that kind's genres, and the address carries it",
       %{conn: conn} do
    # Opening these pages caches what the lists answered; the other tests seed their own.
    on_exit(fn ->
      for kind <- [:movies, :shows],
          genre <- [nil, "horror"],
          do: Roki.TTLCache.delete({:browse, kind, :popular, nil, nil, genre, 1})
    end)

    {:ok, _view, html} = live(conn, "/movies")
    assert html =~ "All genres"
    assert html =~ "Horror"
    assert html =~ "&quot;genre&quot;:&quot;horror&quot;"

    {:ok, _view, shows} = live(conn, "/shows")
    assert shows =~ "Sci-Fi"
    # TMDB has no Horror genre for shows, so it is offered through its "horror" keyword; Thriller
    # has neither.
    assert shows =~ "&quot;genre&quot;:&quot;horror&quot;"
    refute shows =~ "&quot;genre&quot;:&quot;thriller&quot;"

    {:ok, _view, picked} = live(conn, "/movies?genre=horror")
    assert picked =~ ">Horror<"

    # A genre this kind does not have is ignored, not trusted.
    {:ok, _view, bogus} = live(conn, "/shows?genre=thriller")
    assert bogus =~ "All genres"
  end

  test "a list that is already held is in the first render, before anything is asked of TMDB", %{
    conn: conn
  } do
    key = {:browse, :movies, :top, nil, nil, nil, 1}
    items = [%{id: 77_001, type: "movie", title: "Held Film", poster: nil, year: "2001"}]
    Roki.TTLCache.put(key, 60, {:ok, {items, false}})
    on_exit(fn -> Roki.TTLCache.delete(key) end)

    assert {:ok, :held, [%{title: "Held Film"}], false} =
             (case Roki.Browse.peek(:movies, :top, 1) do
                {:ok, got, more?} -> {:ok, :held, got, more?}
                other -> other
              end)

    {:ok, _view, html} = live(conn, "/movies?sort=top")
    assert html =~ "Held Film"
    assert html =~ ~s(href="/title/movie/77001")
  end
end
