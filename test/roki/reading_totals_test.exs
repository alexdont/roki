defmodule Roki.ReadingTotalsTest do
  @moduledoc """
  The reading half of the home page's strip: how long, across how many series, and how many
  chapters — which is the chapter each series is up to, not the number the reader has logged.
  """
  use Roki.DataCase

  alias Roki.Manga.Library

  setup do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "totals@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "totalsuser"
      })

    %{user: user}
  end

  # A series as the reader has it: timed on-site, hand-entered off-site, and where it is up to.
  defp series!(user, slug, opts) do
    {:ok, _} =
      Library.save_manga(user.uuid, %{
        source: "mangadex",
        slug: slug,
        title: slug,
        cover_url: "https://example.invalid/#{slug}.jpg"
      })

    Roki.Repo.query!(
      "update saved_manga set reading_seconds = $1, reading_seconds_adjusted = $2, reading_seconds_offsite = $3, last_chapter = $4 where user_id = $5::text::uuid and slug = $6",
      [
        Keyword.get(opts, :raw, 0),
        opts[:adjusted],
        opts[:off],
        opts[:chapter],
        user.uuid,
        slug
      ]
    )
  end

  test "an account that has read nothing is all zeros", %{user: user} do
    assert Library.reading_totals(user.uuid) == %{seconds: 0, series: 0, chapters: 0}
  end

  test "adds on-site time and time entered by hand, and the chapters each series is up to", %{
    user: user
  } do
    series!(user, "overgeared", raw: 8412, adjusted: 8340, off: 95_460, chapter: "331")
    series!(user, "berserk", raw: 3600, chapter: "12.5")

    # The adjusted figure replaces the raw one, as it does everywhere else: 8340, not 8412.
    assert Library.reading_totals(user.uuid) ==
             %{seconds: 8340 + 95_460 + 3600, series: 2, chapters: 331 + 12}
  end

  test "a series with no reading time on it is not counted, whatever chapter it is at", %{
    user: user
  } do
    series!(user, "read", raw: 600, chapter: "10")
    series!(user, "only-saved", raw: 0, chapter: "5")

    assert %{series: 1, chapters: 10} = Library.reading_totals(user.uuid)
  end

  test "time entered by hand alone is reading", %{user: user} do
    series!(user, "elsewhere", raw: 0, off: 7200, chapter: "40")

    assert Library.reading_totals(user.uuid) == %{seconds: 7200, series: 1, chapters: 40}
  end

  test "a label that is not a number counts as no chapters, not as an error", %{user: user} do
    series!(user, "oneshot", raw: 300, chapter: "Oneshot")
    series!(user, "extra", raw: 300, chapter: "Extra 3")
    series!(user, "none", raw: 300, chapter: nil)
    series!(user, "real", raw: 300, chapter: "7")

    assert %{series: 4, chapters: 7} = Library.reading_totals(user.uuid)
  end

  test "is this account's own", %{user: user} do
    {:ok, other} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "totals2@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "totalsother"
      })

    series!(user, "mine", raw: 600, chapter: "10")
    series!(other, "theirs", raw: 9000, chapter: "900")

    assert Library.reading_totals(user.uuid) == %{seconds: 600, series: 1, chapters: 10}
  end
end
