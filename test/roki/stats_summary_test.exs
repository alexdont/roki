defmodule Roki.StatsSummaryTest do
  @moduledoc """
  The strip's headline totals are handed back at once however old they are, and rebuilt behind
  the page that asked rather than in front of it.
  """
  use ExUnit.Case, async: false

  alias Roki.{Stats, TTLCache}

  @value %{totals: %{seconds: 3600, films: 1, episodes: 2}, films: %{603 => 7200}}

  setup do
    uuid = Ecto.UUID.generate()

    on_exit(fn ->
      TTLCache.delete({:stats_summary, uuid})
      TTLCache.delete({:stats_refreshing, uuid})
    end)

    %{uuid: uuid}
  end

  defp keep(uuid, age_s) do
    TTLCache.put(
      {:stats_summary, uuid},
      3600,
      {:ok, %{at: System.os_time(:second) - age_s, value: @value}}
    )
  end

  test "a recent answer is returned and nothing is rebuilt", %{uuid: uuid} do
    keep(uuid, 60)

    assert Stats.summary(uuid) == {:ok, @value}
    refute TTLCache.cached?({:stats_refreshing, uuid})
  end

  test "an old answer is still returned at once, and a rebuild is started behind it", %{
    uuid: uuid
  } do
    keep(uuid, 3 * 3600)

    assert Stats.summary(uuid) == {:ok, @value}
    assert TTLCache.cached?({:stats_refreshing, uuid})
  end

  test "asking again does not start a second rebuild", %{uuid: uuid} do
    keep(uuid, 3 * 3600)
    Stats.summary(uuid)

    # The guard is the only thing that stops a page opened ten times from measuring ten times.
    {:ok, started} = TTLCache.peek({:stats_refreshing, uuid})
    Stats.summary(uuid)
    assert TTLCache.peek({:stats_refreshing, uuid}) == {:ok, started}
  end

  test "with nothing kept and nothing to measure, it says so and keeps nothing", %{uuid: uuid} do
    assert {:error, _} = Stats.summary(uuid)
    assert TTLCache.peek({:stats_summary, uuid}) == :miss
  end

  test "forgetting an account drops the answer, so a new connection is measured afresh", %{
    uuid: uuid
  } do
    keep(uuid, 10)
    Stats.forget(uuid)

    assert TTLCache.peek({:stats_summary, uuid}) == :miss
  end
end
