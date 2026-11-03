defmodule RokiWeb.NavNoReloadTest do
  @moduledoc """
  The header's links opt in to doing nothing when they point at the page you are on
  (`data-no-reload`, acted on by the click handler in app.js). The behaviour is the browser's;
  what is pinned here is that every link a person is likely to click twice carries the marker.
  """
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "nav@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "navuser"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token})}
  end

  test "the section links, the star and the profile row opt in", %{conn: conn} do
    {:ok, view, _} = live(conn, "/u/navuser/stats")

    for section <- ["/movies", "/shows", "/anime", "/manga"] do
      assert has_element?(
               view,
               ~s|header nav:not(#mobile-nav) a[href="#{section}"][data-no-reload]|
             )

      assert has_element?(view, ~s|#mobile-nav[data-no-reload] a[href="#{section}"]|)
    end

    assert has_element?(view, ~s|header a[href="/u/navuser/corner"][data-no-reload]|)
    assert has_element?(view, ~s|header a[href="/u/navuser/calendar"][data-no-reload]|)
    assert has_element?(view, ~s|#account-pop[data-no-reload] a[href="/u/navuser/profile"]|)
    assert has_element?(view, ~s|header a[href="/"][data-no-reload]|)
  end

  test "the phone's panel closes itself when a link in it is followed", %{conn: conn} do
    {:ok, view, _} = live(conn, "/u/navuser/stats")

    # Without this a click that goes nowhere would leave the panel open on top of the page.
    assert has_element?(view, ~s|#mobile-nav a[phx-click*="mobile-nav"]|)
  end
end
