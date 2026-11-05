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
    html = open(conn, "/u/statstest/stats")

    assert html =~ "Nothing in this window."
    refute html =~ "Solo Leveling"
  end

  test "the page waits for both halves before it shows a number", %{conn: conn, user: user} do
    read!(user, "Solo Leveling", 7200)

    {:ok, view, html} = live(conn, "/u/statstest/stats")

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

    {:ok, view, _} = live(conn, "/u/statstest/stats")
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

    html = open(conn, "/u/statstest/stats?kind=manga")
    assert html =~ "Solo Leveling"
    assert html =~ "across 1 title of manga"

    html = open(conn, "/u/statstest/stats?kind=movie")
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
    html = open(conn, "/u/statstest/stats?range=week")
    refute html =~ "Long Ago"

    # The year holds that one day, and only what that day holds.
    html = open(conn, "/u/statstest/stats?range=year")
    assert html =~ "Long Ago"
    assert html =~ "1h"
    refute html =~ "10h"

    # All time is the whole tally, including time entered by hand with no day on it.
    html = open(conn, "/u/statstest/stats?range=all")
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

    html = open(conn, "/u/statstest/stats")

    assert html =~ "Day by day"
    # 5400 seconds logged today, so today's cell carries it.
    assert html =~ "1h 30m"
  end

  test "the charts add the same days up by month, and the kind filter reaches them", %{
    conn: conn,
    user: user
  } do
    read!(user, "Solo Leveling", 7200)
    {:ok, bin} = Ecto.UUID.dump(user.uuid)

    Roki.Repo.query!(
      "insert into reading_activity (user_id, date, source, slug, title, reading_seconds, chapters_read, inserted_at, updated_at) " <>
        "values ($1, current_date, 'mangadex', 'solo-leveling', 'Solo Leveling', 5400, 2, now(), now())",
      [bin]
    )

    html = open(conn, "/u/statstest/stats")

    assert html =~ "Over time"
    assert html =~ "By month"
    assert html =~ "By day of the week"
    # The month we are in carries the hour and a half, in manga's colour, and the table says so.
    assert html =~ "bg-success/80"
    assert html =~ "As a table"
    assert html =~ "1h 30m"
    refute html =~ "Nothing in this span."
    # One session is not enough to say anything about the time of day.
    refute html =~ "By time of day"

    # Manga left out: the columns are empty and the chart says so.
    html = open(conn, "/u/statstest/stats?hide=manga")
    assert html =~ "Nothing in this span."
  end

  test "the reader's old stats address leads here", %{conn: conn} do
    conn = get(conn, "/manga/stats")
    assert redirected_to(conn) == "/u/statstest/stats#reading"
  end

  test "each kind is told apart by colour, and a row carries its cover", %{conn: conn, user: user} do
    read!(user, "Solo Leveling", 7200)
    html = open(conn, "/u/statstest/stats")

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

    html = open(conn, "/u/statstest/stats")

    assert html =~ "No Cover"
    assert html =~ "bg-success/20"
    refute html =~ "/manga/proxy/image"
  end

  describe "the row and its popup" do
    setup %{user: user} do
      read!(user, "Overgeared", 8340)

      Roki.Repo.query!(
        "update saved_manga set reading_seconds_offsite = 95460, last_chapter = '331', total_chapters = 342 where slug = 'overgeared'"
      )

      :ok
    end

    test "under the name is the kind and nothing else", %{conn: conn} do
      html = open(conn, "/u/statstest/stats?kind=manga")

      assert html =~ "Overgeared"
      # The wording that used to follow the kind is gone from the list.
      refute html =~ "assumed"
      refute html =~ "added by hand"
      refute html =~ "counted in full"
      refute html =~ "read here"
    end

    test "the number on the right is the way in", %{conn: conn} do
      {:ok, view, _} = live(conn, "/u/statstest/stats?kind=manga")
      render_async(view)

      assert has_element?(
               view,
               ~s|button[phx-click="inspect"][phx-value-key="manga:mangadex/overgeared"]|
             )

      refute has_element?(view, "#detail-dialog")
    end

    test "pressing it opens what was recorded, and closing puts it away", %{conn: conn} do
      {:ok, view, _} = live(conn, "/u/statstest/stats?kind=manga")
      render_async(view)

      html =
        view |> element(~s|button[phx-value-key="manga:mangadex/overgeared"]|) |> render_click()

      assert has_element?(view, "#detail-dialog")
      assert html =~ "Overgeared"
      assert html =~ "Read here"
      assert html =~ "2h 19m"
      assert html =~ "Added by hand"
      assert html =~ "26h 31m"
      assert html =~ "331 of 342"

      view |> element(~s|button[phx-click="close_detail"]|) |> render_click()
      refute has_element?(view, "#detail-dialog")
    end

    test "escape closes it too", %{conn: conn} do
      {:ok, view, _} = live(conn, "/u/statstest/stats?kind=manga")
      render_async(view)
      view |> element(~s|button[phx-value-key="manga:mangadex/overgeared"]|) |> render_click()

      view |> element("#detail-dialog") |> render_keydown(%{"key" => "Escape"})
      refute has_element?(view, "#detail-dialog")
    end

    test "a key that is not a title opens nothing", %{conn: conn} do
      {:ok, view, _} = live(conn, "/u/statstest/stats?kind=manga")
      render_async(view)

      render_click(view, "inspect", %{"key" => "nonsense"})
      render_click(view, "inspect", %{"key" => "tv:999999999"})
      render_click(view, "inspect", %{"key" => "manga:mangadex/not-a-series"})

      refute has_element?(view, "#detail-dialog")
    end

    test "a skipped figure is said under the name only when it is big enough to mean something" do
      assert RokiWeb.StatsLive.skipped_note(%{skipped: 4980}) == " · skipped 1h 23m"
      assert RokiWeb.StatsLive.skipped_note(%{skipped: 59}) == ""
      assert RokiWeb.StatsLive.skipped_note(%{skipped: 0}) == ""
      assert RokiWeb.StatsLive.skipped_note(%{skipped: nil}) == ""
      assert RokiWeb.StatsLive.skipped_note(%{}) == ""
    end
  end

  describe "the kind chips" do
    setup %{user: user} do
      read!(user, "Overgeared", 7200)
      :ok
    end

    # The chip for a kind, found by what it says it will do.
    defp chip(view, hint), do: element(view, ~s|a[title="#{hint}"]|)

    test "pressing a kind once shows only it, and says so", %{conn: conn} do
      {:ok, view, _} = live(conn, "/u/statstest/stats")
      render_async(view)

      view |> chip("Show only manga") |> render_click()
      assert_patch(view, "/u/statstest/stats?kind=manga&range=all")

      html = render(view)
      assert html =~ "across 1 title of manga"
      assert has_element?(view, ~s|a[title="Leave manga out of the numbers"]|)
    end

    test "pressing it again leaves it out: red, struck through, and out of the number", %{
      conn: conn
    } do
      {:ok, view, _} = live(conn, "/u/statstest/stats?kind=manga")
      render_async(view)

      view |> chip("Leave manga out of the numbers") |> render_click()
      assert_patch(view, "/u/statstest/stats?hide=manga&range=all")

      html = render(view)
      # Out of the number and the list…
      assert html =~ "across 0 titles without manga"
      assert html =~ "Nothing in this window."
      refute html =~ "Overgeared"
      # …and shown as left out: red, and struck through, name and figure both.
      assert has_element?(view, ~s|a[title="Put manga back"].btn-error|)
      assert has_element?(view, ~s|a[title="Put manga back"] .line-through|, "Manga")
    end

    test "pressing a red one puts it back", %{conn: conn} do
      {:ok, view, _} = live(conn, "/u/statstest/stats?hide=manga")
      render_async(view)
      refute render(view) =~ "Overgeared"

      view |> chip("Put manga back") |> render_click()
      assert_patch(view, "/u/statstest/stats?range=all")

      html = render(view)
      assert html =~ "Overgeared"
      assert html =~ "across 1 title"
      refute html =~ "without"
      refute has_element?(view, "a.btn-error")
    end

    test "several kinds can be left out at once", %{conn: conn} do
      {:ok, view, _} = live(conn, "/u/statstest/stats?hide=anime")
      render_async(view)

      view |> chip("Show only manga") |> render_click()
      view |> chip("Leave manga out of the numbers") |> render_click()

      html = render(view)
      assert html =~ "without anime &amp; manga"
      assert has_element?(view, ~s|a[title="Put anime back"].btn-error|)
      assert has_element?(view, ~s|a[title="Put manga back"].btn-error|)
      # Films and shows are not in the list anyway, so nothing is left to show.
      assert html =~ "Nothing in this window."
    end

    test "leaving out a kind this account has none of changes nothing", %{conn: conn} do
      {:ok, view, _} = live(conn, "/u/statstest/stats?hide=movie,tv,anime")
      render_async(view)

      html = render(view)
      assert html =~ "Overgeared"
      assert html =~ "without films, shows &amp; anime"
    end

    test "kinds shown alone and kinds left out can be mixed", %{conn: conn} do
      {:ok, view, _} = live(conn, "/u/statstest/stats?kind=movie,manga&hide=movie")
      html = render_async(view)

      # Films are shown alone and also left out, which leaves manga shown alone, without films.
      assert html =~ "of manga without films"
      refute html =~ "of films"
    end

    test "the sentence names a kind shown alone and a kind left out together", %{conn: conn} do
      {:ok, view, _} = live(conn, "/u/statstest/stats?kind=movie,tv&hide=manga")
      html = render_async(view)

      assert html =~ "of films &amp; shows without manga"
    end

    test "a kind named in both is left out", %{conn: conn} do
      {:ok, view, _} = live(conn, "/u/statstest/stats?kind=manga&hide=manga")
      html = render_async(view)

      refute html =~ "Overgeared"
      assert has_element?(view, ~s|a[title="Put manga back"]|)
    end

    test "an address with nonsense in it is read as no filter", %{conn: conn} do
      {:ok, view, _} = live(conn, "/u/statstest/stats?kind=banana&hide=,,")
      html = render_async(view)

      assert html =~ "Overgeared"
      assert has_element?(view, ~s|a.btn-neutral|, "All")
    end

    test "the window tabs keep the filter, and All clears it", %{conn: conn} do
      {:ok, view, _} = live(conn, "/u/statstest/stats?kind=movie&hide=manga&range=month")
      render_async(view)

      assert has_element?(view, ~s|a[href="/u/statstest/stats?hide=manga&kind=movie&range=week"]|)
      assert has_element?(view, ~s|a[href="/u/statstest/stats?range=month"]|, "All")
    end

    test "the figure on a left-out chip is still its own, struck through", %{conn: conn} do
      {:ok, view, _} = live(conn, "/u/statstest/stats?hide=manga")
      render_async(view)

      # The chip says what it would hold, so putting it back is an informed choice.
      assert has_element?(view, ~s|a[title="Put manga back"] .line-through.font-mono|, "2h")
    end
  end

  test "time watched together through a link has its own section", %{conn: conn, user: user} do
    {:ok, friend} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "stats-friend@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "statsfriend"
      })

    {:ok, [[link_id]]} =
      {:ok,
       Roki.Repo.query!(
         "insert into roki_links (type, tmdb_id, created_by, status, inserted_at, updated_at) values ('tv', 99, $1, 'active', now(), now()) returning id",
         [Ecto.UUID.dump!(user.uuid)]
       ).rows}

    for e <- 1..3 do
      Roki.Repo.query!(
        "insert into roki_link_events (link_id, tmdb_id, season, episode, minutes, participants, inserted_at) values ($1, 99, 1, $2, 30, $3, now())",
        [link_id, e, [Ecto.UUID.dump!(user.uuid), Ecto.UUID.dump!(friend.uuid)]]
      )
    end

    {:ok, view, _} = live(conn, "/u/statstest/stats")
    html = render_async(view)
    assert html =~ "Together"
    assert html =~ "Time together"
    assert html =~ "1h 30m"
    assert html =~ "statsfriend"
  end
end
