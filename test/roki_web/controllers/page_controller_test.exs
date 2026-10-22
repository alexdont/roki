defmodule RokiWeb.PageControllerTest do
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  test "/home shows a visitor the pitch and the account menu", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/home")
    assert html =~ "Everything you watch, in one place."
    assert html =~ "Create an account"
    assert html =~ "Featured"
  end

  test "/ sends a visitor to the featured page", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/home"}}} = live(conn, ~p"/")
  end

  test "a visitor cannot open someone's home", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/phoenix_kit/users/log-in"}}} =
             live(conn, ~p"/alex/home")
  end
end
