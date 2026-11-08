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
             live(build_conn(), "/u/settingstest/settings")

    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/u/someone-else/settings")
  end

  test "the reader's preferences are on this page, whether or not laev is connected", %{
    conn: conn
  } do
    {:ok, _view, html} = live(conn, "/u/settingstest/settings")

    assert html =~ "Connect laev in your corner"
    assert html =~ ~s(id="reading")
    assert html =~ "Default tap zone layout"
    assert html =~ "Default reading direction"
    assert html =~ "Panel snap settings"
    assert html =~ "Default page padding"
    # The reader's own hook, so every control still saves itself with a PUT.
    assert html =~ "RokiWeb.MangaSettings.ReaderSettings"
  end

  test "the Nuvio section lists the providers with the defaults already on", %{conn: conn} do
    {:ok, view, _html} = live(conn, "/u/settingstest/settings?tab=sources")
    html = render_async(view, 5_000)

    assert has_element?(view, "#nuvio")
    assert html =~ "providers in the manifest"
    refute html =~ "I am authorised to use this provider"

    for id <- Roki.Nuvio.Settings.defaults() do
      assert has_element?(view, ~s(#nuvio-#{id} input[role="switch"][checked]))
    end
  end

  test "a Nuvio provider is switched on and off with one toggle", %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, "/u/settingstest/settings?tab=sources")
    render_async(view, 5_000)
    switch = ~s(#nuvio-purstream input[role="switch"])

    assert has_element?(view, "#nuvio-purstream input[role=switch]:not([checked])")

    view |> element(switch) |> render_click()
    assert has_element?(view, switch <> "[checked]")
    assert "purstream" in Roki.Nuvio.Settings.enabled_ids(user.uuid)

    view |> element(switch) |> render_click()
    refute has_element?(view, switch <> "[checked]")
    refute "purstream" in Roki.Nuvio.Settings.enabled_ids(user.uuid)

    # A default switches off the same way, and stays off.
    view |> element(~s(#nuvio-movix input[role="switch"])) |> render_click()
    refute "movix" in Roki.Nuvio.Settings.enabled_ids(user.uuid)
  end

  test "the count says how many are on, and providers past the limit are marked not asked", %{
    conn: conn,
    user: user
  } do
    {:ok, view, _html} = live(conn, "/u/settingstest/settings?tab=sources")
    render_async(view, 5_000)
    assert render(element(view, "#nuvio-count")) =~ "4 on"
    assert render(element(view, "#nuvio-count")) =~ "up to 18 are asked per search"

    # Switch on enough eligible providers to pass the limit. The oldest in the order (the
    # defaults come after the account's own) drop out first.
    {:ok, providers} = Roki.Nuvio.Registry.providers()

    extra =
      providers
      |> Enum.filter(& &1.enabled)
      |> Enum.map(& &1.id)
      |> Kernel.--(Roki.Nuvio.Settings.defaults())
      |> Enum.take(16)

    Enum.reduce(extra, user, fn id, user ->
      {:ok, user} = Roki.Nuvio.Settings.set_enabled(user, id, true)
      user
    end)

    {:ok, view, _html} = live(conn, "/u/settingstest/settings?tab=sources")
    render_async(view, 5_000)
    count = render(element(view, "#nuvio-count"))
    assert count =~ "20 on"
    assert count =~ "only the first 18 are asked per search"

    # 16 own + 4 defaults: the last two defaults in order are past the limit.
    [_, _, third, fourth] = Roki.Nuvio.Settings.defaults()

    for id <- [third, fourth] do
      assert has_element?(view, "#nuvio-#{id} .badge", "not asked")
    end

    refute has_element?(view, "#nuvio-#{hd(extra)} .badge", "not asked")
  end

  test "Reset to defaults puts back exactly the default Nuvio providers", %{
    conn: conn,
    user: user
  } do
    {:ok, user} = Roki.Nuvio.Settings.set_enabled(user, "purstream", true)
    {:ok, user} = Roki.Nuvio.Settings.set_enabled(user, "movix", false)
    {:ok, _user} = Roki.Nuvio.Settings.set_options(user, "purstream", %{"lang" => "fr"})

    {:ok, view, _html} = live(conn, "/u/settingstest/settings?tab=sources")
    render_async(view, 5_000)
    reset = ~s(#nuvio button[phx-click="nuvio_reset"])
    refute has_element?(view, reset <> "[disabled]")

    html = view |> element(reset) |> render_click()
    assert html =~ "Back to the default providers."
    assert Roki.Nuvio.Settings.enabled_ids(user.uuid) == Roki.Nuvio.Settings.defaults()
    assert has_element?(view, ~s(#nuvio-movix input[role="switch"][checked]))
    refute has_element?(view, ~s(#nuvio-purstream input[role="switch"][checked]))
    assert has_element?(view, reset <> "[disabled]")
    # Options are not sources; they stay.
    assert Roki.Nuvio.Settings.options(user.uuid, "purstream") == %{"lang" => "fr"}
  end

  test "the reader's old settings address leads here", %{conn: conn} do
    conn = get(conn, "/manga/settings")
    assert redirected_to(conn) == "/u/settingstest/settings#reading"
  end

  test "an account that has not connected laev is pointed at the shelf", %{conn: conn} do
    {:ok, view, html} = live(conn, "/u/settingstest/settings")
    assert html =~ "Connect laev in your corner"
    refute render(view) =~ "Auto-pick"
  end

  test "without a TMDB account the page offers to link one, and says where to come back to", %{
    conn: conn,
    user: user
  } do
    connect!(user)
    {:ok, view, _} = live(conn, "/u/settingstest/settings?tab=accounts")
    html = render_async(view, 3000)

    assert html =~ "TMDB"
    assert html =~ "Link my TMDB account"
    assert html =~ ~s(href="/tmdb/link?return=%2Fu%2Fsettingstest%2Fsettings")
    refute html =~ "Unlink"
  end

  test "a linked TMDB account can add an IMDb export to date its titles, and a wrong file is refused",
       %{conn: conn, user: user} do
    dir = connect!(user)

    File.write!(
      Path.join(dir, "config"),
      File.read!(Path.join(dir, "config")) <> "TMDB_SESSION_ID=abc123\n"
    )

    {:ok, view, _} = live(conn, "/u/settingstest/settings?tab=accounts")
    html = render_async(view, 3000)
    assert html =~ "Date my titles"
    assert html =~ "Your ratings → Export"

    upload = fn name, body ->
      file_input(view, "form[phx-submit=imdb_dates]", :imdb_csv, [
        %{name: name, content: body, type: "text/csv"}
      ])
    end

    render_upload(
      upload.("ratings.csv", "Const,Date Rated,Title Type\ntt0000001,2020-01-01,Movie\n"),
      "ratings.csv"
    )

    view |> form("form[phx-submit=imdb_dates]") |> render_submit()
    assert render_async(view, 5000) =~ "Dated 0 titles from your export"

    render_upload(upload.("other.csv", "a,b\n1,2\n"), "other.csv")
    view |> form("form[phx-submit=imdb_dates]") |> render_submit()
    assert render_async(view, 5000) =~ "not an IMDb ratings export"
  end

  test "unlinking takes the session and the copied TMDB ratings, and keeps the MyAnimeList ones",
       %{user: user} do
    dir = connect!(user)

    File.write!(
      Path.join(dir, "config"),
      File.read!(Path.join(dir, "config")) <> "TMDB_SESSION_ID=abc123\n"
    )

    {:ok, bin} = Ecto.UUID.dump(user.uuid)

    for {type, id} <- [{"movie", 1}, {"tv", 2}, {"mal", 3}] do
      Roki.Repo.query!(
        "insert into roki_ratings (user_uuid, type, id, score) values ($1, $2, $3, 8)",
        [bin, type, id]
      )
    end

    assert {:ok, false} = Roki.Laev.tmdb_logout(user.uuid)
    assert Map.get(Laev.Config.read_dir(dir), :tmdb_session) in [nil, ""]
    assert Roki.Profile.ratings(user.uuid) |> Map.keys() == [{"mal", 3}]
  end

  test "notification switches: friends' activity starts off, a switch takes effect at once, and it is the person's own",
       %{conn: conn, user: user} do
    # Open to someone who has not connected laev too: it is about the bell, not about laev.
    {:ok, view, html} = live(conn, "/u/settingstest/settings?tab=notifications")
    assert html =~ "Notifications"
    assert html =~ "New episodes and releases"

    refute Roki.Notify.wants?(user.uuid, "friend_activity")
    assert Roki.Notify.wants?(user.uuid, "release")

    view
    |> element("input[phx-click=notify_toggle][phx-value-key=friend_activity]")
    |> render_click()

    assert Roki.Notify.wants?(user.uuid, "friend_activity")

    view |> element("input[phx-click=notify_toggle][phx-value-key=release]") |> render_click()
    refute Roki.Notify.wants?(user.uuid, "release")
    assert Roki.Notify.choices(user.uuid)["release"] == false

    # A made-up kind is ignored, not stored.
    render_click(view, "notify_toggle", %{"key" => "nonsense"})
    refute Map.has_key?(Roki.Notify.choices(user.uuid), "nonsense")
  end

  test "the settings are laid out by group, with laev's own labels", %{conn: conn, user: user} do
    connect!(user)
    {:ok, view, _} = live(conn, "/u/settingstest/settings")
    render_async(view, 3000)

    html =
      Enum.map_join(~w(general accounts sync), fn tab ->
        render_patch(view, "/u/settingstest/settings?tab=#{tab}")
      end)

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
    {:ok, view, _} = live(conn, "/u/settingstest/settings")
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
    {:ok, view, _} = live(conn, "/u/settingstest/settings?tab=sync")
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
    {:ok, view, _} = live(conn, "/u/settingstest/settings")
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
    {:ok, view, _} = live(conn, "/u/settingstest/settings")
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

    {:ok, view, _} = live(conn, "/u/settingstest/settings?tab=sync")
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
    {:ok, view, _} = live(conn, "/u/settingstest/settings")
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
    {:ok, view, _} = live(conn, "/u/settingstest/settings")
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
    {:ok, view, _} = live(conn, "/u/settingstest/settings?tab=accounts")
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
    # the edit form is closed again (the debrid paste section, shown to an account with no
    # debrid key, has password fields of its own, so it is the replace form that is checked)
    refute has_element?(view, "form[phx-submit=replace]")
  end

  test "the settings page is in the header", %{conn: conn, user: user} do
    connect!(user)
    {:ok, _view, html} = live(conn, "/u/settingstest/settings")
    assert html =~ ">\n      Settings\n    </a>" or html =~ ~r/>\s*Settings\s*</
  end
end
