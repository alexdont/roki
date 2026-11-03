defmodule RokiWeb.MangaShelfLiveTest do
  @moduledoc "The saved-manga page (`/manga`) as a LiveView: chips, sorts, categories, redirects."
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Roki.Manga.Library

  setup %{conn: conn} do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "shelfme@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "shelfme"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token}), user: user}
  end

  defp save!(user, slug, title, set) do
    {:ok, _} =
      Library.save_manga(user.uuid, %{
        source: "mangadex",
        slug: slug,
        title: title,
        cover_url: "https://example.invalid/#{slug}.jpg"
      })

    {:ok, bin} = Ecto.UUID.dump(user.uuid)
    {cols, vals} = Enum.unzip(set)
    sets = cols |> Enum.with_index(3) |> Enum.map_join(", ", fn {c, i} -> "#{c} = $#{i}" end)

    if set != [] do
      Roki.Repo.query!(
        "update saved_manga set #{sets} where user_id = $1 and slug = $2",
        [bin, slug | vals]
      )
    end
  end

  defp library!(user) do
    save!(user, "reading-one", "Reading One", last_chapter: "3", total_chapters: 50)
    save!(user, "caught-one", "Caught One", last_chapter: "20", total_chapters: 20)
    save!(user, "fresh-one", "Fresh One", [])
  end

  test "a visitor is sent to sign in" do
    conn = Phoenix.ConnTest.build_conn()
    assert {:error, {:redirect, %{to: "/phoenix_kit/users/log-in"}}} = live(conn, "/manga")
  end

  test "an empty library goes to Explore", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/manga/explore"}}} = live(conn, "/manga")
  end

  test "the shelf, the banner to carry on, and the chips narrow it", %{conn: conn, user: user} do
    library!(user)
    {:ok, view, html} = live(conn, "/manga")

    assert html =~ "Reading One" and html =~ "Caught One" and html =~ "Fresh One"
    assert html =~ "Continue reading"
    assert has_element?(view, ~s(section a[aria-label^="Continue "]))

    html = render_patch(view, "/manga?mode=reading")
    assert html =~ "Reading One"
    refute html =~ "Caught One"
    # The chip that is on offers to exclude itself next.
    assert has_element?(view, ~s(#manga-chips a[href="/manga?exclude_mode=reading"]), "Reading")

    html = render_patch(view, "/manga?exclude_mode=reading")
    refute grid(html) =~ "Reading One"
    assert grid(html) =~ "Caught One"

    html = render_patch(view, "/manga?mode=caughtup")
    assert grid(html) =~ "Caught One"
    refute grid(html) =~ "Fresh One"
    assert has_element?(view, "button[phx-click=sync]")

    html = render_patch(view, "/manga?filter=unread")
    assert grid(html) =~ "Fresh One"
    refute grid(html) =~ "Reading One"
  end

  test "a category: on, add titles to it, excluded", %{conn: conn, user: user} do
    library!(user)
    {:ok, cat} = Library.create_category(user.uuid, %{name: "Favourites"})
    {:ok, view, _} = live(conn, "/manga?category=#{cat.id}")

    assert render(view) =~ "Nothing here with these choices."

    view |> element("button[phx-click=bulk_open]") |> render_click()
    view |> element(~s(#manga-bulk button[phx-value-key="mangadex:fresh-one"])) |> render_click()

    assert has_element?(
             view,
             ~s(#manga-bulk button[phx-value-key="mangadex:fresh-one"][aria-pressed=true])
           )

    render_click(view, "bulk_close")

    assert grid(render(view)) =~ "Fresh One"
    refute grid(render(view)) =~ "Reading One"

    html = render_patch(view, "/manga?exclude=#{cat.id}")
    refute grid(html) =~ "Fresh One"
    assert grid(html) =~ "Reading One"
  end

  test "a category that is not the account's is ignored", %{conn: conn, user: user} do
    library!(user)
    {:ok, _view, html} = live(conn, "/manga?category=999999")
    assert grid(html) =~ "Reading One" and grid(html) =~ "Fresh One"
  end

  test "the old address forwards with its choices", %{conn: conn, user: user} do
    library!(user)
    conn = get(conn, "/manga/home2?mode=reading")
    assert redirected_to(conn) == "/manga?mode=reading"
  end

  defp grid(html) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query("#manga-grid") |> LazyHTML.to_html()
  end

  test "a bare /manga opens on the account's last view, from the first paint", %{
    conn: conn,
    user: user
  } do
    library!(user)

    {:ok, view, _} = live(conn, "/manga")
    render_patch(view, "/manga?mode=caughtup&sort=chapters_asc")

    saved = PhoenixKit.Users.Auth.get_user(user.uuid).custom_fields["manga_view"]
    assert saved["chip"] == %{"mode" => "caughtup"} and saved["sort"] == "chapters_asc"

    # The disconnected render is already that view: nothing to jump once the socket connects.
    html = conn |> get("/manga") |> html_response(200)
    assert html =~ "Caught One"
    refute html =~ "Fresh One"

    {:ok, view, _} = live(conn, "/manga")
    refute render(view) =~ "Fresh One"

    # "All" is a choice too, and is what a bare /manga then opens on.
    render_patch(view, "/manga")
    html = conn |> get("/manga") |> html_response(200)
    assert html =~ "Fresh One"
  end
end
