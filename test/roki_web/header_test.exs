defmodule RokiWeb.HeaderTest do
  use RokiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the header has the sections on the left and no Featured link", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/lists")

    sections = [
      {"Movies", "/movies"},
      {"Shows", "/shows"},
      {"Anime", "/anime"},
      {"Manga", "/manga"}
    ]

    for {label, href} <- sections do
      assert html =~ ~s(href="#{href}")
      assert html =~ label
    end

    # Featured is the logo
    refute html =~ ~r/>\s*Featured\s*</
  end

  test "search is an icon that opens a box; it submits to the search page", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/lists")
    assert html =~ ~s(aria-label="Search")
    assert html =~ ~s(id="search-pop")
    assert html =~ ~s(action="/search")
    assert html =~ ~s(name="q")
  end

  test "a visitor has no home or new-episodes buttons, only the ways in", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/lists")
    refute html =~ ~s(aria-label="Home")
    refute html =~ ~s(aria-label="New episodes")
    refute html =~ ~s(id="account-button")
    assert html =~ "Log in"
  end

  test "signed in: home star, new episodes, and one account menu" do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "header-test@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "headertest"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    conn = Plug.Test.init_test_session(build_conn(), %{user_token: token})
    {:ok, _view, html} = live(conn, "/lists")

    assert html =~ ~s(href="/headertest/home")
    assert html =~ ~s(aria-label="Home")
    assert html =~ "hero-star"
    assert html =~ ~s(href="/headertest/calendar")
    assert html =~ "hero-calendar-days"
    assert html =~ ~s(aria-label="New episodes")
    # Everything else is a row of the account menu, not an icon in the bar.
    assert html =~ ~s(id="account-button")
    assert html =~ ~s(href="/headertest/settings")
    assert html =~ ~s(href="/headertest/friends")
    assert html =~ "Log out"
    refute html =~ "Playback &amp; services"
    refute html =~ ~s(phx-hook="MenuExtras")
    refute html =~ ~s(href="/headertest/stats" data-phx-link)
  end

  test "/account/services opens this site's playback and services page" do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "account-test@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "accounttest"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    conn = Plug.Test.init_test_session(build_conn(), %{user_token: token})

    assert redirected_to(get(conn, "/account/services")) == "/accounttest/settings"
    assert redirected_to(get(build_conn(), "/account/services")) =~ "log-in"
  end

  test "on a phone the sections are a panel under the header, not a small dropdown", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/lists")

    assert html =~ ~s(id="mobile-nav")
    assert html =~ ~s(aria-controls="mobile-nav")
    # inset from both edges and the full width of the screen, so it cannot run off the side
    assert html =~ "inset-x-3"
    refute html =~ "dropdown-content z-[60] mt-3 w-52"

    for label <- ~w(Movies Shows Anime Manga), do: assert(html =~ label)
  end
end
