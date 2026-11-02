defmodule Roki.Manga.TrialTest do
  @moduledoc """
  A series can be tried in the reader's other modes before it is saved: the choice is held, shown
  back by the store, and kept when the series is saved — and only then is it on the account.
  """
  use Roki.DataCase, async: true

  alias Roki.Manga.{Library, Trial}
  alias Roki.Manga.MangaReader.Store

  @uuid "0199f7a1-0000-7000-8000-0000000000a1"
  @series ["kotatsu", "TESTSRC~abc"]

  defp user, do: %{uuid: @uuid, user_timezone: "Etc/UTC"}

  test "a choice for a series that is not saved is held and read back" do
    assert Store.reader_state(user(), @series) == nil

    assert :ok = Store.put_setting(user(), @series, :reading_mode, "scroll", "desktop")
    assert :ok = Store.put_setting(user(), @series, :reading_direction, "ltr", nil)

    state = Store.reader_state(user(), @series)
    assert state.reading_mode_desktop == "scroll"
    assert state.reading_direction == "ltr"
    # Nothing on the account: there is no row for it.
    refute Library.saved?(@uuid, "kotatsu", "TESTSRC~abc")
  end

  test "a value the reader does not take is refused" do
    assert {:error, :invalid} = Trial.put(@uuid, "kotatsu", "x", :reading_mode, "sideways", nil)
    assert Trial.get(@uuid, "kotatsu", "x") == nil
  end

  test "saving the series keeps what was tried, and forgets the trial" do
    Store.put_setting(user(), @series, :reading_mode, "scroll", "desktop")
    Store.put_setting(user(), @series, :reading_mode, "double_page", "mobile")

    {:ok, _} =
      Library.save_manga(@uuid, %{
        source: "kotatsu",
        slug: "TESTSRC~abc",
        title: "Tried First",
        cover_url: "http://example.test/c.jpg",
        reading_mode: "paged",
        total_chapters: 3
      })

    saved = Library.get_saved_manga(@uuid, "kotatsu", "TESTSRC~abc")
    assert saved.reading_mode_desktop == "scroll"
    assert saved.reading_mode_mobile == "double_page"
    assert saved.reading_mode == "paged"
    assert Trial.get(@uuid, "kotatsu", "TESTSRC~abc") == nil
  end

  test "once saved, a setting goes to the row, not to the trial" do
    {:ok, _} =
      Library.save_manga(@uuid, %{
        source: "kotatsu",
        slug: "SAVED~1",
        title: "Saved",
        cover_url: "http://example.test/c.jpg",
        reading_mode: "paged",
        total_chapters: 1
      })

    Store.put_setting(user(), ["kotatsu", "SAVED~1"], :reading_mode, "scroll", "desktop")

    assert Library.get_saved_manga(@uuid, "kotatsu", "SAVED~1").reading_mode_desktop == "scroll"
    assert Trial.get(@uuid, "kotatsu", "SAVED~1") == nil
  end
end
