defmodule Roki.BusyTest do
  use ExUnit.Case, async: true

  test "the busy message names who is converting what" do
    msg =
      Roki.Watch.Resolver.failure(
        {:busy, [%{username: "alex", title: "Lupin S1E4", release: "Lupin.S01E04.2160p.HEVC"}]}
      )

    assert msg =~ "alex: Lupin S1E4 (Lupin.S01E04.2160p.HEVC)"
  end

  test "an empty list falls back to the plain message" do
    assert Roki.Watch.Resolver.failure({:busy, []}) =~ "re-encoding other videos"
  end
end
