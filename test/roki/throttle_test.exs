defmodule Roki.ThrottleTest do
  use ExUnit.Case, async: true

  alias Roki.{RateLimit, TTLCache}

  describe "RateLimit.check/4" do
    test "allows up to the limit, then says how long to wait" do
      client = {:ip, "rl-#{System.unique_integer()}"}

      assert RateLimit.check(:t, client, 3, 60_000) == :ok
      assert RateLimit.check(:t, client, 3, 60_000) == :ok
      assert RateLimit.check(:t, client, 3, 60_000) == :ok
      assert {:error, {:rate_limited, secs}} = RateLimit.check(:t, client, 3, 60_000)
      assert secs >= 1 and secs <= 60
    end

    test "clients and buckets are independent" do
      a = {:ip, "a-#{System.unique_integer()}"}
      b = {:ip, "b-#{System.unique_integer()}"}
      assert RateLimit.check(:x, a, 1, 60_000) == :ok
      assert {:error, _} = RateLimit.check(:x, a, 1, 60_000)
      assert RateLimit.check(:x, b, 1, 60_000) == :ok
      assert RateLimit.check(:y, a, 1, 60_000) == :ok
    end
  end

  describe "TTLCache.fetch/3" do
    test "computes once, then serves from memory" do
      key = {:test, System.unique_integer()}
      {:ok, calls} = Agent.start_link(fn -> 0 end)
      fun = fn -> Agent.update(calls, &(&1 + 1)) && {:ok, :answer} end

      assert TTLCache.fetch(key, 60, fun) == {:ok, :answer}
      assert TTLCache.fetch(key, 60, fun) == {:ok, :answer}
      assert Agent.get(calls, & &1) == 1
    end

    test "never remembers a failure" do
      key = {:test, System.unique_integer()}
      assert TTLCache.fetch(key, 60, fn -> {:error, :boom} end) == {:error, :boom}
      assert TTLCache.fetch(key, 60, fn -> {:ok, 1} end) == {:ok, 1}
    end

    test "expired entries are recomputed" do
      key = {:test, System.unique_integer()}
      assert TTLCache.fetch(key, 0, fn -> {:ok, 1} end) == {:ok, 1}
      assert TTLCache.fetch(key, 60, fn -> {:ok, 2} end) == {:ok, 2}
    end

    test "concurrent askers for a cold key share one computation" do
      key = {:test, System.unique_integer()}
      {:ok, calls} = Agent.start_link(fn -> 0 end)

      fun = fn ->
        Agent.update(calls, &(&1 + 1))
        Process.sleep(100)
        {:ok, :shared}
      end

      results =
        1..8
        |> Task.async_stream(fn _ -> TTLCache.fetch(key, 60, fun) end)
        |> Enum.map(&elem(&1, 1))

      assert Enum.all?(results, &(&1 == {:ok, :shared}))
      assert Agent.get(calls, & &1) == 1
    end

    test "a sweep trims past the size cap, soonest-to-expire first" do
      base = System.unique_integer([:positive])
      for i <- 1..30, do: TTLCache.fetch({:sweep, base, i}, 100 + i, fn -> {:ok, i} end)
      before = TTLCache.size()
      TTLCache.sweep(before - 10)
      assert TTLCache.size() == before - 10
      # the ones that expire first went first
      assert TTLCache.fetch({:sweep, base, 1}, 60, fn -> {:ok, :recomputed} end) ==
               {:ok, :recomputed}

      assert TTLCache.fetch({:sweep, base, 30}, 60, fn -> {:ok, :recomputed} end) == {:ok, 30}
    end
  end
end
