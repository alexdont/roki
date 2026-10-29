defmodule RokiWeb.UserHomeContinueTest do
  @moduledoc """
  The row the shelf opens with: the chapter you stopped on and the episode you are up to, side
  by side at every width.
  """
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "roki-continue-#{System.unique_integer([:positive])}")
    prior = Application.get_env(:roki, :laev_dir)
    Application.put_env(:roki, :laev_dir, dir)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:roki, :laev_dir, prior),
        else: Application.delete_env(:roki, :laev_dir)

      File.rm_rf(dir)
    end)

    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "continue@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "continuer"
      })

    # A shelf appears once laev is connected; the reading half does not depend on it.
    laev = Roki.Laev.dir(user.uuid)
    File.mkdir_p!(laev)

    File.write!(
      Path.join(laev, "config"),
      "LAEV_SYNC_URL=https://sync.invalid/laev\nLAEV_SYNC_TOKEN=laev_#{String.duplicate("a", 40)}\n"
    )

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, bin} = Ecto.UUID.dump(user.uuid)
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token}), user: user, bin: bin}
  end

  defp reading!(user, slug, title, attrs \\ %{}) do
    {:ok, _} =
      Roki.Manga.Library.save_manga(
        user.uuid,
        Map.merge(
          %{
            source: "mangadex",
            slug: slug,
            title: title,
            cover_url: "https://example.invalid/#{slug}.jpg",
            last_chapter: "23"
          },
          attrs
        )
      )
  end

  test "it opens with one of each, in one row of two", %{conn: conn, user: user} do
    reading!(user, "berserk", "Berserk")

    {:ok, view, _} = live(conn, "/continuer/home")
    html = render(view)

    assert html =~ "Continue"
    assert html =~ "Berserk"
    assert html =~ "Chapter 23"
    assert html =~ "/manga/mangadex/berserk/23"
    # Two across at every width, phones included.
    assert html =~ ~s(class="grid grid-cols-2 gap-3")
  end

  test "a series you are caught up with is not something to carry on with", %{
    conn: conn,
    user: user
  } do
    reading!(user, "caught", "Caught Up", %{last_chapter: "10", last_chapter_number: 10})

    {:ok, view, _} = live(conn, "/continuer/home")
    refute render(view) =~ "Caught Up"
  end

  test "nor is one you have finished", %{conn: conn, user: user} do
    reading!(user, "done", "All Done", %{completed: true})

    {:ok, view, _} = live(conn, "/continuer/home")
    refute render(view) =~ "All Done"
  end
end
