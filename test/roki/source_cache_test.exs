defmodule Roki.Watch.SourceCacheTest do
  use ExUnit.Case, async: false

  alias Roki.Watch.SourceCache

  setup do
    uuid = Ecto.UUID.generate()
    on_exit(fn -> File.rm_rf(Path.join(Roki.Laev.dir(uuid), "roki-sources")) end)
    {:ok, uuid: uuid}
  end

  test "a study session keeps its own list per language pair, and the account's stays apart", %{uuid: uuid} do
    key = {"tv", 1, 1, 2}
    SourceCache.put(uuid, key, [{%{hash: "plain"}, %{}}], [])

    Roki.Study.bind(%{lang: "fr", subs_lang: "fr"})
    assert SourceCache.get(uuid, key, 12) == nil
    SourceCache.put(uuid, key, [{%{hash: "study-fr"}, %{}}], [])
    assert %{playable: [{%{hash: "study-fr"}, _}]} = SourceCache.get(uuid, key, 12)

    Roki.Study.bind(%{lang: "fr", subs_lang: "en"})
    assert SourceCache.get(uuid, key, 12) == nil

    Roki.Study.bind(%{})
    assert %{playable: [{%{hash: "plain"}, _}]} = SourceCache.get(uuid, key, 12)
    # only the account's own list counts as "cached" on the title page
    assert SourceCache.keys(uuid, 12) == MapSet.new([key])
  end

  test "a study session uses the cache like any other (it was off, so every reload searched again)" do
    Roki.Study.bind(%{lang: "fr", subs_lang: "fr"})
    assert SourceCache.hours(%{}) == 12
    Roki.Study.bind(%{})
  end
end
