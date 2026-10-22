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

  test "the settings are laid out by group, with laev's own labels", %{conn: conn, user: user} do
    connect!(user)
    {:ok, view, _} = live(conn, "/settingstest/settings")
    html = render_async(view)

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
    render_async(view)

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
    html = render_async(view)

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

  test "the browser player's own resolution cap saves, and starts at 1080p", %{
    conn: conn,
    user: user
  } do
    dir = connect!(user)
    {:ok, view, _} = live(conn, "/settingstest/settings")
    html = render_async(view)

    assert html =~ "this page&#39;s player"
    assert has_element?(view, "#w-browser_max_resolution option[selected]", "1080p")

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

  test "a value laev refuses is explained, not saved", %{conn: conn, user: user} do
    dir = connect!(user)
    {:ok, view, _} = live(conn, "/settingstest/settings")
    render_async(view)

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
    render_async(view)

    html =
      view |> element("button[phx-click=edit][phx-value-key=JIMAKU_API_KEY]") |> render_click()

    assert html =~ ~s(type="password")

    secret = "jimaku-secret-key-0123456789"

    view
    |> form("form[phx-submit=replace]", %{"key" => "JIMAKU_API_KEY", "value" => secret})
    |> render_submit()

    html = render_async(view)

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
