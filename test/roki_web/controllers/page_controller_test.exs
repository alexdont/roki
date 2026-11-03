defmodule RokiWeb.PageControllerTest do
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  test "the bare address shows a visitor the featured page, the pitch and the account menu", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, ~p"/")
    assert html =~ "Everything you watch, in one place."
    assert html =~ "Create an account"
    assert html =~ "Featured"
  end

  test "old addresses go, for good, to where they live now", %{conn: conn} do
    for {old, new} <- [
          {"/home", "/"},
          {"/alex", "/u/alex/profile"},
          {"/u/alex", "/u/alex/profile"},
          {"/alex/home", "/u/alex/corner"},
          {"/alex/watched?view=rows", "/u/alex/watched?view=rows"},
          {"/alex/settings", "/u/alex/settings"}
        ] do
      conn = get(conn, old)
      assert conn.status == 301
      assert redirected_to(conn, 301) == new
    end
  end

  test "a visitor cannot open someone's home", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/phoenix_kit/users/log-in"}}} =
             live(conn, ~p"/u/alex/corner")
  end
end
