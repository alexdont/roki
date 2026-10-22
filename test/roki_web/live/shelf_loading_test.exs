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
    {:ok, _view, html} = live(conn, "/shelftest/home")
    assert html =~ "Connect laev"
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

    {:ok, _view, html} = live(conn, "/shelftest/home")

    # The real header and strip are there from the first paint…
    assert html =~ "Your shelf"
    assert html =~ "all stats"
    # …with a placeholder grid standing where the Watchlist will be…
    assert html =~ "aria-busy"
    assert length(Regex.scan(~r/skeleton aspect-\[2\/3\]/, html)) == 16
    # …and nothing to click until there is a shelf to act on.
    assert Regex.scan(~r/<button[^>]*disabled[^>]*>/, html) != []
    refute html =~ "Connect laev"
  end
end
