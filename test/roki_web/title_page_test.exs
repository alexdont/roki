defmodule RokiWeb.TitlePageTest do
  @moduledoc """
  A show's own page, drawn for a signed-in account with laev connected, from a kept copy of the
  title (so no TMDB is asked). It must come up, not crash and reconnect.
  """
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "roki-title-page-#{System.unique_integer([:positive])}")
    prior = Application.get_env(:roki, :laev_dir)
    Application.put_env(:roki, :laev_dir, dir)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:roki, :laev_dir, prior),
        else: Application.delete_env(:roki, :laev_dir)

      File.rm_rf(dir)
    end)

    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "titlepage@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "titlepage"
      })

    udir = Roki.Laev.dir(user.uuid)
    File.mkdir_p!(udir)

    File.write!(
      Path.join(udir, "config"),
      "LAEV_SYNC_URL=https://sync.invalid/laev\nLAEV_SYNC_TOKEN=laev_#{String.duplicate("a", 40)}\n"
    )

    {title, _} = Code.eval_file(Path.expand("../support/fixtures/frieren_title.exs", __DIR__))
    Roki.Titles.put(title)

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token}), user: user}
  end

  test "a show's page comes up with the link button", %{conn: conn} do
    {:ok, view, _} = live(conn, "/title/tv/209867")
    html = render_async(view, 8000)
    assert html =~ "Frieren"
    assert html =~ "Link progress"
    assert Process.alive?(view.pid)
  end

  test "the score in the hero opens the Reviews sheet", %{conn: conn} do
    {:ok, view, _} = live(conn, "/title/tv/209867")
    html = render_async(view, 8000)
    assert html =~ ~s(id="reviews-sheet")
    assert has_element?(view, ~s|button[aria-label="Reviews and scores"]|)

    # What it shows is asked for when it is opened: held here, so nothing is fetched.
    Roki.TTLCache.put(
      {:mdblist, 2, "tv", 209_867},
      60,
      {:ok,
       [%{source: "imdb", order: 5, label: "IMDb", who: "Members", text: "8.9/10", votes: 86_755}]}
    )

    Roki.TTLCache.put(
      {:critics, "tv", 209_867},
      60,
      {:ok,
       %{
         paragraphs: ["Well received."],
         title: "Frieren",
         url: "https://en.wikipedia.org/wiki/Frieren"
       }}
    )

    render_hook(view, "reviews_open", %{})
    html = render_async(view, 8000)
    assert html =~ "8.9/10"
    assert html =~ "Well received."
    assert html =~ "Summary from Wikipedia (CC BY-SA)"
  end

  describe "rating without a TMDB account" do
    test "the rating is kept on Roki, and survives a refresh from TMDB", %{conn: conn, user: user} do
      {:ok, view, _} = live(conn, "/title/tv/209867")
      html = render_async(view, 8000)
      assert html =~ "your score is kept on Roki"
      assert html =~ "Link a TMDB account"
      refute html =~ "Link my TMDB account"

      view |> element("#rate-form") |> render_submit(%{"value" => "8.5"})
      render_async(view, 8000)

      assert {:ok, 8.5} = Roki.Profile.rating(user.uuid, {"tv", 209_867})
      assert Roki.Profile.ratings(user.uuid)[{"tv", 209_867}] == 8.5

      # A rating copied from TMDB is replaced on a refresh; one made here is not.
      Roki.Profile.forget_tmdb_ratings(user.uuid)
      assert {:ok, 8.5} = Roki.Profile.rating(user.uuid, {"tv", 209_867})

      render_click(view, "clear_rating", %{})
      render_async(view, 8000)
      assert Roki.Profile.rating(user.uuid, {"tv", 209_867}) != {:ok, 8.5}
    end
  end

  describe "the trailer" do
    setup do
      on_exit(fn -> Roki.TTLCache.delete({:trailer, "tv", 209_867, nil}) end)
    end

    test "a title with one has a Trailer button, and a player sheet for it", %{conn: conn} do
      Roki.TTLCache.put({:trailer, "tv", 209_867, nil}, 600, {:ok, "abc123xyz"})
      {:ok, view, _} = live(conn, "/title/tv/209867")
      render_async(view, 8000)
      html = render_async(view, 8000)

      assert html =~ ~s(id="trailer-sheet")
      assert html =~ ~s(data-key="abc123xyz")
      # The CSS that fades the video in is keyed on this attribute: without it the sound plays
      # over a hero that stays a still picture.
      assert html =~ ~r/<section[^>]*\sdata-hero(=""|[\s>])/
      assert html =~ "https://www.youtube.com/watch?v=abc123xyz"
      assert html =~ "Trailer"
    end

    test "one without has neither", %{conn: conn} do
      Roki.TTLCache.put({:trailer, "tv", 209_867, nil}, 600, {:ok, nil})
      {:ok, view, _} = live(conn, "/title/tv/209867")
      render_async(view, 8000)
      html = render_async(view, 8000)

      refute html =~ ~s(id="trailer-sheet")
      refute html =~ ~s(data-key="abc123xyz")
    end
  end

  describe "the wide-screen page" do
    setup do
      Roki.TTLCache.put({:trailer, "tv", 209_867, nil}, 600, {:ok, "abc123xyz"})

      Roki.TTLCache.put(
        {:credits, "tv", 209_867},
        600,
        {:ok,
         %{
           cast: [%{name: "Cast Person", character: "Role", photo: nil}],
           directors: ["Dir One"],
           writers: []
         }}
      )

      on_exit(fn ->
        Roki.TTLCache.delete({:trailer, "tv", 209_867, nil})
        Roki.TTLCache.delete({:credits, "tv", 209_867})
      end)
    end

    defp open_page(conn) do
      {:ok, view, _} = live(conn, "/title/tv/209867")
      render_async(view, 8000)
      render_async(view, 8000)
    end

    test "has a hero the trailer plays in, with the viewer's controls", %{conn: conn} do
      html = open_page(conn)

      assert html =~ ~s(id="hero")
      assert html =~ ~s(phx-hook="HeroTrailer")
      assert html =~ ~s(data-key="abc123xyz")
      # The player is put in by the hook, and the page leaves it alone.
      assert html =~
               ~r/id="hero-video"[^>]*phx-update="ignore"|phx-update="ignore"[^>]*id="hero-video"/

      for ctl <- ~w(play mute full), do: assert(html =~ ~s(data-hero-ctl="#{ctl}"))
    end

    test "has no controls to offer when there is no trailer", %{conn: conn} do
      Roki.TTLCache.put({:trailer, "tv", 209_867, nil}, 600, {:ok, nil})
      html = open_page(conn)

      assert html =~ ~s(id="hero")
      refute html =~ "data-hero-ctl"
      refute html =~ ~s(data-key="abc123xyz")
    end

    test "has the facts, the cast and the comments, the comments before more like this", %{
      conn: conn
    } do
      html = open_page(conn)

      assert html =~ ~s(id="details")
      assert html =~ "Cast Person"
      assert html =~ "Dir One"
      refute html =~ ">false<"

      {cast, _} = :binary.match(html, ~s(id="row-cast"))

      # The comments section that follows the cast (the phone has its own, earlier in the page).
      {comments, _} =
        :binary.match(html, ~s(aria-label="Comments"), scope: {cast, byte_size(html) - cast})

      assert cast < comments

      # Whatever "more like this" is, it never comes before the comments.
      case :binary.match(html, ~s(id="row-similar")) do
        {similar, _} -> assert comments < similar
        :nomatch -> :ok
      end
    end

    test "the page's header floats over it", %{conn: conn} do
      assert open_page(conn) =~ "site-header--overlay"
    end

    # A reload (or a shared link) paints the page before LiveView connects: the hero from the
    # site's own copy of the title, and a placeholder in the hero's shape when it has none —
    # never the padded column of the page that was.
    test "its first paint is the hero, from the kept copy", %{conn: conn} do
      html = conn |> get("/title/tv/209867") |> html_response(200)
      assert html =~ ~s(id="hero")
      assert html =~ "Frieren"
      assert html =~ "site-header--overlay"
    end

    test "its first paint is a hero-shaped placeholder when there is no copy yet", %{conn: conn} do
      html = conn |> get("/title/movie/424242424") |> html_response(200)
      refute html =~ ~s(id="hero")
      assert html =~ ~s(aria-busy="true")
      assert html =~ "animate-pulse"
      assert html =~ "site-header--overlay"
    end
  end
end
