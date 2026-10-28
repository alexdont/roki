defmodule RokiWeb.StatsLiveTest do
  use RokiWeb.ConnCase

  import Phoenix.LiveViewTest

  alias Roki.Manga.Library

  setup %{conn: conn} do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "stats-test@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "statstest"
      })

    token = PhoenixKit.Users.Auth.generate_user_session_token(user, [])
    {:ok, conn: Plug.Test.init_test_session(conn, %{user_token: token}), user: user}
  end

  # `reading_seconds` is the reader's own tally and the changeset does not cast it,
  # so the row goes in first and the time is set the way the reader sets it.
  defp read!(user, title, seconds) do
    slug = String.downcase(String.replace(title, " ", "-"))

    {:ok, _} =
      Library.save_manga(user.uuid, %{
        source: "mangadex",
        slug: slug,
        title: title,
        cover_url: "https://example.invalid/#{slug}.jpg"
      })

    Roki.Repo.query!(
      "update saved_manga set reading_seconds = $1 where user_id = $2::text::uuid and slug = $3",
      [seconds, user.uuid, slug]
    )
  end

  test "an account that has read nothing gets no reading section", %{conn: conn} do
    {:ok, _view, html} = live(conn, "/statstest/stats")

    refute html =~ ~s(id="reading")
    refute html =~ "Total Reading Time"
  end

  test "reading time is on this page, whether or not laev is connected", %{
    conn: conn,
    user: user
  } do
    read!(user, "Solo Leveling", 7200)
    read!(user, "Berserk", 3600)

    {:ok, _view, html} = live(conn, "/statstest/stats")

    # The watching half is still measuring (and this account has no laev at all);
    # reading is drawn from the manga tables and is there either way.
    assert html =~ ~s(id="reading")
    assert html =~ "Total Reading Time"
    assert html =~ "3h"
    assert html =~ "Solo Leveling"
    assert html =~ "Berserk"
  end

  test "the reader's old stats address leads here", %{conn: conn} do
    conn = get(conn, "/manga/stats")
    assert redirected_to(conn) == "/statstest/stats#reading"
  end
end
