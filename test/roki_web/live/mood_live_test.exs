defmodule RokiWeb.MoodLiveTest do
  use RokiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    items = [
      %{id: 501, type: "movie", title: "Mood Film", poster: nil, year: "2019", popularity: 9.0, vote: 7.1},
      %{id: 502, type: "tv", title: "Mood Show", poster: nil, year: "2021", popularity: 8.0, vote: 8.1}
    ]

    Roki.TTLCache.put({:mood, 2, "scared", :all, :popular, 1}, 60, {:ok, {items, false}})
    Roki.TTLCache.put({:mood, 2, "scared", :movies, :popular, 1}, 60, {:ok, {Enum.take(items, 1), false}})

    on_exit(fn ->
      Roki.TTLCache.delete({:mood, 2, "scared", :all, :popular, 1})
      Roki.TTLCache.delete({:mood, 2, "scared", :movies, :popular, 1})
    end)

    :ok
  end

  test "a mood page lists films and shows together, with a held page in the first render", %{conn: conn} do
    {:ok, view, html} = live(conn, "/mood/scared")
    assert html =~ "Be scared"
    assert html =~ ~s(href="/title/movie/501")
    assert html =~ ~s(href="/title/tv/502")

    # Narrowed to films: the address carries it, and only the film is left.
    view |> element(~s(button[phx-click="kind"][phx-value-kind="movies"])) |> render_click()
    assert_patch(view, "/mood/scared?kind=movies")
    html = render(view)
    assert html =~ "Mood Film"
    refute html =~ "Mood Show"
  end

  test "a mood that does not exist goes home", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/home"}}} = live(conn, "/mood/nothing")
  end

  test "the home page offers every mood and the popular grid", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/home")
    assert html =~ "What are you feeling like today?"
    for m <- Roki.Mood.all(), do: assert(html =~ ~s(href="/mood/#{m.slug}"))
    assert html =~ ~s(data-mood="scared")
  end
end
