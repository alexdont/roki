defmodule RokiWeb.MoodLiveTest do
  use RokiWeb.ConnCase, async: false

  import Phoenix.LiveViewTest

  setup do
    items = [
      %{
        id: 501,
        type: "movie",
        title: "Mood Film",
        poster: nil,
        year: "2019",
        popularity: 9.0,
        vote: 7.1
      },
      %{
        id: 502,
        type: "tv",
        title: "Mood Show",
        poster: nil,
        year: "2021",
        popularity: 8.0,
        vote: 8.1
      }
    ]

    Roki.TTLCache.put(Roki.Mood.key("scared", :all, :popular, 1), 60, {:ok, {items, false}})

    Roki.TTLCache.put(
      Roki.Mood.key("scared", :movies, :popular, 1),
      60,
      {:ok, {Enum.take(items, 1), false}}
    )

    on_exit(fn ->
      Roki.TTLCache.delete(Roki.Mood.key("scared", :all, :popular, 1))
      Roki.TTLCache.delete(Roki.Mood.key("scared", :movies, :popular, 1))
    end)

    :ok
  end

  test "a mood page lists films and shows together, with a held page in the first render", %{
    conn: conn
  } do
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
    assert html =~ "What are you in the mood for?"
    for m <- Roki.Mood.all(), do: assert(html =~ ~s(href="/mood/#{m.slug}"))
    assert html =~ ~s(data-mood="scared")
  end

  test "a mood page's top carries the mood's number and name, in the site's face, with no pictograph",
       %{conn: conn} do
    {:ok, view, _html} = live(conn, "/mood/scared")
    band = view |> element("section.z-20") |> render()
    scared = Roki.Mood.get("scared")

    assert band =~ ~r/>\s*#{Roki.Mood.number("scared")}\s*</
    assert has_element?(view, "section.z-20 h1", scared.label)
    # Its colour is in the line above the name; the name is not in a typeface of its own any more.
    assert band =~ "color: hsl(#{scared.hue} 90% 62%)"
    refute band =~ "mood-title"
    refute band =~ Phoenix.HTML.safe_to_string(Phoenix.HTML.html_escape(scared.font))

    # Nothing in the band is a pictograph. (The posters below it carry a plain "★" for a rating,
    # which is type, not a picture.)
    refute band =~ ~r/[\x{1F000}-\x{1FAFF}\x{2600}-\x{27BF}\x{FE0F}]/u
  end

  test "a mood page carries its mood's animation over the top, a little lighter", %{conn: conn} do
    {:ok, view, _} = live(conn, "/mood/cry")

    assert has_element?(
             view,
             ~s(#mood-fx[phx-hook="MoodFx"][data-mood="cry"][data-amount="0.7"] canvas#mood-fx-canvas)
           )

    assert has_element?(view, "#mood-fx section[data-fx-stage] h1", "Have a good cry")
  end

  test "a season's page has no animation", %{conn: conn} do
    {:ok, view, _} = live(conn, "/mood/halloween")
    refute has_element?(view, "#mood-fx-canvas")
  end

  test "a season's page says it is in season and has no search box", %{conn: conn} do
    items = [
      %{
        id: 601,
        type: "movie",
        title: "A Season Film",
        poster: nil,
        year: "2019",
        popularity: 1.0,
        vote: 7.0
      }
    ]

    key = Roki.Mood.key("halloween", :all, :popular, 1)
    Roki.TTLCache.put(key, 60, {:ok, {items, false}})
    on_exit(fn -> Roki.TTLCache.delete(key) end)

    {:ok, view, _} = live(conn, "/mood/halloween")
    html = render_async(view, 3000)

    assert html =~ "In season now"
    assert html =~ "Halloween"
    assert html =~ "A Season Film"
    refute html =~ "Tonight I want to"
    refute html =~ ~s(phx-submit="search")
  end
end
