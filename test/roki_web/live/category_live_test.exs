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
    assert html =~ "Load more"
    refute html =~ "Title 21"

    view |> element("button", "Load more") |> render_click()
    html = render_async(view, 3000)
    assert html =~ "Title 21"
    refute html =~ "Load more"
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
end
