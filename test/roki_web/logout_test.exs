defmodule RokiWeb.LogoutTest do
  @moduledoc """
  Logging out lands on the home page, not on a profile page for a user called "phoenix_kit".
  """
  use RokiWeb.ConnCase

  setup %{conn: conn} do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "logout@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "logoutuser"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token})}
  end

  test "PhoenixKit's own address leads home, not to a profile", %{conn: conn} do
    conn = get(conn, "/phoenix_kit")
    assert redirected_to(conn) == "/"
    conn = get(build_conn(), "/phoenix_kit/")
    assert redirected_to(conn) == "/"
  end

  test "logging out ends on the home page, and says so", %{conn: conn} do
    conn = delete(conn, "/phoenix_kit/users/log-out")
    first = redirected_to(conn)

    # wherever PhoenixKit sends a visitor, following it reaches the home page
    conn = get(recycle(conn), first)
    conn = if conn.status in 300..308, do: get(recycle(conn), redirected_to(conn)), else: conn

    assert conn.request_path == "/"
    refute conn.resp_body =~ "There is no one called"
    assert Phoenix.Flash.get(conn.assigns.flash, :info) =~ "Logged out"
  end
end
