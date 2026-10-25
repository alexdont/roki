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
    assert Activity.verb(one) == "watched S2E4 of"
    assert [two] = Activity.group([ev("a", 1, 1), ev("a", 1, 2)])
    assert Activity.verb(two) == "watched 2 episodes of"
    assert [film] = Activity.group([ev("a", 9, 1, %{type: "movie", season: nil, episode: nil})])
    assert Activity.verb(film) == "watched"
  end
end
