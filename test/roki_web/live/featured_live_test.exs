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

    {:ok, view, _} = live(conn, "/")
    render_async(view, 3000)
    html = render_async(view, 3000)

    assert html =~ "A Seeded Film"
    assert html =~ ~s(href="/title/movie/4242")
  end

  test "the popular grid is short and leads to each kind's own page; there is no load more", %{
    conn: conn
  } do
    for kind <- Roki.Featured.kinds() do
      items =
        for i <- 1..20, do: %{id: i, type: "movie", title: "Film #{i}", poster: nil, year: "2020"}

      Roki.Featured.seed(kind, 1, items, true)
    end

    {:ok, view, _} = live(conn, "/")
    render_async(view, 3000)
    html = render_async(view, 3000)

    for kind <- ~w(movies shows anime), do: assert(html =~ ~s(href="/#{kind}"))
    refute html =~ "Popular right now"
    refute html =~ "Load more"

    # The rows carry the whole page, to scroll along, on every width.
    assert has_element?(view, ~s|#row-movies [data-peek-title="Film 13"]|)
    assert has_element?(view, ~s|#row-movies [data-peek-title="Film 20"]|)
  end

  describe "activity row" do
    defp signed_in(name) do
      {:ok, user} =
        PhoenixKit.Users.Auth.register_user(%{
          "email" => "#{name}@example.com",
          "password" => "a-long-enough-password-123",
          "username" => name
        })

      token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
      {user, Plug.Test.init_test_session(build_conn(), %{user_token: token})}
    end

    test "a group of films is one card that opens the list of them" do
      {user, conn} = signed_in("actrow")

      for {id, title} <- [{901, "Group One"}, {902, "Group Two"}] do
        Roki.Activity.insert_now(user.uuid, %{type: "movie", tmdb_id: id, title: title}, "saved")
      end

      {:ok, view, _} = live(conn, "/")
      html = render_async(view, 3000)
      assert html =~ "saved 2 films"
      assert html =~ "See which"
      # Full width on a wide screen: the section's wrapper has no maximum width there.
      assert has_element?(view, ~s|div[class~="lg:max-w-none"] section[aria-label="Activity"]|)
      refute html =~ ~s(aria-label="Titles in this group")

      html = view |> element(~s(button[phx-click="activity_open"])) |> render_click()
      assert html =~ ~s(aria-label="Titles in this group")
      assert html =~ ~s(href="/title/movie/901")
      assert html =~ ~s(href="/title/movie/902")

      html = render_click(view, "activity_close", %{})
      refute html =~ ~s(aria-label="Titles in this group")
    end

    test "someone in the player leads the row: live while it plays, paused when it stops" do
      {user, conn} = signed_in("actlive")
      what = %{type: "tv", tmdb_id: 77, title: "Lupin", poster: nil, season: 2, episode: 5}
      page = spawn(fn -> Process.sleep(:infinity) end)

      {:ok, view, _} = live(conn, "/")
      render_async(view, 3000)
      refute render(view) =~ "is watching"

      Roki.NowWatching.report(user.uuid, page, what, 754, 2700, false)
      Roki.NowWatching.list()
      html = render(view)
      assert html =~ "is watching"
      assert html =~ "Lupin S2E5"
      assert html =~ "12:34"
      assert html =~ "45:00"
      assert html =~ "Live"

      Roki.NowWatching.report(user.uuid, page, what, 760, 2700, true)
      Roki.NowWatching.list()
      html = render(view)
      assert html =~ "paused"
      assert html =~ "Paused"

      Process.exit(page, :kill)
      Roki.NowWatching.list()
      refute render(view) =~ "Lupin S2E5"
    end

    test "a single title is a link to its page" do
      {user, conn} = signed_in("actsingle")

      Roki.Activity.insert_now(
        user.uuid,
        %{type: "movie", tmdb_id: 903, title: "Solo Film"},
        "saved"
      )

      {:ok, view, _} = live(conn, "/")
      html = render_async(view, 3000)
      assert html =~ ~s(href="/title/movie/903")
      refute html =~ "See which"
    end
  end

  describe "the mood picker" do
    @emoji ~r/[\x{1F000}-\x{1FAFF}\x{2190}-\x{21FF}\x{2300}-\x{23FF}\x{2600}-\x{27BF}\x{FE0F}]/u

    test "has no emoji in it: the moods are their names and their colours", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      picker = view |> element("#mood-picker") |> render()

      refute picker =~ @emoji

      for mood <- Roki.Mood.all() do
        assert picker =~ mood.label
        assert has_element?(view, ~s(#mood-picker [data-mood-chip="#{mood.slug}"]))
      end
    end

    test "opens on a random mood, the tabs in their own order", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")

      [start] =
        Regex.run(~r/id="mood-picker"[^>]*data-start="([^"]+)"/, html, capture: :all_but_first)

      mood = Enum.find(Roki.Mood.all(), &(&1.slug == start))
      assert mood

      assert has_element?(
               view,
               ~s(#mood-picker [data-mood-chip="#{start}"][aria-selected="true"])
             )

      assert has_element?(view, ~s(#mood-picker [data-mood="#{start}"] h1), mood.label)
      assert has_element?(view, ~s(#mood-picker [data-mood-chip][aria-selected="true"]))

      tabs = Regex.scan(~r/data-mood-chip="([^"]+)"/, render(view), capture: :all_but_first)
      assert List.flatten(tabs) == Enum.map(Roki.Mood.all(), & &1.slug)
    end

    test "connecting keeps the mood the first paint chose", %{conn: conn} do
      [_, second | _] = Roki.Mood.all()
      conn = put_connect_params(conn, %{"mood" => second.slug})
      {:ok, view, _} = live(conn, "/")
      assert has_element?(view, ~s(#mood-picker[data-start="#{second.slug}"]))
    end
  end

  describe "the mood animations" do
    test "sit over the carousel on their own canvas, clicks passing through", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")

      assert has_element?(
               view,
               ~s(#mood-fx[phx-hook="MoodFx"] canvas#mood-fx-canvas.pointer-events-none)
             )

      assert has_element?(view, "#mood-fx #mood-picker")
    end

    test "are switched off site-wide by config", %{conn: conn} do
      Application.put_env(:roki, :mood_fx, false)
      on_exit(fn -> Application.delete_env(:roki, :mood_fx) end)

      {:ok, view, _} = live(conn, "/")
      refute has_element?(view, "#mood-fx-canvas")
      refute has_element?(view, ~s([phx-hook="MoodFx"]))
      assert has_element?(view, "#mood-picker")
    end
  end

  describe "the header" do
    test "floats over the picture on the home page, with a search field in it", %{conn: conn} do
      {:ok, view, html} = live(conn, "/")
      assert html =~ "site-header--overlay"
      assert has_element?(view, ~s|header form[role="search"] input#search-input-wide[name="q"]|)
      # The icon that opens the search under the bar is still there for narrower screens.
      assert has_element?(view, ~s|header button[aria-label="Search"].lg\\:hidden|)
    end

    test "stays an ordinary frosted bar on the pages without a picture behind it, search field included",
         %{conn: conn} do
      {:ok, view, html} = live(conn, "/study")
      refute html =~ "site-header--overlay"
      assert has_element?(view, ~s|header form[role="search"] input#search-input-wide|)
    end
  end

  describe "the Lists row" do
    test "starts with six lists and draws six more each time it is asked", %{conn: conn} do
      for kind <- Roki.Featured.kinds() do
        Roki.Featured.seed(kind, 1, [
          %{id: 1, type: "movie", title: "Film 1", poster: nil, year: "2020"}
        ])
      end

      {:ok, view, _} = live(conn, "/")
      render_async(view, 3000)
      render_async(view, 3000)

      tiles = fn ->
        view
        |> element("#row-lists")
        |> render()
        |> then(&length(Regex.scan(~r/href="\/lists\/[^"]+"/, &1)))
      end

      assert tiles.() == 6
      assert has_element?(view, ~s|#row-lists[data-more="true"]|)

      render_hook(view, "row_more", %{"kind" => "lists"})
      assert tiles.() == 12

      # Asking for what does not exist does nothing.
      render_hook(view, "row_more", %{"kind" => "nonsense"})
      assert tiles.() == 12
    end
  end

  describe "the Seasonal row" do
    setup do
      season = Roki.Seasonal.current()

      on_exit(fn ->
        for kind <- [:all, :movies, :shows, :anime],
            do: Roki.TTLCache.delete(Roki.Mood.key(season.slug, kind, :popular, 1))
      end)

      %{season: season}
    end

    test "is last, named for the season, and leads to the season's own page", %{
      conn: conn,
      season: season
    } do
      items =
        for i <- 1..25,
            do: %{id: 900 + i, type: "movie", title: "Seasonal #{i}", poster: nil, year: "2020"}

      Roki.TTLCache.put(Roki.Mood.key(season.slug, :all, :popular, 1), 60, {:ok, {items, true}})

      {:ok, view, _} = live(conn, "/")
      render_async(view, 3000)
      html = render_async(view, 3000)

      assert html =~ "Seasonal · #{season.label}"
      assert html =~ ~s(href="/mood/#{season.slug}")
      assert html =~ ~s(href="/title/movie/901")
      # twenty, like the rest
      assert html =~ ~s(href="/title/movie/920")
      refute html =~ ~s(href="/title/movie/921")
    end

    test "is not drawn when the season could not be read", %{conn: conn} do
      {:ok, view, _} = live(conn, "/")
      render_async(view, 3000)
      html = render_async(view, 3000)
      refute html =~ "Seasonal ·"
    end
  end
end
