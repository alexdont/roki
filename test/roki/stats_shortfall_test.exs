defmodule Roki.StatsShortfallTest do
  @moduledoc """
  A film the record calls finished, measured for four minutes: what it is worth.
  """
  use ExUnit.Case, async: true

  alias Roki.Stats

  setup do
    dir = Path.join(System.tmp_dir!(), "shortfall-#{System.unique_integer([:positive])}")
    File.mkdir_p!(Path.join(dir, "positions"))
    File.mkdir_p!(Path.join(dir, "played"))

    File.write!(
      Path.join(dir, "runtimes.json"),
      Jason.encode!(%{
        "movie-27324" => 7140,
        "movie-1" => 7200,
        "movie-2" => 7200,
        "tv-110316" => 3000,
        "mal-1425" => 1440
      })
    )

    Laev.Scope.put(Laev.Scope.new(dir))
    on_exit(fn -> Laev.Scope.clear() end)

    %{dir: dir}
  end

  defp entry(dir, name, position, played \\ nil) do
    File.write!(Path.join([dir, "positions", name]), position)
    if played, do: File.write!(Path.join([dir, "played", name]), played)
  end

  test "a finished film measured for four minutes is worth its runtime", %{dir: dir} do
    entry(dir, "movie-27324", "done", "293 4817")

    assert Stats.shortfalls() == %{{"movie", 27_324} => 7140 - 293}
  end

  test "a hand mark with a stray measurement counts as a hand mark", %{dir: dir} do
    entry(dir, "movie-1", "seen", "254 8914")

    assert Stats.shortfalls() == %{{"movie", 1} => 7200 - 254}
  end

  test "a play that really was measured keeps its own figure", %{dir: dir} do
    # Over half the runtime: laev followed this one, and its reading stands.
    entry(dir, "movie-2", "done", "6027 800")

    assert Stats.shortfalls() == %{}
  end

  test "nothing is invented where the record says nothing", %{dir: dir} do
    # Unfinished, no measurement, and no known runtime: three ways to be left alone.
    entry(dir, "movie-1", "1200", "1200 0")
    entry(dir, "movie-2", "done")
    entry(dir, "movie-999", "done", "10 0")

    assert Stats.shortfalls() == %{}
  end

  test "episodes count under their show, and anime under its own runtime", %{dir: dir} do
    entry(dir, "tv-110316-s1e1", "seen", "60 0")
    entry(dir, "tv-110316-s1e2", "done", "30 0")
    entry(dir, "mal-1425-e3", "seen", "12 0")

    assert Stats.shortfalls() == %{
             {"tv", 110_316} => 3000 - 60 + (3000 - 30),
             {"mal", 1425} => 1440 - 12
           }
  end
end
