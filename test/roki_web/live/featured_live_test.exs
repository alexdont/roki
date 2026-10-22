defmodule RokiWeb.FeaturedLiveTest do
  use RokiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  # The shelves are drawn by function components inside the page: anything the page assigns
  # for its posters has to be handed down to them. A page with no titles never notices.
  test "the featured page draws its posters, linked to their title pages", %{conn: conn} do
    for kind <- Roki.Featured.kinds() do
      items = [%{id: 4242, type: "movie", title: "A Seeded Film", poster: nil, year: "2020"}]
      Roki.Featured.seed(kind, 1, items)
    end

    {:ok, view, _} = live(conn, "/home")
    render_async(view, 3000)
    html = render_async(view, 3000)

    assert html =~ "A Seeded Film"
    assert html =~ ~s(href="/title/movie/4242")
  end

  test "each shelf is short and leads to its own page; there is no load more", %{conn: conn} do
    for kind <- Roki.Featured.kinds() do
      items =
        for i <- 1..20, do: %{id: i, type: "movie", title: "Film #{i}", poster: nil, year: "2020"}

      Roki.Featured.seed(kind, 1, items, true)
    end

    {:ok, view, _} = live(conn, "/home")
    render_async(view, 3000)
    html = render_async(view, 3000)

    for kind <- ~w(movies shows anime), do: assert(html =~ ~s(href="/#{kind}"))
    assert html =~ "See more"
    refute html =~ "Load more"
    assert html =~ "Film 16"
    refute html =~ "Film 17"
  end
end
