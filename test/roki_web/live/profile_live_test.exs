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

  test "a name nobody has shows nothing; every profile is open to a visitor", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/nobody-here")
    assert html =~ "There is no one called"

    register("quietone")
    {:ok, view, html} = live(conn, "/quietone")
    assert html =~ "quietone"
    assert html =~ "written anything here yet"
    # Empty shelves are the owner's to see, not a visitor's.
    refute render_async(view) =~ "Top 10 Movies"
  end

  test "the owner writes the words where they go, and the rest from the banner's button", %{conn: conn} do
    user = register("ownerone")
    {:ok, view, html} = live(signed_in(user), "/ownerone")
    assert html =~ "Press here to write it"
    assert html =~ "Edit profile"

    # The placeholder becomes the place to write, Enter (the form) keeps it.
    view |> element("button", "Say something about yourself") |> render_click()
    assert has_element?(view, "form input[name=bio]")
    view |> form("form[phx-submit=bio_save]", %{bio: "Mostly anime."}) |> render_submit()
    html = render(view)
    assert html =~ "Mostly anime."
    refute html =~ "Press here to write it"

    # Written, the words are no longer a button; the panel on the banner changes them.
    refute has_element?(view, "button", "Mostly anime.")
    view |> element("button", "Edit profile") |> render_click()
    assert has_element?(view, "#profile-form")
    assert has_element?(view, "#profile-form a", "Change picture")
    refute has_element?(view, "#profile-form input[name='profile[public]']")

    view |> form("#profile-form", profile: %{bio: "Mostly anime, some films."}) |> render_submit()
    assert render(view) =~ "Mostly anime, some films."

    # A visitor sees it all, and the watched page with its controls.
    {:ok, _view, html} = live(conn, "/ownerone")
    assert html =~ "Mostly anime, some films."
    assert html =~ "Watched →"

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

    # A visitor sees only the shelves with something on them.
    {:ok, visitor, _} = live(conn, "/shelfowner")
    refute render_async(visitor) =~ "Top 10 Movies"

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
