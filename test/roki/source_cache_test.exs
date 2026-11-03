defmodule Roki.Watch.SourceCacheTest do
  use ExUnit.Case, async: false

  alias Roki.Watch.SourceCache

  @uuid "01a163a7-a312-7691-8440-db7feaca900f"
  @key {"movie", 1_273_221, nil, nil}

  setup do
    dir = Path.join(System.tmp_dir!(), "roki-cache-test-#{System.unique_integer([:positive])}")
    prior = Application.get_env(:roki, :laev_dir)
    Application.put_env(:roki, :laev_dir, dir)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:roki, :laev_dir, prior),
        else: Application.delete_env(:roki, :laev_dir)

      File.rm_rf(dir)
    end)

    :ok
  end

  defp pair(hash), do: {%{name: "x", hash: hash}, %{url: "https://example.invalid/#{hash}"}}

  test "what was found comes back until it is older than the setting" do
    SourceCache.put(@uuid, @key, [pair("a"), pair("b")], [%{name: "unchecked"}])

    assert %{playable: [{%{hash: "a"}, _}, _], rest: [%{name: "unchecked"}], good: nil} =
             SourceCache.get(@uuid, @key, 12)

    assert SourceCache.get(@uuid, {"movie", 5, nil, nil}, 12) == nil
    assert SourceCache.get(@uuid, @key, 0) == nil
  end

  test "an entry older than the window is not served and is deleted" do
    SourceCache.put(@uuid, @key, [pair("a")], [])
    path = Path.join([Roki.Laev.dir(@uuid), "roki-sources", "movie-1273221-0-0.etf"])
    old = %{at: System.os_time(:second) - 13 * 3600, playable: [pair("a")], rest: [], good: nil}
    File.write!(path, :erlang.term_to_binary(old))

    assert SourceCache.get(@uuid, @key, 12) == nil
    refute File.exists?(path)
  end

  test "the release that started is remembered, and survives a refresh of the list" do
    SourceCache.put(@uuid, @key, [pair("a"), pair("b")], [])
    SourceCache.mark_good(@uuid, @key, "b")
    assert SourceCache.get(@uuid, @key, 12).good == "b"
  end

  test "a later search adds to what was found, it does not replace it" do
    # The sources page found a, b, c; a background search with a lower ceiling found only c, d.
    SourceCache.put(@uuid, @key, [pair("a"), pair("b"), pair("c")], [%{hash: "x"}, %{hash: "d"}])
    SourceCache.mark_good(@uuid, @key, "b")
    SourceCache.put(@uuid, @key, [pair("c"), pair("d")], [%{hash: "y"}])

    entry = SourceCache.get(@uuid, @key, 12)
    assert entry.playable |> Enum.map(fn {s, _} -> s.hash end) |> Enum.sort() == ~w(a b c d)
    # Still to check: both lists, less what is now known to play (d).
    assert entry.rest |> Enum.map(& &1.hash) |> Enum.sort() == ~w(x y)
    assert entry.good == "b"
  end

  test "a release taken out for not starting stays out of a later save that lacks it" do
    SourceCache.put(@uuid, @key, [pair("a"), pair("b")], [])
    SourceCache.mark_bad(@uuid, @key, "a")
    SourceCache.put(@uuid, @key, [pair("b")], [])
    assert SourceCache.get(@uuid, @key, 12).playable |> Enum.map(fn {s, _} -> s.hash end) == ["b"]
  end

  test "episodes are separate entries, and the keys come back as a set" do
    SourceCache.put(@uuid, {"tv", 1396, 1, 1}, [pair("a")], [])
    SourceCache.put(@uuid, {"tv", 1396, 1, 2}, [pair("b")], [])
    SourceCache.put(@uuid, @key, [pair("c")], [])

    keys = SourceCache.keys(@uuid, 12)
    assert MapSet.member?(keys, {"tv", 1396, 1, 1})
    assert MapSet.member?(keys, {"tv", 1396, 1, 2})
    assert MapSet.member?(keys, @key)
    assert MapSet.size(keys) == 3
    assert SourceCache.keys(@uuid, 0) == MapSet.new()
  end

  test "delete forgets one entry" do
    SourceCache.put(@uuid, @key, [pair("a")], [])
    SourceCache.delete(@uuid, @key)
    assert SourceCache.get(@uuid, @key, 12) == nil
  end

  test "the setting: 12 hours by default, off, or a chosen number" do
    assert SourceCache.hours(%{}) == 12
    assert SourceCache.hours(%{"sources_cache" => "off"}) == 0
    assert SourceCache.hours(%{"sources_cache" => "6"}) == 6
  end

  test "a study session keeps its own list per language pair, and the account's stays apart" do
    key = {"tv", 1, 1, 2}
    SourceCache.put(@uuid, key, [pair("plain")], [])

    Roki.Study.bind(%{lang: "fr", subs_lang: "fr"})
    assert SourceCache.get(@uuid, key, 12) == nil
    SourceCache.put(@uuid, key, [pair("study-fr")], [])
    assert %{playable: [{%{hash: "study-fr"}, _}]} = SourceCache.get(@uuid, key, 12)

    Roki.Study.bind(%{lang: "fr", subs_lang: "en"})
    assert SourceCache.get(@uuid, key, 12) == nil

    Roki.Study.bind(%{})
    assert %{playable: [{%{hash: "plain"}, _}]} = SourceCache.get(@uuid, key, 12)
    # only the account's own list counts as "cached" on the title page
    assert SourceCache.keys(@uuid, 12) == MapSet.new([key])
  end

  test "a study session uses the cache like any other (it was off, so every reload searched again)" do
    Roki.Study.bind(%{lang: "fr", subs_lang: "fr"})
    assert SourceCache.hours(%{}) == 12
    Roki.Study.bind(%{})
  end
end
