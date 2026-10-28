defmodule Roki.CacheSweeperTest do
  use ExUnit.Case, async: true

  alias Roki.CacheSweeper

  setup do
    base = Path.join(System.tmp_dir!(), "roki-sweeper-test-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf(base) end)
    %{base: base}
  end

  defp conversion(base, id, age_s) do
    dir = Path.join(base, id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "media.mp4"), String.duplicate("x", 1000))
    File.write!(Path.join(dir, "index.m3u8"), "")
    stamp = System.os_time(:second) - age_s
    File.touch!(Path.join(dir, "index.m3u8"), stamp)
    File.touch!(dir, stamp)
    dir
  end

  test "a conversion nobody fetched for the TTL goes; a fresh one and a running one stay", %{
    base: base
  } do
    old = conversion(base, "0000000000000001", 7 * 3600)
    fresh = conversion(base, "0000000000000002", 3600)
    running = conversion(base, "0000000000000003", 9 * 3600)

    assert {1, 1000} = CacheSweeper.sweep(base, 6 * 3600, ["0000000000000003"])

    refute File.exists?(old)
    assert File.exists?(fresh)
    assert File.exists?(running)
  end

  test "the last fetch, not the making, is what counts", %{base: base} do
    dir = conversion(base, "0000000000000004", 9 * 3600)
    # A request a minute ago bumps the marker, as laev's touch does.
    File.touch!(Path.join(dir, "index.m3u8"), System.os_time(:second) - 60)

    assert {0, 0} = CacheSweeper.sweep(base, 6 * 3600, [])
    assert File.exists?(dir)
  end
end
