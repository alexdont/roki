defmodule Roki.Manga.ArcDatesTest do
  @moduledoc """
  Dating the parts of a series read before this site saw them: the share an arc
  takes of the hours that have no day, and the row that records it.
  """
  use Roki.DataCase

  alias Roki.Manga.ArcDates
  alias Roki.Manga.Library
  alias Roki.Manga.Library.MangaStoryData

  setup do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "arcs@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "arcsuser"
      })

    {:ok, _} =
      Library.save_manga(user.uuid, %{
        source: "mangadex",
        slug: "berserk",
        title: "Berserk",
        cover_url: "https://example.invalid/b.jpg"
      })

    {:ok, bin} = Ecto.UUID.dump(user.uuid)

    Roki.Repo.query!(
      "update saved_manga set reading_seconds = 1800, reading_seconds_offsite = 7200, last_chapter = '20' where user_id = $1",
      [bin]
    )

    story =
      Roki.Repo.insert!(%MangaStoryData{
        source: "mangadex",
        slug: "berserk",
        arcs: [
          %{"id" => 1, "position" => 1, "title" => "Golden Age", "from" => 1, "to" => 10},
          %{"id" => 2, "position" => 2, "title" => "Conviction", "from" => 11, "to" => 30}
        ],
        volumes: [],
        units: [],
        synced_at: DateTime.utc_now() |> DateTime.truncate(:second)
      })

    %{user: user, story: story, row: hd(Library.list_reading_stats(user.uuid))}
  end

  test "an arc's share is by the chapters of it that were read", ctx do
    [first, second] = ArcDates.datable(ctx.user.uuid, ctx.row, ctx.story)

    # Twenty chapters read: all ten of the first arc, half of the second, so the
    # two hours of off-site time divide in half.
    assert first.chapters == 10
    assert second.chapters == 10
    assert first.seconds == 3600
    assert second.seconds == 3600
  end

  test "a date is set, read back, replaced, and cleared", ctx do
    assert :ok = ArcDates.set(ctx.user.uuid, "mangadex", "berserk", "arc", 1, ~D[2019-06-01])
    assert ArcDates.get(ctx.user.uuid, "mangadex", "berserk") == %{{"arc", 1} => ~D[2019-06-01]}

    assert :ok = ArcDates.set(ctx.user.uuid, "mangadex", "berserk", "arc", 1, ~D[2020-01-02])
    assert ArcDates.get(ctx.user.uuid, "mangadex", "berserk") == %{{"arc", 1} => ~D[2020-01-02]}

    assert :ok = ArcDates.set(ctx.user.uuid, "mangadex", "berserk", "arc", 1, nil)
    assert ArcDates.get(ctx.user.uuid, "mangadex", "berserk") == %{}
  end

  test "the dated arcs of a series never carry more hours than it has", ctx do
    rows = Library.list_reading_stats(ctx.user.uuid)
    ArcDates.set(ctx.user.uuid, "mangadex", "berserk", "arc", 1, ~D[2019-06-01])
    ArcDates.set(ctx.user.uuid, "mangadex", "berserk", "arc", 2, ~D[2019-07-01])

    [one, two] = ArcDates.parts(ctx.user.uuid, rows)[{"mangadex", "berserk"}]

    assert one.title == "Berserk · Golden Age"
    assert two.title == "Berserk · Conviction"
    assert one.seconds + two.seconds == 7200
  end
end
