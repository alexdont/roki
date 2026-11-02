defmodule RokiWeb.SourcesConnectTest do
  @moduledoc """
  An account with nothing connected is told what to connect (and where to get it), instead of a
  page that says it is starting and never does.
  """
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "nosource@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "nosource"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token}), user: user}
  end

  test "nothing connected: the connect panel, with where to get each one, and no spinner", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, "/sources/movie/603?auto=1")

    assert html =~ "Connect a source to start watching"
    assert html =~ "https://pengu.uk"
    assert html =~ "https://real-debrid.com/apitoken"
    assert html =~ "https://torbox.app/settings"
    refute html =~ "loading-spinner"
    refute html =~ "Starting…"
  end

  test "both switches grey out what the account has not connected, and point to Settings", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, "/sources/movie/603")

    # the sources page's own switch and the account menu's
    assert html =~ ~s(href="/nosource/settings#debrid")
    assert html =~ ~s(href="/nosource/settings#penguplay")
    assert html =~ ~s(href="/nosource/settings#nuvio")
    assert html =~ "Nuvio"
    assert html =~ "data-source-switch"
    assert html =~ "Not connected — add a PenguPlay link in Settings"
    refute html =~ ~s(phx-click="set_play_from")
    refute html =~ ~s(phx-value-to="pengu")
  end

  test "the paste fields say what is wrong instead of doing nothing", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/sources/movie/603")

    html =
      view
      |> form("form[phx-submit=setup_pengu]",
        pengu: %{url: "https://example.com/a/manifest.json"}
      )
      |> render_submit()

    assert html =~ "Paste the install link from pengu.uk"

    view |> form("form[phx-submit=setup_debrid]") |> render_submit()
    html = render_async(view)
    assert html =~ "Paste a Real-Debrid token or a TorBox key first."
  end
end
