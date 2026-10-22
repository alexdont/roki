defmodule RokiWeb.PageControllerTest do
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  test "GET / shows a visitor the pitch and the account menu", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Everything you watch, in one place."
    assert html =~ "Create an account"
  end
end
