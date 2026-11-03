defmodule RokiWeb.HistoryLiveTest do
  @moduledoc """
  The history page: a day holds what was done that day, read or watched.
  """
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "history@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "histuser"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, bin} = Ecto.UUID.dump(user.uuid)
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token}), user: user, bin: bin}
  end

  test "a film finished today is on today's calendar", %{conn: conn, bin: bin} do
    Roki.Repo.query!(
      "insert into roki_watched (user_uuid, type, id, tmdb_type, tmdb_id, title, anime, at, dated) " <>
        "values ($1, 'movie', 603, 'movie', 603, 'The Matrix', false, now(), true)",
      [bin]
    )

    {:ok, view, _} = live(conn, "/u/histuser/history")
    html = render(view)

    assert html =~ "History"
    assert html =~ "The Matrix"
  end

  test "someone else's history is not yours", %{conn: conn} do
    assert {:error, {:live_redirect, %{to: "/"}}} = live(conn, "/u/someone-else/history")
  end
end
