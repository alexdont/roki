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

  test "the popular grid is short and leads to each kind's own page; there is no load more", %{
    conn: conn
  } do
    for kind <- Roki.Featured.kinds() do
      items =
        for i <- 1..20, do: %{id: i, type: "movie", title: "Film #{i}", poster: nil, year: "2020"}

      Roki.Featured.seed(kind, 1, items, true)
    end

    {:ok, view, _} = live(conn, "/home")
    render_async(view, 3000)
    html = render_async(view, 3000)

    for kind <- ~w(movies shows anime), do: assert(html =~ ~s(href="/#{kind}"))
    assert html =~ "Popular right now"
    refute html =~ "Load more"
    # Twelve of each kind, the three lists interleaved; the same titles seeded thrice fold to one.
    assert html =~ "Film 12"
    refute html =~ "Film 13"
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

      {:ok, view, _} = live(conn, "/home")
      html = render_async(view, 3000)
      assert html =~ "saved 2 films"
      assert html =~ "See which"
      refute html =~ ~s(aria-label="Titles in this group")

      html = view |> element(~s(button[phx-click="activity_open"])) |> render_click()
      assert html =~ ~s(aria-label="Titles in this group")
      assert html =~ ~s(href="/title/movie/901")
      assert html =~ ~s(href="/title/movie/902")

      html = render_click(view, "activity_close", %{})
      refute html =~ ~s(aria-label="Titles in this group")
    end

    test "a single title is a link to its page" do
      {user, conn} = signed_in("actsingle")

      Roki.Activity.insert_now(
        user.uuid,
        %{type: "movie", tmdb_id: 903, title: "Solo Film"},
        "saved"
      )

      {:ok, view, _} = live(conn, "/home")
      html = render_async(view, 3000)
      assert html =~ ~s(href="/title/movie/903")
      refute html =~ "See which"
    end
  end

  describe "the mood picker" do
    @emoji ~r/[\x{1F000}-\x{1FAFF}\x{2190}-\x{21FF}\x{2300}-\x{23FF}\x{2600}-\x{27BF}\x{FE0F}]/u

    test "has no emoji in it: the moods are their names, their colours and their numbers", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, "/home")
      picker = view |> element("#mood-picker") |> render()

      refute picker =~ @emoji
      # Every mood is in it, numbered the way a programme numbers its films.
      for mood <- Roki.Mood.all() do
        assert picker =~ mood.label
        assert picker =~ ">#{Roki.Mood.number(mood)}<"
      end
    end

    test "each chip carries a dot in its mood's colour, in place of a picture", %{conn: conn} do
      {:ok, view, _} = live(conn, "/home")

      for mood <- Roki.Mood.all() do
        assert has_element?(
                 view,
                 ~s|[data-mood-chip="#{mood.slug}"] span.rounded-full.bg-\\[var\\(--mood\\)\\]|
               )
      end
    end

    test "each chip holds the room of both its states, so none changes size when it is lit", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, "/home")

      for mood <- Roki.Mood.all() do
        chip = view |> element(~s|[data-mood-chip="#{mood.slug}"]|) |> render()

        # Two invisible copies of the name, one set as the lit chip is and one as it is not,
        # and the visible one on top of them: the chip is as wide as the wider, always.
        assert length(Regex.scan(~r/class="invisible /, chip)) == 2,
               "#{mood.slug} does not reserve both states"

        assert chip =~
                 Phoenix.HTML.safe_to_string(
                   Phoenix.HTML.html_escape("font-family: #{mood.font}")
                 )

        # …and none of it is read out twice.
        assert length(Regex.scan(~r/aria-hidden="true"/, chip)) >= 2
      end
    end

    test "the title is set in the mood's own typeface, with a rule in its colour under it", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, "/home")
      scared = Roki.Mood.get("scared")

      # The typeface's name has quotes in it, which the page's HTML escapes.
      font = Phoenix.HTML.html_escape("font-family: #{scared.font}")
      assert render(view) =~ Phoenix.HTML.safe_to_string(font)
      assert render(view) =~ "background: hsl(#{scared.hue} 90% 62%)"
    end
  end
end
