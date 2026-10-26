defmodule RokiWeb.ProfileLiveTest do
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  defp register(username) do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "#{username}@example.com",
        "password" => "a-long-enough-password-123",
        "username" => username
      })

    user
  end

  defp signed_in(user) do
    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    Plug.Test.init_test_session(build_conn(), %{user_token: token})
  end

  test "a name nobody has, and a private profile, show nothing of the person", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/nobody-here")
    assert html =~ "There is no one called"

    register("quietone")
    {:ok, _view, html} = live(conn, "/quietone")
    assert html =~ "This profile is private."
    refute html =~ "Watched"
  end

  test "the owner sees their private page with a note, and can open it to everyone", %{conn: conn} do
    user = register("ownerone")
    {:ok, view, html} = live(signed_in(user), "/ownerone")
    assert html =~ "Only you can see this page"
    assert html =~ "Edit profile"

    view |> element("button", "Edit profile") |> render_click()
    assert has_element?(view, "#profile-form")

    view
    |> form("#profile-form", profile: %{bio: "Mostly anime.", public: "true", show_history: "true", show_ratings: "true"})
    |> render_submit()

    html = render(view)
    assert html =~ "Mostly anime."
    refute html =~ "Only you can see this page"

    # Now a visitor sees it, words and all, and the watched page with its controls.
    {:ok, _view, html} = live(conn, "/ownerone")
    assert html =~ "Mostly anime."
    assert html =~ "watched →"

    {:ok, _view, html} = live(conn, "/ownerone/watched")
    assert html =~ "By rating"
    assert html =~ "★ 10 only"
  end

  test "the shelves are the owner's to fill, ten a shelf, from what they watched", %{conn: conn} do
    user = register("shelfowner")
    {:ok, view, _html} = live(signed_in(user), "/shelfowner")
    html = render_async(view)
    assert html =~ "Top 10 Movies"
    assert html =~ "Nothing on this shelf yet"

    # A visitor to a private profile sees nothing; to a public one, only shelves with something on them.
    {:ok, _, html} = live(conn, "/shelfowner")
    assert html =~ "This profile is private."

    assert {:ok, favs} = Roki.Profile.add_favorite(user.uuid, :movie, {"movie", 10_331}, "Easy A")
    assert [%{title: "Easy A", position: 1, badge: "#1"}] = favs.movie
    assert {:error, msg} = Roki.Profile.add_favorite(user.uuid, :tv, {"movie", 10_331}, "Easy A")
    assert msg =~ "already"

    for n <- 1..9, do: {:ok, _} = Roki.Profile.add_favorite(user.uuid, :movie, {"movie", n}, "Film #{n}")
    assert {:error, msg} = Roki.Profile.add_favorite(user.uuid, :movie, {"movie", 99}, "One too many")
    assert msg =~ "holds 10"

    {:ok, favs} = Roki.Profile.move_favorite(user.uuid, {"movie", 9}, :up)
    assert Enum.map(favs.movie, & &1.id) |> Enum.take(3) == [10_331, 1, 2]
    assert Enum.map(Enum.drop(favs.movie, 8), & &1.id) == [9, 8]
    {:ok, favs} = Roki.Profile.remove_favorite(user.uuid, {"movie", 10_331})
    assert Enum.map(favs.movie, & &1.position) == Enum.to_list(1..9)
    assert hd(favs.movie).id == 1
  end
end
