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

defmodule RokiWeb.FeaturedListsSectionTest do
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  test "Lists is a section at the bottom of the featured page, not a header link", %{conn: conn} do
    {:ok, view, html} = live(conn, ~p"/")

    # not in the header, in the bar or the menu
    refute Regex.match?(
             ~r/<a[^>]*href="\/lists"[^>]*>\s*Lists\s*<\/a>/,
             hd(String.split(html, "<main"))
           )

    # and not shown until the shelves above have settled (no key in test: they error, which settles them)
    html = render_async(view)
    assert html =~ ">Lists<"
    for name <- ["Marvel", "Star Wars", "Animation"], do: assert(html =~ name)
    assert html =~ ~s(href="/lists/marvel")

    # it is below the shelves, never above
    {lists_at, _} = :binary.match(html, ">Lists<")
    {pitch_at, _} = :binary.match(html, "Everything you watch")
    assert lists_at > pitch_at
  end
end
