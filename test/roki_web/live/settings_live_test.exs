defmodule RokiWeb.SettingsLiveTest do
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "roki-settings-live-#{System.unique_integer([:positive])}")
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
        "email" => "settings-test@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "settingstest"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token}), user: user}
  end

  defp connect!(user) do
    dir = Roki.Laev.dir(user.uuid)
    File.mkdir_p!(dir)

    File.write!(
      Path.join(dir, "config"),
      "LAEV_SYNC_URL=https://sync.invalid/laev\nLAEV_SYNC_TOKEN=laev_#{String.duplicate("a", 40)}\n"
    )

    dir
  end

  test "someone else's settings are not yours: a visitor goes to the login, another user home", %{
    conn: conn
  } do
    assert {:error, {:live_redirect, %{to: "/phoenix_kit/users/log-in"}}} =
             live(build_conn(), "/settingstest/settings")

    assert {:error, {:live_redirect, %{to: "/home"}}} = live(conn, "/someone-else/settings")
  end

  test "an account that has not connected laev is pointed at the shelf", %{conn: conn} do
    {:ok, view, html} = live(conn, "/settingstest/settings")
    assert html =~ "Connect laev on your shelf"
    refute render(view) =~ "Auto-pick"
  end

  test "without a TMDB account the page offers to link one, and says where to come back to", %{conn: conn, user: user} do
    connect!(user)
    {:ok, view, _} = live(conn, "/settingstest/settings")
    html = render_async(view, 3000)

    assert html =~ "TMDB"
    assert html =~ "Link my TMDB account"
    assert html =~ ~s(href="/tmdb/link?return=%2Fsettingstest%2Fsettings")
    refute html =~ "Unlink"
  end

  test "unlinking takes the session and the copied TMDB ratings, and keeps the MyAnimeList ones", %{user: user} do
    dir = connect!(user)
    File.write!(Path.join(dir, "config"), File.read!(Path.join(dir, "config")) <> "TMDB_SESSION_ID=abc123\n")
    {:ok, bin} = Ecto.UUID.dump(user.uuid)

    for {type, id} <- [{"movie", 1}, {"tv", 2}, {"mal", 3}] do
      Roki.Repo.query!("insert into roki_ratings (user_uuid, type, id, score) values ($1, $2, $3, 8)", [bin, type, id])
    end

    assert {:ok, false} = Roki.Laev.tmdb_logout(user.uuid)
    assert Map.get(Laev.Config.read_dir(dir), :tmdb_session) in [nil, ""]
    assert Roki.Profile.ratings(user.uuid) |> Map.keys() == [{"mal", 3}]
  end

  test "the settings are laid out by group, with laev's own labels", %{conn: conn, user: user} do
    connect!(user)
    {:ok, view, _} = live(conn, "/settingstest/settings")
    html = render_async(view, 3000)

    for text <- [
          "Playback",
          "Language",
          "Auto-pick the best source",
          "Resolution ceiling",
          "Audio language",
          "Connections",
          "Real-Debrid token",
          "Sync",
          "Carry my API keys"
        ] do
      assert html =~ text, "missing #{text}"
    end

    refute html =~ "laev_" <> String.duplicate("a", 10)
  end

  test "a choice saves the moment it changes", %{conn: conn, user: user} do
    dir = connect!(user)
    {:ok, view, _} = live(conn, "/settingstest/settings")
    render_async(view, 3000)

    html =
      view
      |> form("form[phx-change=change]")
      |> render_change(%{
        "_target" => ["s", "LAEV_AUTO_SOURCE"],
        "s" => %{"LAEV_AUTO_SOURCE" => "off"}
      })

    assert html =~ "Saved"
    assert File.read!(Path.join(dir, "config")) =~ "LAEV_AUTO_SOURCE=off"
  end

  test "the terminal app's settings are shown but locked", %{conn: conn, user: user} do
    connect!(user)
    {:ok, view, _} = live(conn, "/settingstest/settings")
    html = render_async(view, 3000)

    assert html =~ "Terminal app only"
    assert html =~ "CLI only"

    for key <- ~w(LAEV_PLAYER LAEV_POSTERS LAEV_SKIP LAEV_DOWNLOAD_DIR LAEV_MPV_ARGS) do
      assert has_element?(view, ~s([name="s[#{key}]"][disabled])), "#{key} should be locked"
    end

    # the player lists every choice, even ones this server cannot run
    for o <- ~w(vlc mpv browser), do: assert(has_element?(view, "#s-LAEV_PLAYER option", o))
    # while the shared ones stay editable
    refute has_element?(view, ~s([name="s[LAEV_AUTO_SOURCE]"][disabled]))

    html =
      render_hook(view, "change", %{
        "_target" => ["s", "LAEV_PLAYER"],
        "s" => %{"LAEV_PLAYER" => "vlc"}
      })

    assert html =~ "can only be changed in the terminal app"
  end

  test "the browser player's own resolution cap saves, and starts at 4K", %{
    conn: conn,
    user: user
  } do
    dir = connect!(user)
    {:ok, view, _} = live(conn, "/settingstest/settings")
    html = render_async(view, 3000)

    assert html =~ "browser player"
    assert has_element?(view, "#w-browser_max_resolution option[selected]", "4K")

    html =
      render_hook(view, "change", %{
        "_target" => ["w", "browser_max_resolution"],
        "w" => %{"browser_max_resolution" => "720p"}
      })

    assert html =~ "Saved"
    assert Roki.Laev.web_settings(user.uuid)["browser_max_resolution"] == "720p"
    refute File.read!(Path.join(dir, "config")) =~ "720p"

    html =
      render_hook(view, "change", %{
        "_target" => ["w", "browser_max_resolution"],
        "w" => %{"browser_max_resolution" => "4K"}
      })

    assert html =~ "not one of"
    assert Roki.Laev.web_settings(user.uuid)["browser_max_resolution"] == "720p"
  end

  test "the player for this device can be changed, and defaults to external", %{
    conn: conn,
    user: user
  } do
    connect!(user)
    {:ok, view, _} = live(conn, "/settingstest/settings")
    render_async(view, 3000)

    assert has_element?(view, "#d-player option[selected]", "External player")

    view
    |> form("#settings-form")
    |> render_change(%{"_target" => ["d", "player"], "d" => %{"player" => "browser"}})

    assert_push_event(view, "roki:player", %{mode: "browser"})
    assert has_element?(view, "#d-player option[selected]", "Browser")
  end

  test "when keys are carried, a change schedules its own sync", %{conn: conn, user: user} do
    dir = connect!(user)
    # carrying keys needs the whole laev key: the token and the half that never leaves the device
    File.write!(
      Path.join(dir, "config"),
      "LAEV_SYNC_URL=https://sync.invalid/laev\n" <>
        "LAEV_SYNC_TOKEN=laev_#{String.duplicate("a", 40)}.#{String.duplicate("b", 40)}\nLAEV_SYNC_KEYS=on\n"
    )

    {:ok, view, _} = live(conn, "/settingstest/settings")
    html = render_async(view, 3000)
    assert html =~ "No need"

    html =
      render_hook(view, "change", %{
        "_target" => ["s", "LAEV_AUTO_SOURCE"],
        "s" => %{"LAEV_AUTO_SOURCE" => "off"}
      })

    assert html =~ "sending it on"

    # the sync server in this test does not exist: it says so rather than pretending
    send(view.pid, :auto_sync)
    render_async(view, 3000)
    assert render(view) =~ "Couldn&#39;t reach the sync server"
  end

  test "the external player app can be chosen, from a fixed list", %{conn: conn, user: user} do
    connect!(user)
    {:ok, view, _} = live(conn, "/settingstest/settings")
    render_async(view, 3000)

    assert has_element?(view, "#w-external_app option[selected]", "VLC")

    for app <- ~w(infuse mpv m3u vlc) do
      render_hook(view, "change", %{
        "_target" => ["w", "external_app"],
        "w" => %{"external_app" => app}
      })

      assert Roki.Laev.web_settings(user.uuid)["external_app"] == app
    end

    html =
      render_hook(view, "change", %{
        "_target" => ["w", "external_app"],
        "w" => %{"external_app" => "quicktime"}
      })

    assert html =~ "not one of"
  end

  test "a value laev refuses is explained, not saved", %{conn: conn, user: user} do
    dir = connect!(user)
    {:ok, view, _} = live(conn, "/settingstest/settings")
    render_async(view, 3000)

    html =
      render_hook(view, "change", %{
        "_target" => ["s", "LAEV_AUTO_SOURCE"],
        "s" => %{"LAEV_AUTO_SOURCE" => "maybe"}
      })

    assert html =~ "must be one of"
    refute File.read!(Path.join(dir, "config")) =~ "LAEV_AUTO_SOURCE"
  end

  test "adding a key: the form opens, the key is saved masked and never echoed", %{
    conn: conn,
    user: user
  } do
    connect!(user)
    {:ok, view, _} = live(conn, "/settingstest/settings")
    render_async(view, 3000)

    html =
      view |> element("button[phx-click=edit][phx-value-key=JIMAKU_API_KEY]") |> render_click()

    assert html =~ ~s(type="password")

    secret = "jimaku-secret-key-0123456789"

    view
    |> form("form[phx-submit=replace]", %{"key" => "JIMAKU_API_KEY", "value" => secret})
    |> render_submit()

    html = render_async(view, 3000)

    assert html =~ "•"
    refute html =~ secret
    refute html =~ ~s(type="password")
  end

  test "the settings page is in the header", %{conn: conn, user: user} do
    connect!(user)
    {:ok, _view, html} = live(conn, "/settingstest/settings")
    assert html =~ ">\n      Settings\n    </a>" or html =~ ~r/>\s*Settings\s*</
  end
end
