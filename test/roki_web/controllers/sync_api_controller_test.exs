defmodule RokiWeb.SyncApiControllerTest do
  @moduledoc """
  Acceptance checklist for the Laev sync store:

    * GET with an empty store → 404, never invented content
    * PUT then GET returns IDENTICAL bytes + a stable ETag
    * stale If-Match → 412 and no overwrite
    * two tokens never see each other's data
    * malformed token → 401 (open registration: any well-FORMED token
      is a tenant; only the shape is checked)
    * body that doesn't sniff as Laev data → 422 (bot gate)
    * > 5 MB → 413
  """
  use RokiWeb.ConnCase, async: false

  alias Roki.Repo

  @token_a "laev_test_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
  @token_b "laev_test_bbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"

  # Deliberately non-canonical JSON: odd key order, extra whitespace,
  # unicode. jsonb or any parse/re-encode step would reshape this —
  # byte fidelity is the whole contract.
  @doc_bytes ~s({"version": 1,\n  "watchlist": {"a": [1, 2,3]},  "note": "šeleškova — 映画"})

  setup %{conn: conn} do
    # Sandboxed onto the shared dev DB (see config/test.exs) — clear our
    # table inside the rollback transaction so assertions see it empty.
    Repo.delete_all("laev_documents")
    {:ok, conn: conn}
  end

  defp get_doc(conn, token, doc \\ "watchlist") do
    get(conn, "/api/laev/#{token}/#{doc}")
  end

  defp put_doc(conn, token, body, opts \\ []) do
    doc = Keyword.get(opts, :doc, "watchlist")
    ctype = Keyword.get(opts, :content_type, "application/json")

    conn = put_req_header(conn, "content-type", ctype)

    conn =
      case Keyword.get(opts, :if_match) do
        nil -> conn
        etag -> put_req_header(conn, "if-match", etag)
      end

    put(conn, "/api/laev/#{token}/#{doc}", body)
  end

  defp etag_of(conn), do: conn |> get_resp_header("etag") |> List.first()

  defp patch_doc(conn, token, body, opts \\ []) do
    doc = Keyword.get(opts, :doc, "watchlist")

    conn
    |> put_req_header("content-type", "application/json")
    |> patch("/api/laev/#{token}/#{doc}", body)
  end

  defp get_json(conn, token, doc \\ "watchlist") do
    resp = get_doc(conn, token, doc)
    assert resp.status == 200
    Jason.decode!(resp.resp_body)
  end

  defp rec(data, ts, deleted \\ false),
    do: %{"data" => data, "updated_at" => ts, "deleted" => deleted}

  test "malformed tokens → 401; any well-formed token is a tenant", %{conn: conn} do
    assert get_doc(conn, "not-a-token").status == 401
    assert put_doc(conn, "not-a-token", @doc_bytes).status == 401
    # too short / wrong prefix / bad chars
    assert get_doc(conn, "laev_short").status == 401
    assert get_doc(conn, "laev2_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa").status == 401
    assert get_doc(conn, "laev_aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa!!").status == 401
    # a never-seen but well-formed token is simply an empty tenant
    assert get_doc(conn, "laev_neverseen_zzzzzzzzzzzzzzzzzzzzzzzz").status == 404
  end

  test "non-Laev payloads → 422 and nothing stored", %{conn: conn} do
    # invalid JSON (octet-stream dodges Plug.Parsers so our check answers)
    resp =
      put_doc(conn, @token_a, "<html>bot junk</html>", content_type: "application/octet-stream")

    assert resp.status == 422
    # valid JSON, but nothing Laev about it
    resp2 = put_doc(conn, @token_a, ~s({"totally": "unrelated"}))
    assert resp2.status == 422
    # arrays/scalars are not documents
    assert put_doc(conn, @token_a, ~s([1,2,3])).status == 422
    assert get_doc(conn, @token_a).status == 404
  end

  test "GET with nothing stored → 404 and an empty body", %{conn: conn} do
    resp = get_doc(conn, @token_a)
    assert resp.status == 404
    assert resp.resp_body == ""
  end

  test "PUT then GET returns identical bytes and a stable ETag", %{conn: conn} do
    put1 = put_doc(conn, @token_a, @doc_bytes)
    assert put1.status == 200
    etag = etag_of(put1)
    assert etag =~ ~r/^"[0-9a-f]{64}"$/

    got = get_doc(conn, @token_a)
    assert got.status == 200
    assert got.resp_body == @doc_bytes
    assert etag_of(got) == etag

    # Same bytes again → same ETag (content-derived).
    put2 = put_doc(conn, @token_a, @doc_bytes)
    assert etag_of(put2) == etag
  end

  test "bytes survive an octet-stream PUT identically too", %{conn: conn} do
    put_doc(conn, @token_a, @doc_bytes, content_type: "application/octet-stream")
    assert get_doc(conn, @token_a).resp_body == @doc_bytes
  end

  test "stale If-Match → 412 and the stored document is untouched", %{conn: conn} do
    put_doc(conn, @token_a, @doc_bytes)

    stale = put_doc(conn, @token_a, ~s({"version": 9}), if_match: ~s("0000beef"))
    assert stale.status == 412
    assert get_doc(conn, @token_a).resp_body == @doc_bytes
  end

  test "current If-Match → 200 and the write lands", %{conn: conn} do
    etag = etag_of(put_doc(conn, @token_a, @doc_bytes))

    fresh = put_doc(conn, @token_a, ~s({"version": 2}), if_match: etag)
    assert fresh.status == 200
    assert get_doc(conn, @token_a).resp_body == ~s({"version": 2})
  end

  test "If-Match against a missing document is stale → 412", %{conn: conn} do
    assert put_doc(conn, @token_a, @doc_bytes, if_match: ~s("00")).status == 412
    assert get_doc(conn, @token_a).status == 404
  end

  test "weak/unquoted If-Match values are normalized", %{conn: conn} do
    etag = etag_of(put_doc(conn, @token_a, @doc_bytes))
    weak = "W/" <> etag
    assert put_doc(conn, @token_a, ~s({"version": 3}), if_match: weak).status == 200
  end

  test "tokens are fully isolated tenants", %{conn: conn} do
    put_doc(conn, @token_a, @doc_bytes)
    assert get_doc(conn, @token_b).status == 404

    put_doc(conn, @token_b, ~s({"version": 1, "who": "b"}))
    assert get_doc(conn, @token_a).resp_body == @doc_bytes
    assert get_doc(conn, @token_b).resp_body == ~s({"version": 1, "who": "b"})
  end

  test "doc names are independent documents under one token", %{conn: conn} do
    put_doc(conn, @token_a, @doc_bytes, doc: "watchlist")
    put_doc(conn, @token_a, ~s({"positions": {"m": 42}}), doc: "resume")

    assert get_doc(conn, @token_a, "watchlist").resp_body == @doc_bytes
    assert get_doc(conn, @token_a, "resume").resp_body == ~s({"positions": {"m": 42}})
  end

  describe "PATCH merge" do
    @full ~s({"version": 1, "watchlist": {"tv:1": {"data": {"t": "Dune"}, "updated_at": 100, "deleted": false}, "tv:2": {"data": {"t": "Alien"}, "updated_at": 100, "deleted": false}}, "resume": {"tv:1": {"data": {"pos": 10}, "updated_at": 100, "deleted": false}}})

    test "merges one record and leaves everything else intact", %{conn: conn} do
      put_doc(conn, @token_a, @full)

      p =
        Jason.encode!(%{"version" => 1, "watchlist" => %{"tv:2" => rec(%{"t" => "Aliens"}, 200)}})

      resp = patch_doc(conn, @token_a, p)
      assert resp.status == 200

      doc = get_json(conn, @token_a)
      assert doc["watchlist"]["tv:2"]["data"] == %{"t" => "Aliens"}
      assert doc["watchlist"]["tv:1"]["data"] == %{"t" => "Dune"}
      assert doc["resume"]["tv:1"]["data"] == %{"pos" => 10}
      # merged ETag matches the next GET's
      assert etag_of(resp) == etag_of(get_doc(conn, @token_a))
    end

    test "a lower updated_at does not overwrite a newer stored record", %{conn: conn} do
      put_doc(conn, @token_a, @full)

      p = Jason.encode!(%{"version" => 1, "watchlist" => %{"tv:1" => rec(%{"t" => "stale"}, 50)}})
      assert patch_doc(conn, @token_a, p).status == 200
      assert get_json(conn, @token_a)["watchlist"]["tv:1"]["data"] == %{"t" => "Dune"}
    end

    test "incoming wins updated_at ties", %{conn: conn} do
      put_doc(conn, @token_a, @full)

      p =
        Jason.encode!(%{"version" => 1, "watchlist" => %{"tv:1" => rec(%{"t" => "Dune 2"}, 100)}})

      assert patch_doc(conn, @token_a, p).status == 200
      assert get_json(conn, @token_a)["watchlist"]["tv:1"]["data"] == %{"t" => "Dune 2"}
    end

    test "tombstones are stored as-is and persist", %{conn: conn} do
      put_doc(conn, @token_a, @full)

      p = Jason.encode!(%{"version" => 1, "watchlist" => %{"tv:1" => rec(%{}, 200, true)}})
      assert patch_doc(conn, @token_a, p).status == 200

      stored = get_json(conn, @token_a)["watchlist"]["tv:1"]
      assert stored["deleted"] == true
      assert stored["updated_at"] == 200

      # an older un-delete loses to the tombstone
      p2 =
        Jason.encode!(%{"version" => 1, "watchlist" => %{"tv:1" => rec(%{"t" => "Dune"}, 150)}})

      assert patch_doc(conn, @token_a, p2).status == 200
      assert get_json(conn, @token_a)["watchlist"]["tv:1"]["deleted"] == true
    end

    test "PATCH to a never-seen token auto-provisions", %{conn: conn} do
      t = "laev_fresh_cccccccccccccccccccccccccccccc"
      p = Jason.encode!(%{"version" => 1, "positions" => %{"m:9" => rec(%{"s" => 33}, 100)}})

      resp = patch_doc(conn, t, p)
      assert resp.status == 200
      assert get_json(conn, t)["positions"]["m:9"]["data"] == %{"s" => 33}
    end

    test "non-Laev patch body → 422; malformed collection → 422", %{conn: conn} do
      assert patch_doc(conn, @token_a, ~s({"nothing": "laev"})).status == 422
      assert patch_doc(conn, @token_a, ~s({"version": 1, "watchlist": [1, 2]})).status == 422
      assert get_doc(conn, @token_a).status == 404
    end
  end

  test "body over 5 MB → 413 and nothing stored", %{conn: conn} do
    big = :binary.copy("x", 5 * 1024 * 1024 + 1)

    resp = put_doc(conn, @token_a, big, content_type: "application/octet-stream")
    assert resp.status == 413
    assert get_doc(conn, @token_a).status == 404
  end

  test "the key never reaches the request log", %{conn: conn} do
    previous = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous) end)

    log =
      ExUnit.CaptureLog.capture_log([level: :debug], fn ->
        get(conn, "/api/laev/#{@token_a}/watchlist")
      end)

    refute log =~ @token_a
    assert log =~ "/api/laev/[key]/watchlist"
  end
end
