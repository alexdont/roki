defmodule RokiWeb.PeekControllerTest do
  use RokiWeb.ConnCase

  test "only signed-in users can look titles up", %{conn: conn} do
    assert conn |> get("/peek/movie/10331") |> response(401)
  end

  test "an unknown kind or a bad id is a 404, not a crash", %{conn: conn} do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "peek-test@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "peektest"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    conn = Plug.Test.init_test_session(conn, %{user_token: token})

    assert conn |> get("/peek/book/1") |> response(404)
    assert conn |> get("/peek/movie/abc") |> response(404)
  end
end
