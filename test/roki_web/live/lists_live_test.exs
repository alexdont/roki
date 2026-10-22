defmodule RokiWeb.ListsLiveTest do
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  test "/lists shows every curated list, with no TMDB request", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/lists")
    assert html =~ "Marvel"
    assert html =~ "Animation"
    assert html =~ "curated list"
    assert html =~ ~s(href="/lists/marvel")
  end

  test "a list opens complete from the curated file, in release order", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/lists/star-wars")
    assert html =~ "Star Wars"
    assert html =~ "57 titles, in release order"
  end

  test "a tiered list offers its tiers, once each, and filters by them", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/lists/marvel")
    assert html =~ "207 titles, in release order"
    assert length(String.split(html, "Everything")) - 1 == 1
    assert html =~ "Essentials"

    {:ok, _view, essentials} = live(conn, ~p"/lists/marvel?tier=essential")
    assert essentials =~ "68 titles, in release order"
  end

  test "a list with no tiers of its own still gets no empty tab bar", %{conn: conn} do
    {:ok, _view, html} = live(conn, ~p"/lists/star-wars")
    refute html =~ ~s(role="tablist")
  end

  test "an unknown list goes back to the lists", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/lists"}}} = live(conn, ~p"/lists/no-such-list")
  end
end
