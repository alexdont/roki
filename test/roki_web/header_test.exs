defmodule RokiWeb.HeaderTest do
  use RokiWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  test "the header has the sections on the left and no Featured link", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/lists")

    for {label, href} <- [{"Movies", "/movies"}, {"Shows", "/shows"}, {"Anime", "/anime"}] do
      assert html =~ ~s(href="#{href}")
      assert html =~ label
    end

    # manga is a placeholder, not a link
    assert html =~ "Manga"
    refute html =~ ~s(href="/manga")
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

  test "a visitor has no shelf or calendar buttons", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/lists")
    refute html =~ ~s(aria-label="Shelf")
    refute html =~ ~s(aria-label="Calendar")
  end

  test "signed in: a star for the shelf, a calendar icon, and no settings link in the bar" do
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
    assert html =~ ~s(aria-label="Shelf")
    assert html =~ "hero-star"
    assert html =~ ~s(href="/headertest/calendar")
    assert html =~ "hero-calendar-days"
    refute html =~ ~s(href="/headertest/settings" data-phx-link)
    refute html =~ ~s(href="/headertest/stats" data-phx-link)
  end

  test "the account menu's Settings opens this site's settings page" do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "account-test@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "accounttest"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    conn = Plug.Test.init_test_session(build_conn(), %{user_token: token})

    assert redirected_to(get(conn, "/phoenix_kit/en/profile/settings")) == "/accounttest/settings"
    assert redirected_to(get(build_conn(), "/phoenix_kit/en/profile/settings")) =~ "log-in"
  end
end
