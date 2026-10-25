defmodule Roki.ActivityTest do
  use ExUnit.Case, async: true

  alias Roki.Activity

  defp ev(user, id, at_min, extra \\ %{}) do
    Map.merge(
      %{
        user: user,
        username: user,
        type: "tv",
        tmdb_id: id,
        season: 1,
        episode: at_min,
        title: "Show #{id}",
        poster: nil,
        kind: "finished",
        at: DateTime.add(~U[2026-10-25 12:00:00Z], at_min * 60)
      },
      extra
    )
  end

  test "episodes close together by one person are one binge, newest run first" do
    events = for n <- 1..25, do: ev("alex", 1, n)
    [run] = Activity.group(Enum.shuffle(events))
    assert run.count == 25 and run.binge?
    assert Activity.verb(run) == "binged 25 episodes of"
  end

  test "a long pause, another person or another show starts a new run" do
    events = [
      ev("alex", 1, 1),
      ev("alex", 1, 2),
      ev("alex", 1, 3),
      # nine hours later
      ev("alex", 1, 600),
      ev("max", 1, 4),
      ev("alex", 2, 5)
    ]

    runs = Activity.group(events)
    assert length(runs) == 4
    assert Enum.map(runs, & &1.at) == Enum.sort(Enum.map(runs, & &1.at), {:desc, DateTime})
    assert Enum.find(runs, &(&1.username == "alex" and &1.tmdb_id == 1 and &1.count == 3)).binge?
  end

  test "the sentence for one episode, two, and a film" do
    assert [one] = Activity.group([ev("a", 1, 1, %{season: 2, episode: 4})])
    assert Activity.verb(one) == "finished S2E4 of"
    assert [two] = Activity.group([ev("a", 1, 1), ev("a", 1, 2)])
    assert Activity.verb(two) == "finished 2 episodes of"
    assert [film] = Activity.group([ev("a", 9, 1, %{type: "movie", season: nil, episode: nil})])
    assert Activity.verb(film) == "finished"
  end

  test "only starting something is a start, however many times it was opened" do
    started = %{kind: "started"}
    assert [run] = Activity.group([ev("a", 1, 1, %{season: 1, episode: 4} |> Map.merge(started))])
    assert Activity.verb(run) == "started S1E4 of" and run.kind == "started"

    assert [film] =
             Activity.group([
               ev("a", 9, 1, %{type: "movie", season: nil, episode: nil, kind: "started"})
             ])

    assert Activity.verb(film) == "started"
  end

  test "starting the next episode after finishing some does not hide the finished ones" do
    events = [ev("a", 1, 1), ev("a", 1, 2), ev("a", 1, 3), ev("a", 1, 4, %{kind: "started"})]
    assert [run] = Activity.group(events)
    assert run.kind == "finished" and run.count == 3 and run.binge?
  end
end
