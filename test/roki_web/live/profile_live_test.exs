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

    # Now a visitor sees it, words and all, with the watched list's controls.
    {:ok, _view, html} = live(conn, "/ownerone")
    assert html =~ "Mostly anime."
    assert html =~ "By rating"
    assert html =~ "★ 10 only"
  end
end
