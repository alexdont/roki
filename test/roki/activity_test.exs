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

  test "how far in a started entry is, as a clock" do
    assert Activity.watched_text(%{kind: "started", seconds: 1412}) == "23:32"
    assert Activity.watched_text(%{kind: "started", seconds: 3909}) == "1:05:09"
    assert Activity.watched_text(%{kind: "finished", seconds: 1412}) == nil
    assert Activity.watched_text(%{kind: "started", seconds: nil}) == nil
  end

  describe "batching and describing" do
    defp mv(user, id, at_min, kind, extra \\ %{}),
      do:
        ev(
          user,
          id,
          at_min,
          Map.merge(%{type: "movie", season: nil, episode: nil, kind: kind}, extra)
        )

    test "films finished within an hour are one batch; hours apart stay separate" do
      [b] =
        Activity.group([
          mv("a", 1, 0, "finished"),
          mv("a", 2, 10, "finished"),
          mv("a", 3, 20, "finished")
        ])

      assert b.batch? and b.count == 3 and length(b.items) == 3
      assert Activity.describe(b).verb == "finished 3 films"

      assert length(Activity.group([mv("a", 1, 0, "finished"), mv("a", 2, 300, "finished")])) == 2
    end

    test "different people and different kinds never batch together" do
      assert length(Activity.group([mv("a", 1, 0, "finished"), mv("b", 2, 5, "finished")])) == 2
      assert length(Activity.group([mv("a", 1, 0, "finished"), mv("a", 2, 5, "saved")])) == 2
    end

    test "backdated entries read as added to history, with the date" do
      one = Activity.group([mv("a", 1, 0, "backdated", %{watched_on: ~D[2019-03-02]})]) |> hd()
      d = Activity.describe(one)
      assert d.verb == "added" and d.after == "to their history"
      assert d.detail =~ "2019"

      [b] =
        Activity.group([
          mv("a", 1, 0, "backdated", %{watched_on: ~D[2019-03-02]}),
          mv("a", 2, 3, "backdated", %{watched_on: ~D[2020-01-05]})
        ])

      d = Activity.describe(b)
      assert b.batch? and d.verb == "added 2 films"
      assert d.detail =~ "2019" and d.detail =~ "2020"
    end

    test "saved titles batch and say for later" do
      [b] = Activity.group([mv("a", 1, 0, "saved"), mv("a", 2, 4, "saved")])
      d = Activity.describe(b)
      assert d.verb == "saved 2 films" and d.after == "for later"
    end

    test "episodes of a show are not batched as films" do
      out = Activity.group([ev("a", 7, 1), ev("a", 7, 2), ev("a", 8, 3)])
      assert length(out) == 2
      refute Enum.any?(out, & &1.batch?)
    end

    test "a rating shows its score" do
      [r] = Activity.group([mv("a", 1, 0, "rated", %{score: 8.5})])
      assert Activity.describe(r).detail =~ "8.5"
    end
  end

  test "a rating given in the same sitting folds into the watching" do
    events =
      for(n <- 1..3, do: ev("alex", 1, n)) ++
        [ev("alex", 1, 10, %{kind: "rated", score: 6.0, season: nil, episode: nil})]

    assert [run] = Activity.group(events)
    assert run.count == 3 and run.score == 6.0
    assert Activity.describe(run).detail =~ "rated ★ 6"
  end

  test "a rating of something else, or hours later, stays on its own" do
    rated = ev("alex", 1, 600, %{kind: "rated", score: 7.0, season: nil, episode: nil})
    assert length(Activity.group([ev("alex", 1, 1), rated])) == 2
    other = ev("alex", 2, 2, %{kind: "rated", score: 7.0, season: nil, episode: nil})
    assert length(Activity.group([ev("alex", 1, 1), other])) == 2
  end
end
