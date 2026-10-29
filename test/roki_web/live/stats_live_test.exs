defmodule RokiWeb.StatsLiveTest do
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Roki.Manga.Library

  setup %{conn: conn} do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "stats-test@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "statstest"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, bin} = Ecto.UUID.dump(user.uuid)

    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token}), user: user, bin: bin}
  end

  # `reading_seconds` is the reader's own tally and the changeset does not cast it,
  # so the row goes in first and the time is set the way the reader sets it.
  defp read!(user, title, seconds) do
    slug = String.downcase(String.replace(title, " ", "-"))

    {:ok, _} =
      Library.save_manga(user.uuid, %{
        source: "mangadex",
        slug: slug,
        title: title,
        cover_url: "https://example.invalid/#{slug}.jpg"
      })

    Roki.Repo.query!(
      "update saved_manga set reading_seconds = $1 where user_id = $2::text::uuid and slug = $3",
      [seconds, user.uuid, slug]
    )
  end

  test "an account that has done nothing shows nothing in the list", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/statstest/stats")

    assert html =~ "Nothing in this window."
    refute html =~ "Solo Leveling"
  end

  test "reading counts towards the total, and is in the one list", %{conn: conn, user: user} do
    read!(user, "Solo Leveling", 7200)
    read!(user, "Berserk", 3600)

    {:ok, view, _} = live(conn, "/statstest/stats")
    html = render_async(view)

    # One list, both series in it, and the headline is their sum.
    assert html =~ "Solo Leveling"
    assert html =~ "Berserk"
    assert html =~ "Where the time went"
    assert html =~ "3h"
    assert html =~ "across 2 titles"
    # Laev is not connected here; the page is still worth opening.
    assert html =~ "Connect laev"
  end

  test "the kind filter narrows the total and the list", %{conn: conn, user: user} do
    read!(user, "Solo Leveling", 7200)

    {:ok, _view, html} = live(conn, "/statstest/stats?kind=manga")
    assert html =~ "Solo Leveling"
    assert html =~ "across 1 title of manga"

    {:ok, _view, html} = live(conn, "/statstest/stats?kind=movie")
    refute html =~ "Solo Leveling"
    assert html =~ "Nothing in this window."
  end

  test "a window keeps what was touched inside it", %{conn: conn, user: user, bin: bin} do
    read!(user, "Long Ago", 7200)

    Roki.Repo.query!(
      "update saved_manga set updated_at = now() - interval '200 days' where user_id = $1",
      [bin]
    )

    {:ok, _view, html} = live(conn, "/statstest/stats?range=week")
    refute html =~ "Long Ago"

    {:ok, _view, html} = live(conn, "/statstest/stats?range=year")
    assert html =~ "Long Ago"
  end

  test "the heatmap counts the days reading was logged on", %{conn: conn, user: user} do
    read!(user, "Solo Leveling", 7200)
    {:ok, bin} = Ecto.UUID.dump(user.uuid)

    Roki.Repo.query!(
      "insert into reading_activity (user_id, date, source, slug, title, reading_seconds, chapters_read, inserted_at, updated_at) " <>
        "values ($1, current_date, 'mangadex', 'solo-leveling', 'Solo Leveling', 5400, 2, now(), now())",
      [bin]
    )

    {:ok, _view, html} = live(conn, "/statstest/stats")

    assert html =~ "Day by day"
    # 5400 seconds logged today, so today's cell carries it.
    assert html =~ "1h 30m"
  end

  test "the reader's old stats address leads here", %{conn: conn} do
    conn = get(conn, "/manga/stats")
    assert redirected_to(conn) == "/statstest/stats#reading"
  end
end
