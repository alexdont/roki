defmodule RokiWeb.ShelfLoadingTest do
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "roki-laev-test-#{System.unique_integer([:positive])}")
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
        "email" => "shelf-test@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "shelftest"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token}), user: user}
  end

  test "an account that never connected laev gets its connect card at once, not a skeleton", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, "/u/shelftest/corner")
    assert html =~ "Set up your shelf"
    assert html =~ "New here?"
    refute html =~ "aria-busy"
  end

  test "a connected account sees the page's own shape immediately, with placeholders where data will be",
       %{
         conn: conn,
         user: user
       } do
    dir = Roki.Laev.dir(user.uuid)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "config"),
      "LAEV_SYNC_URL=https://sync.invalid/laev\nLAEV_SYNC_TOKEN=laev_#{String.duplicate("a", 40)}\n"
    )

    {:ok, _view, html} = live(conn, "/u/shelftest/corner")

    # The real strip and its sync button are there from the first paint — and no
    # "Your shelf" title, which says nothing the page does not already.
    refute html =~ "Your shelf"
    refute html =~ "Welcome back"
    assert html =~ "all stats"
    assert html =~ ~s(aria-label="Sync now")
    # …with a placeholder grid standing where the Watchlist will be…
    assert html =~ "aria-busy"
    assert length(Regex.scan(~r/skeleton aspect-\[2\/3\]/, html)) == 16
    # …and nothing to click until there is a shelf to act on.
    assert Regex.scan(~r/<button[^>]*disabled[^>]*>/, html) != []
    refute html =~ "Connect laev"
  end

  # A connected account: laev's config file is what says so.
  defp connect!(user) do
    dir = Roki.Laev.dir(user.uuid)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "config"),
      "LAEV_SYNC_URL=https://sync.invalid/laev\nLAEV_SYNC_TOKEN=laev_#{String.duplicate("a", 40)}\n"
    )
  end

  # The smallest shelf the page will draw.
  defp shelf(behind) do
    %{
      tally: %{behind: behind, series_finished: 4, anime_finished: 2},
      watchlist: %{behind: [], caught_up: [], on_hold: []},
      continue: [],
      saved: []
    }
  end

  describe "a kept shelf" do
    test "paints at once, with no skeleton, and in the page the server sends", %{
      conn: conn,
      user: user
    } do
      connect!(user)
      Roki.Laev.remember_shelf(user.uuid, shelf(7))

      # The first, static render — before any socket exists.
      html = conn |> get("/u/shelftest/corner") |> html_response(200)
      assert html =~ "in progress"
      refute html =~ "aria-busy"

      # And the connected one.
      {:ok, _view, html} = live(conn, "/u/shelftest/corner")
      assert html =~ "in progress"
      refute html =~ "aria-busy"
    end

    test "is not shown to an account that is no longer connected", %{conn: conn, user: user} do
      # Kept while it was connected, then disconnected — no config file now.
      Roki.Laev.remember_shelf(user.uuid, shelf(7))

      {:ok, _view, html} = live(conn, "/u/shelftest/corner")
      assert html =~ "Set up your shelf"
      refute html =~ "in progress"
    end

    test "is forgotten when the account is disconnected", %{user: user} do
      connect!(user)
      Roki.Laev.remember_shelf(user.uuid, shelf(7))
      assert {:ok, _, _} = Roki.Laev.cached_shelf(user.uuid)

      Roki.Laev.disconnect(user.uuid)

      assert Roki.Laev.cached_shelf(user.uuid) == :miss
    end

    test "survives a restart: with memory empty it is read back from beside the account's data",
         %{user: user} do
      connect!(user)
      Roki.Laev.remember_shelf(user.uuid, shelf(5))

      # A restart empties memory and leaves the disk.
      Roki.TTLCache.delete({:shelf, user.uuid})

      assert {:ok, %{tally: %{behind: 5}}, age} = Roki.Laev.cached_shelf(user.uuid)
      assert age in 0..2
      # And it is back in memory afterwards, so the next page does not read the file.
      assert {:ok, _} = Roki.TTLCache.peek({:shelf, user.uuid})
    end

    test "never creates a directory for an account that has none", %{user: user} do
      refute File.dir?(Roki.Laev.dir(user.uuid))

      Roki.Laev.remember_shelf(user.uuid, shelf(5))

      refute File.dir?(Roki.Laev.dir(user.uuid))
    end

    test "a file that cannot be read is a miss, not a crash", %{user: user} do
      connect!(user)
      File.write!(Path.join(Roki.Laev.dir(user.uuid), "roki-shelf.etf"), "not an erlang term")

      assert Roki.Laev.cached_shelf(user.uuid) == :miss
    end

    test "a file older than a week is as good as none", %{user: user} do
      connect!(user)
      old = %{at: System.os_time(:second) - 8 * 86_400, data: shelf(5)}

      File.write!(
        Path.join(Roki.Laev.dir(user.uuid), "roki-shelf.etf"),
        :erlang.term_to_binary(old)
      )

      assert Roki.Laev.cached_shelf(user.uuid) == :miss
    end

    test "forgetting removes the file as well, so a restart cannot bring it back", %{user: user} do
      connect!(user)
      Roki.Laev.remember_shelf(user.uuid, shelf(5))
      assert File.exists?(Path.join(Roki.Laev.dir(user.uuid), "roki-shelf.etf"))

      Roki.Laev.forget_shelf(user.uuid)

      refute File.exists?(Path.join(Roki.Laev.dir(user.uuid), "roki-shelf.etf"))
      assert Roki.Laev.cached_shelf(user.uuid) == :miss
    end

    test "says how old it is", %{user: user} do
      assert Roki.Laev.cached_shelf(user.uuid) == :miss

      Roki.Laev.remember_shelf(user.uuid, shelf(3))
      assert {:ok, %{tally: %{behind: 3}}, age} = Roki.Laev.cached_shelf(user.uuid)
      assert age in 0..2
    end

    test "an old one is shown first, then replaced in place by what laev says now", %{
      conn: conn,
      user: user
    } do
      connect!(user)

      Roki.TTLCache.put(
        {:shelf, user.uuid},
        3600,
        {:ok, %{at: System.os_time(:second) - 3600, data: shelf(7)}}
      )

      {:ok, view, html} = live(conn, "/u/shelftest/corner")

      # What was kept is what the page opens with…
      assert html =~ ~s(<b class="text-base-content">7</b>)
      refute html =~ "aria-busy"

      # …and the look behind it has the last word. This account has nothing in laev yet.
      html = render_async(view, 15_000)
      assert html =~ ~s(<b class="text-base-content">0</b>)
      refute html =~ ~s(<b class="text-base-content">7</b>)
    end

    test "a recent one is left alone, not read again", %{conn: conn, user: user} do
      connect!(user)
      Roki.Laev.remember_shelf(user.uuid, shelf(7))

      {:ok, view, _html} = live(conn, "/u/shelftest/corner")
      html = render_async(view, 15_000)

      # Still the kept figure: nothing replaced it, because nothing was asked for.
      assert html =~ ~s(<b class="text-base-content">7</b>)
    end

    test "a refresh that fails leaves the shelf on screen, and says nothing" do
      kept = shelf(7)

      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, data: kept, state: :ready, busy: "Syncing…", error: nil}
      }

      assert {:noreply, after_failure} =
               RokiWeb.UserHomeLive.handle_async(:overview, {:exit, :boom}, socket)

      assert after_failure.assigns.data == kept
      assert after_failure.assigns.state == :ready
      assert after_failure.assigns.error == nil
      assert after_failure.assigns.busy == nil
    end

    test "the same failure with nothing on screen is still an error" do
      socket = %Phoenix.LiveView.Socket{
        assigns: %{__changed__: %{}, data: nil, state: :loading, busy: nil, error: nil}
      }

      assert {:noreply, after_failure} =
               RokiWeb.UserHomeLive.handle_async(:overview, {:exit, :boom}, socket)

      assert after_failure.assigns.state == :not_connected
      assert after_failure.assigns.error =~ "Could not read your shelf"
    end
  end

  describe "the reading half of the strip" do
    setup %{user: user} do
      {:ok, _} =
        Roki.Manga.Library.save_manga(user.uuid, %{
          source: "mangafreak",
          slug: "overgeared",
          title: "Overgeared",
          cover_url: "https://example.invalid/o.jpg"
        })

      Roki.Repo.query!(
        "update saved_manga set reading_seconds = 8340, reading_seconds_offsite = 95460, last_chapter = '331'"
      )

      :ok
    end

    test "says how long and how much, on the first paint, before anything watched has loaded", %{
      conn: conn,
      user: user
    } do
      connect!(user)

      {:ok, _view, html} = live(conn, "/u/shelftest/corner")

      # Still waiting for the shelf, and reading is already there.
      assert html =~ "aria-busy"
      assert html =~ "28h 50m"
      assert html =~ "331"
      assert html =~ "chapters"
    end

    test "is left out for an account that has read nothing", %{conn: conn, user: user} do
      Roki.Repo.query!("delete from saved_manga")
      connect!(user)

      {:ok, _view, html} = live(conn, "/u/shelftest/corner")

      refute html =~ " read\n"
      refute html =~ "chapters"
    end
  end

  describe "the strip's watching figures" do
    @totals %{totals: %{seconds: 360_000, films: 1350, episodes: 9000}, films: %{}}

    test "are on the first frame when they are kept, so no placeholder is swapped for them", %{
      conn: conn,
      user: user
    } do
      connect!(user)
      Roki.Laev.remember_shelf(user.uuid, shelf(7))
      Roki.Laev.remember_totals(user.uuid, @totals)

      # The page the server sends, before any socket.
      html = conn |> get("/u/shelftest/corner") |> html_response(200)

      assert html =~ "100h"
      assert html =~ "1,350"
      assert html =~ "films watched"
      # The ghost that used to stand in for them is not drawn.
      refute html =~ "w-[8.1rem]"
    end

    test "are drawn as placeholders when nothing is kept, in cells of their own", %{
      conn: conn,
      user: user
    } do
      connect!(user)

      {:ok, _view, html} = live(conn, "/u/shelftest/corner")

      assert html =~ "w-[8.1rem]"
      refute html =~ "films watched"
      # The strip is a grid on a phone, so a late figure can only change its own cell.
      assert html =~ "grid-cols-2"
    end

    test "survive the page being loaded cold, because a missing shelf is not missing figures",
         %{conn: conn, user: user} do
      connect!(user)
      Roki.Laev.remember_totals(user.uuid, @totals)

      {:ok, _view, html} = live(conn, "/u/shelftest/corner")

      # No shelf kept, so the shelf's own placeholders stand in…
      assert html =~ "aria-busy"
      # …but the figures that are kept are not thrown away to be fetched again.
      assert html =~ "1,350"
    end

    test "are not shown to an account that is no longer connected", %{conn: conn, user: user} do
      Roki.Laev.remember_totals(user.uuid, @totals)

      {:ok, _view, html} = live(conn, "/u/shelftest/corner")

      refute html =~ "1,350"
    end

    test "are kept beside the account's data, and forgotten with the shelf", %{user: user} do
      connect!(user)
      Roki.Laev.remember_totals(user.uuid, @totals)
      file = Path.join(Roki.Laev.dir(user.uuid), "roki-totals.etf")
      assert File.exists?(file)

      # A restart empties memory and leaves the disk.
      Roki.TTLCache.delete({:totals, user.uuid})
      assert {:ok, @totals, _age} = Roki.Laev.cached_totals(user.uuid)

      Roki.Laev.forget_shelf(user.uuid)
      refute File.exists?(file)
      assert Roki.Laev.cached_totals(user.uuid) == :miss
    end

    test "are kept by the measurement that produces them", %{user: user} do
      # A summary already in hand, so nothing is measured from laev.
      Roki.TTLCache.put(
        {:stats_summary, user.uuid},
        3600,
        {:ok, %{at: System.os_time(:second), value: @totals}}
      )

      assert Roki.Profile.kept_totals(user.uuid) == :miss

      assert {:ok, measured} = Roki.Profile.totals(user.uuid)
      assert {:ok, ^measured} = Roki.Profile.kept_totals(user.uuid)
    end
  end

  describe "the strip's layout" do
    test "'all stats' is its own link beside the sync button, not a cell in the wrapping row", %{
      conn: conn,
      user: user
    } do
      connect!(user)
      Roki.Laev.remember_shelf(user.uuid, shelf(7))

      Roki.Laev.remember_totals(user.uuid, %{
        totals: %{seconds: 3600, films: 1, episodes: 1},
        films: %{}
      })

      {:ok, view, _} = live(conn, "/u/shelftest/corner")

      # A link inside a wrapping row is the first thing to drop to a second line when the
      # figures are wide, so it is not inside it.
      assert has_element?(view, ~s|a[href="/u/shelftest/stats"]|, "all stats")
      refute has_element?(view, ~s|a[href="/u/shelftest/stats"].grid|, "all stats")
    end

    test "the reading figures are pinned to the end of the row, so those before them cannot move them",
         %{conn: conn, user: user} do
      {:ok, _} =
        Roki.Manga.Library.save_manga(user.uuid, %{
          source: "mangafreak",
          slug: "o",
          title: "O",
          cover_url: "https://example.invalid/o.jpg"
        })

      Roki.Repo.query!("update saved_manga set reading_seconds = 3600, last_chapter = '5'")
      connect!(user)
      Roki.Laev.remember_shelf(user.uuid, shelf(7))

      {:ok, view, _} = live(conn, "/u/shelftest/corner")

      assert has_element?(view, "span.sm\\:ml-auto", "read")
    end

    test "a placeholder is drawn in the same cell the figure will be, without a reserved width",
         %{
           conn: conn,
           user: user
         } do
      connect!(user)
      Roki.Laev.remember_shelf(user.uuid, shelf(7))

      {:ok, _view, html} = live(conn, "/u/shelftest/corner")

      # Sized like the figure it stands for…
      assert html =~ "w-[8.1rem]"
      # …and no cell reserves room for the widest figure there could ever be, which is what made
      # the row wrap on an ordinary laptop.
      refute html =~ "sm:min-w-["
    end
  end
end
