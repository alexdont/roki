defmodule Roki.SourceCacheBadTest do
  use ExUnit.Case, async: false

  alias Roki.Watch.SourceCache

  setup do
    dir = Path.join(System.tmp_dir!(), "roki-sc-#{System.unique_integer([:positive])}")
    prior = Application.get_env(:roki, :laev_dir)
    Application.put_env(:roki, :laev_dir, dir)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:roki, :laev_dir, prior),
        else: Application.delete_env(:roki, :laev_dir)

      File.rm_rf(dir)
    end)

    {:ok,
     uuid: "00000000-0000-0000-0000-00000000000#{rem(System.unique_integer([:positive]), 9)}"}
  end

  test "a release that would not start stops being the one to go to, and leaves the list", %{
    uuid: uuid
  } do
    key = {"movie", 1, nil, nil}
    bad = {%{hash: "bad", name: "Bad"}, %{}}
    fine = {%{hash: "fine", name: "Fine"}, %{}}

    SourceCache.put(uuid, key, [bad, fine], [])
    SourceCache.mark_good(uuid, key, "bad")
    assert %{good: "bad"} = SourceCache.get(uuid, key, 12)

    SourceCache.mark_bad(uuid, key, "bad")
    entry = SourceCache.get(uuid, key, 12)
    assert entry.good == nil
    assert Enum.map(entry.playable, fn {s, _} -> s.hash end) == ["fine"]

    # …and the one that works takes its place as the one to go to.
    SourceCache.mark_good(uuid, key, "fine")
    assert %{good: "fine"} = SourceCache.get(uuid, key, 12)
  end

  test "the season pack an episode played from is kept for the next one", %{uuid: uuid} do
    pack = %{hash: "pack", name: "Show.S02.1080p.BluRay.x264-GRP"}
    single = %{hash: "one", name: "Show.S02E03.1080p.WEB.x264-GRP"}
    ep3 = {"tv", 5, 2, 3}
    ep4 = {"tv", 5, 2, 4}

    SourceCache.put(uuid, ep3, [{pack, %{}}, {single, %{}}], [])
    SourceCache.mark_good(uuid, ep3, "pack")
    assert %{hash: "pack"} = SourceCache.pack(uuid, ep4, 12)
    # …for that season only
    assert SourceCache.pack(uuid, {"tv", 5, 3, 1}, 12) == nil

    # Choosing a single episode release instead takes the memory away.
    SourceCache.mark_good(uuid, ep3, "one")
    assert SourceCache.pack(uuid, ep4, 12) == nil

    # A pack that would not play is forgotten with its mark.
    SourceCache.mark_good(uuid, ep3, "pack")
    SourceCache.mark_bad(uuid, ep3, "pack")
    assert SourceCache.pack(uuid, ep4, 12) == nil
  end
end
