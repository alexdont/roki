defmodule RokiWeb.TitleLiveTest do
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  test "an unknown kind of title goes back to the featured page", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/title/book/5")
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/title/movie/abc")
  end

  test "a visitor is told to log in rather than shown a broken page", %{conn: conn} do
    {:ok, view, html} = live(conn, "/title/movie/10331")
    assert html =~ "aria-busy"
    html = view |> render_async() |> then(fn _ -> render_async(view) end)
    assert html =~ "Log in"
    # No Play of the title's own (the page's one card template carries a Play of its own).
    refute html =~ ~s(phx-click="play")
  end
end
