defmodule Roki.SourceCacheBadTest do
  use ExUnit.Case, async: true

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
end
