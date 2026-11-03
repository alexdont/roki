defmodule RokiWeb.UserPagesTest do
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  test "stats and calendar belong to their user: a visitor is sent to the login", %{conn: conn} do
    for page <- ["stats", "calendar", "corner"] do
      assert {:error, {:live_redirect, %{to: "/phoenix_kit/users/log-in"}}} =
               live(conn, "/u/alex/#{page}")
    end
  end

  test "someone else's stats and calendar go to the featured page" do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "guard-test@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "guardtest"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    conn = Plug.Test.init_test_session(build_conn(), %{user_token: token})

    for page <- ["stats", "calendar", "corner"] do
      assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/u/someone-else/#{page}")
    end

    # their own pages open, and a user who has not connected laev is told to
    {:ok, view, html} = live(conn, "/u/guardtest/stats")
    assert html =~ ~s(aria-label="Your corner")
    assert render_async(view) =~ "Connect laev in your corner"

    {:ok, cal, _} = live(conn, "/u/guardtest/calendar")
    assert render_async(cal) =~ "Connect laev in your corner"
  end

  test "the logo takes you to the featured page", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/lists")

    # By what the link is, not by the order its attributes happen to be written in.
    assert has_element?(view, ~s|header a[href="/"][aria-label="roki — home"]|)
  end
end
