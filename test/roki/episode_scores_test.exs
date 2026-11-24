defmodule Roki.EpisodeScoresTest do
  use ExUnit.Case, async: true

  alias Roki.EpisodeScores

  test "a kept season comes back with atoms, and its average is over the rated episodes only" do
    s =
      EpisodeScores.shape(%{
        "number" => 8,
        "episodes" => [
          %{
            "number" => 1,
            "name" => "Winterfell",
            "score" => 7.085,
            "votes" => 365,
            "air_date" => "2019-04-14"
          },
          %{
            "number" => 6,
            "name" => "The Iron Throne",
            "score" => 4.476,
            "votes" => 481,
            "air_date" => "2019-05-19"
          },
          %{
            "number" => 7,
            "name" => "Unrated",
            "score" => nil,
            "votes" => 0,
            "air_date" => "2019-05-26"
          }
        ]
      })

    assert s.number == 8
    assert s.average == 5.8
    assert [%{number: 1, votes: 365}, %{number: 6, score: 4.476}, %{score: nil}] = s.episodes
  end

  test "a season read back from Roki.Kept with atom keys reads the same" do
    assert %{number: 2, average: 8.0, episodes: [%{number: 1, name: "A", votes: 12}]} =
             EpisodeScores.shape(%{
               number: 2,
               episodes: [%{number: 1, name: "A", score: 8.0, votes: 12, air_date: "2020-01-01"}]
             })
  end

  test "a season nobody rated has no average" do
    assert %{average: nil} =
             EpisodeScores.shape(%{"number" => 1, "episodes" => [%{"number" => 1, "votes" => 0}]})
  end

  test "the episode colours run red to deep green over 4..9.5, and a 10 is gold" do
    assert RokiWeb.TitleLive.ep_color(3.0) == RokiWeb.TitleLive.ep_color(4.0)
    assert RokiWeb.TitleLive.ep_color(4.0) == RokiWeb.ScoreColor.color(1)
    assert RokiWeb.TitleLive.ep_color(7.75) == RokiWeb.ScoreColor.color(7)
    assert RokiWeb.TitleLive.ep_color(9.6) == RokiWeb.ScoreColor.color(9.5)
    assert RokiWeb.TitleLive.ep_color(10) == "var(--gold)"
  end
end
