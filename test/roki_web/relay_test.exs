defmodule RokiWeb.RelayTest do
  use RokiWeb.ConnCase, async: false

  alias RokiWeb.Relay

  test "a TorBox link is read directly, a Real-Debrid one through a signed relay address" do
    tb = "https://store-011.wnam.tb-cdn.io/dl/abc/file.mkv"
    rd = "https://132-4.download.real-debrid.com/d/X/file.mkv"
    assert Relay.direct?(tb)
    refute Relay.direct?(rd)
    assert Relay.url_for(tb) == tb
    assert "/relay?" <> query = Relay.url_for(rd)
    %{"u" => ^rd, "t" => token} = URI.decode_query(query)
    assert Relay.verify(token, rd) == :ok
    assert Relay.verify(token, rd <> "x") == {:error, :bad_token}
    refute Relay.allowed?("https://example.com/file.mkv")
    refute Relay.allowed?("http://real-debrid.com/plain")
  end

  test "the relay answers nobody who is not signed in, no host it does not know, and no unsigned link", %{conn: conn} do
    rd = "https://132-4.download.real-debrid.com/d/X/file.mkv"
    assert get(conn, "/relay", u: rd, t: Relay.sign(rd)).status == 403

    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{"email" => "relay@example.com", "password" => "a-long-enough-password-123", "username" => "relayer"})

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    conn = Plug.Test.init_test_session(build_conn(), %{user_token: token})
    assert get(conn, "/relay", u: "https://example.com/x.mkv", t: Relay.sign("https://example.com/x.mkv")).status == 400
    assert get(conn, "/relay", u: rd, t: "nope").status == 403
    assert get(conn, "/relay").status == 400
  end
end
