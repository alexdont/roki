defmodule RokiWeb.SearchMangaTest do
  @moduledoc """
  Manga in this site's search: its own section, never mixed into the film and show grid, and
  only for someone signed in — the sources' covers are fetched by this site on their behalf.
  """
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Roki.Manga.Library

  setup do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "search-manga@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "searchmanga"
      })

    {:ok, _} =
      Library.save_manga(user.uuid, %{
        source: "mangadex",
        slug: "berserk",
        title: "Berserk",
        cover_url: "https://example.invalid/berserk.jpg"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, conn: Plug.Test.init_test_session(build_conn(), %{user_token: token}), user: user}
  end

  test "what you are reading is found from the same box, under its own heading", %{conn: conn} do
    {:ok, view, _} = live(conn, "/search?q=berserk")
    html = render_async(view)

    assert html =~ "Manga"
    assert html =~ "Berserk"
    assert html =~ "/manga/mangadex/berserk"
    assert html =~ "/manga/search?q=berserk"
  end

  test "no match still offers the sources", %{conn: conn} do
    {:ok, view, _} = live(conn, "/search?q=dune")
    html = render_async(view)

    assert html =~ "Nothing you are reading matches."
    assert html =~ "/manga/search?q=dune"
  end

  test "a one-letter query asks for nothing", %{conn: conn} do
    {:ok, view, _} = live(conn, "/search?q=b")
    refute render_async(view) =~ "Nothing you are reading matches."
  end

  test "a visitor who is not signed in gets no manga section" do
    {:ok, view, _} = live(build_conn(), "/search?q=berserk")
    html = render_async(view)

    refute html =~ "Nothing you are reading matches."
    refute html =~ "/manga/search?q=berserk"
  end
end
