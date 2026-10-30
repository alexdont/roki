defmodule RokiWeb.TitlePageTest do
  @moduledoc """
  A show's own page, drawn for a signed-in account with laev connected, from a kept copy of the
  title (so no TMDB is asked). It must come up, not crash and reconnect.
  """
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    dir = Path.join(System.tmp_dir!(), "roki-title-page-#{System.unique_integer([:positive])}")
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
        "email" => "titlepage@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "titlepage"
      })

    udir = Roki.Laev.dir(user.uuid)
    File.mkdir_p!(udir)

    File.write!(
      Path.join(udir, "config"),
      "LAEV_SYNC_URL=https://sync.invalid/laev\nLAEV_SYNC_TOKEN=laev_#{String.duplicate("a", 40)}\n"
    )

    {title, _} = Code.eval_file(Path.expand("../support/fixtures/frieren_title.exs", __DIR__))
    Roki.Titles.put(title)

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token}), user: user}
  end

  test "a show's page comes up with the link button", %{conn: conn} do
    {:ok, view, _} = live(conn, "/title/tv/209867")
    html = render_async(view, 8000)
    assert html =~ "Frieren"
    assert html =~ "Link progress"
    assert Process.alive?(view.pid)
  end
end
