defmodule RokiWeb.StreamControllerTest do
  use RokiWeb.ConnCase

  @id "0123456789abcdef"

  setup %{conn: conn} do
    dir = Laev.Remux.dir(@id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "s_0.m3u8"), "#EXTM3U\n")

    File.write!(
      Path.join(dir, "master.m3u8"),
      "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1\ns_0.m3u8\n"
    )

    File.write!(Path.join(dir, "ext-fr.vtt"), "WEBVTT\n")
    File.write!(Path.join(dir, "seg00000.ts"), "ts")
    on_exit(fn -> File.rm_rf(dir) end)

    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "stream-test@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "streamtest"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])

    {:ok,
     conn: Plug.Test.init_test_session(conn, %{user_token: token}),
     visitor: build_conn(),
     user: user}
  end

  test "a visitor gets nothing", %{visitor: conn} do
    assert conn |> get("/stream/#{@id}/seg00000.ts") |> response(401)
  end

  test "ids and names are checked before the disk is touched", %{conn: conn} do
    assert conn |> get("/stream/not-an-id/seg00000.ts") |> response(400)
    assert conn |> get("/stream/#{@id}/passwd") |> response(400)
    assert conn |> get("/stream/#{@id}/..%2F..%2Fetc%2Fpasswd") |> response(400)
    assert conn |> get("/stream/#{@id}/seg0000.ts") |> response(400)
  end

  test "a file that is not written yet is a 404 the player retries", %{conn: conn} do
    assert conn |> get("/stream/#{@id}/seg00009.ts") |> response(404)
  end

  test "segments, subtitles and playlists are served with the right types", %{conn: conn} do
    seg = get(conn, "/stream/#{@id}/seg00000.ts")
    assert response(seg, 200) == "ts"
    assert get_resp_header(seg, "content-type") |> hd() =~ "video/mp2t"
    assert get_resp_header(seg, "cache-control") == ["private, max-age=3600"]

    vtt = get(conn, "/stream/#{@id}/ext-fr.vtt")
    assert response(vtt, 200) =~ "WEBVTT"
    assert get_resp_header(vtt, "content-type") |> hd() =~ "text/vtt"

    pl = get(conn, "/stream/#{@id}/s_0.m3u8")
    assert response(pl, 200) =~ "EXTM3U"
    assert get_resp_header(pl, "cache-control") == ["no-store"]
  end

  test "playlist.m3u8 is whichever playlist the remux started with", %{conn: conn} do
    assert conn |> get("/stream/#{@id}/playlist.m3u8") |> response(200) =~ "EXTM3U"
  end

  # An AirPlay receiver fetches the playlist and everything under it with no cookie.
  test "a signed address serves a visitor the same files, for its own remux, for a day",
       %{visitor: conn, user: user} do
    assert conn |> get(RokiWeb.StreamToken.path(user.uuid, @id)) |> response(200) =~ "EXTM3U"

    seg = get(conn, RokiWeb.StreamToken.path(user.uuid, @id, "seg00000.ts"))
    assert response(seg, 200) == "ts"
    assert get_resp_header(seg, "content-type") |> hd() =~ "video/mp2t"

    # The names are checked as ever.
    assert conn |> get(RokiWeb.StreamToken.path(user.uuid, @id, "passwd")) |> response(400)

    # A token for one remux opens no other.
    other = RokiWeb.StreamToken.sign(user.uuid, String.duplicate("f", 16))
    assert conn |> get("/stream/t/#{other}/#{@id}/seg00000.ts") |> response(401)

    # Nor does a mangled one, or one from yesterday.
    assert conn |> get("/stream/t/not-a-token/#{@id}/seg00000.ts") |> response(401)

    old =
      Phoenix.Token.sign(RokiWeb.Endpoint, "stream", %{"u" => user.uuid, "id" => @id},
        signed_at: System.system_time(:second) - 25 * 3600
      )

    assert conn |> get("/stream/t/#{old}/#{@id}/seg00000.ts") |> response(401)
  end
end
