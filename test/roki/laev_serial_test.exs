defmodule Roki.LaevSerialTest do
  use ExUnit.Case, async: false

  # Two syncs of one account must take turns: laev empties a file before it fills it again, and a
  # second sync reading meanwhile pushed the empty mark as a change (an old episode unwatched).
  test "syncs of one account take turns; another account's do not wait" do
    base = Path.join(System.tmp_dir!(), "roki-serial-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf(base) end)
    [a, b] = for n <- ~w(a b), do: Laev.Scope.new(Path.join(base, n), %{})
    parent = self()

    work = fn scope, tag ->
      Task.async(fn ->
        Laev.Scope.run(scope, fn ->
          Roki.Laev.serial(fn ->
            send(parent, {:in, tag, System.monotonic_time(:millisecond)})
            Process.sleep(150)
            send(parent, {:out, tag, System.monotonic_time(:millisecond)})
          end)
        end)
      end)
    end

    tasks = [work.(a, :a1), work.(a, :a2), work.(b, :b1)]
    Task.await_many(tasks)

    times =
      for _ <- 1..6, into: %{} do
        receive do
          {edge, tag, t} -> {{edge, tag}, t}
        end
      end

    # a1 and a2 never overlap…
    [first, second] = Enum.sort_by([:a1, :a2], &times[{:in, &1}])
    assert times[{:in, second}] >= times[{:out, first}]
    # …while b1 ran beside the first of them.
    assert times[{:in, :b1}] < times[{:out, first}]
  end

  test "the lock is re-entrant for the process holding it" do
    scope = Laev.Scope.new(Path.join(System.tmp_dir!(), "roki-serial-re"), %{})

    assert Laev.Scope.run(scope, fn ->
             Roki.Laev.serial(fn -> Roki.Laev.serial(fn -> :inner end) end)
           end) == :inner
  end
end
