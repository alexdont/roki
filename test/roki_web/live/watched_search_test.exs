defmodule RokiWeb.WatchedSearchTest do
  @moduledoc """
  The watched page's search box names whose list it searches.
  """
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  setup %{conn: conn} do
    register = fn name ->
      {:ok, user} =
        PhoenixKit.Users.Auth.register_user(%{
          "email" => "#{name}@example.com",
          "password" => "a-long-enough-password-123",
          "username" => name
        })

      user
    end

    me = register.("watchedme")
    other = register.("watchedmax")
    token = PhoenixKit.Users.Auth.generate_user_session_token(me, [])
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token}), me: me, other: other}
  end

  test "on your own page it says you, on someone else's it names them", %{conn: conn} do
    {:ok, _view, mine} = live(conn, "/watchedme/watched")
    assert mine =~ "Search what you watched…"

    {:ok, _view, theirs} = live(conn, "/watchedmax/watched")
    assert theirs =~ "Search what watchedmax watched…"
    refute theirs =~ "Search what you watched"
  end
end
