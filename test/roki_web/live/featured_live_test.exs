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

  test "the popular grid is short and leads to each kind's own page; there is no load more", %{conn: conn} do
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
      Roki.Activity.insert_now(user.uuid, %{type: "movie", tmdb_id: 903, title: "Solo Film"}, "saved")
      {:ok, view, _} = live(conn, "/home")
      html = render_async(view, 3000)
      assert html =~ ~s(href="/title/movie/903")
      refute html =~ "See which"
    end
  end
end
