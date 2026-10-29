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

  # The page holds its numbers until both halves are in, so every assertion here is made
  # after the measurement settles — see "the page waits for both halves" below.
  defp open(conn, path) do
    {:ok, view, _} = live(conn, path)
    render_async(view)
  end

  test "an account that has done nothing shows nothing in the list", %{conn: conn} do
    html = open(conn, "/statstest/stats")

    assert html =~ "Nothing in this window."
    refute html =~ "Solo Leveling"
  end

  test "the page waits for both halves before it shows a number", %{conn: conn, user: user} do
    read!(user, "Solo Leveling", 7200)

    {:ok, view, html} = live(conn, "/statstest/stats")

    # Reading is in hand at once and watching is a measurement, so the first render shows the
    # shape of the answer rather than reading's half of it: no total, no list.
    assert html =~ "skeleton"
    assert html =~ "Measuring what you watched"
    refute html =~ "across 1 title"
    refute html =~ "Solo Leveling"

    # Both halves, together.
    html = render_async(view)
    assert html =~ "across 1 title"
    assert html =~ "Solo Leveling"
    refute html =~ "Measuring what you watched"
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

    html = open(conn, "/statstest/stats?kind=manga")
    assert html =~ "Solo Leveling"
    assert html =~ "across 1 title of manga"

    html = open(conn, "/statstest/stats?kind=movie")
    refute html =~ "Solo Leveling"
    assert html =~ "Nothing in this window."
  end

  test "a window over reading is what those days hold, not the whole title", %{
    conn: conn,
    user: user,
    bin: bin
  } do
    read!(user, "Long Ago", 36_000)

    # Read on one day, 200 days back. The title's own total is ten hours; that day holds one.
    Roki.Repo.query!(
      "insert into reading_activity (user_id, date, source, slug, title, reading_seconds, chapters_read, inserted_at, updated_at) " <>
        "values ($1, current_date - 200, 'mangadex', 'long-ago', 'Long Ago', 3600, 3, now(), now())",
      [bin]
    )

    # Nothing was read this week, so nothing is in it.
    html = open(conn, "/statstest/stats?range=week")
    refute html =~ "Long Ago"

    # The year holds that one day, and only what that day holds.
    html = open(conn, "/statstest/stats?range=year")
    assert html =~ "Long Ago"
    assert html =~ "1h"
    refute html =~ "10h"

    # All time is the whole tally, including time entered by hand with no day on it.
    html = open(conn, "/statstest/stats?range=all")
    assert html =~ "10h"
  end

  test "the heatmap counts the days reading was logged on", %{conn: conn, user: user} do
    read!(user, "Solo Leveling", 7200)
    {:ok, bin} = Ecto.UUID.dump(user.uuid)

    Roki.Repo.query!(
      "insert into reading_activity (user_id, date, source, slug, title, reading_seconds, chapters_read, inserted_at, updated_at) " <>
        "values ($1, current_date, 'mangadex', 'solo-leveling', 'Solo Leveling', 5400, 2, now(), now())",
      [bin]
    )

    html = open(conn, "/statstest/stats")

    assert html =~ "Day by day"
    # 5400 seconds logged today, so today's cell carries it.
    assert html =~ "1h 30m"
  end

  test "the reader's old stats address leads here", %{conn: conn} do
    conn = get(conn, "/manga/stats")
    assert redirected_to(conn) == "/statstest/stats#reading"
  end

  test "each kind is told apart by colour, and a row carries its cover", %{conn: conn, user: user} do
    read!(user, "Solo Leveling", 7200)
    html = open(conn, "/statstest/stats")

    # Reading's bar and its chip are the same colour, so the chips read as the list's legend.
    assert html =~ "bg-success/70"
    assert html =~ "btn-success"
    # And the other kinds have their own, whether or not anything is in them.
    assert html =~ "btn-primary"
    assert html =~ "btn-info"
    assert html =~ "btn-secondary"

    # A manga cover is fetched through the reader's proxy, never hotlinked.
    assert html =~ "/manga/proxy/image"
    assert html =~ "aspect-2/3"
  end

  test "a title with no cover keeps the space and shows its kind", %{conn: conn, user: user} do
    # `read!/3` saves a cover, so this one is blanked to leave a row with no art at all.
    # The column is NOT NULL, and the reader treats an empty cover as none.
    read!(user, "No Cover", 3600)
    Roki.Repo.query!("update saved_manga set cover_url = '' where slug = 'no-cover'")

    html = open(conn, "/statstest/stats")

    assert html =~ "No Cover"
    assert html =~ "bg-success/20"
    refute html =~ "/manga/proxy/image"
  end

  test "reading time entered by hand is called that, not assumed", %{conn: conn, user: user} do
    read!(user, "Overgeared", 8340)

    Roki.Repo.query!(
      "update saved_manga set reading_seconds_offsite = 95460 where slug = 'overgeared'"
    )

    html = open(conn, "/statstest/stats?kind=manga")

    assert html =~ "Overgeared"
    assert html =~ "2h 19m read here"
    assert html =~ "26h 31m added by hand"
    refute html =~ "assumed"
  end
end
