defmodule Roki.TrailersTest do
  use ExUnit.Case, async: true

  alias Roki.Trailers

  defp video(key, extra \\ %{}),
    do:
      Map.merge(
        %{
          "key" => key,
          "site" => "YouTube",
          "type" => "Trailer",
          "official" => true,
          "published_at" => "2026-01-01T00:00:00.000Z"
        },
        extra
      )

  test "official trailers come before teasers, and the newest official trailer first" do
    results = [
      video("teaser", %{"type" => "Teaser"}),
      video("unofficial", %{"official" => false, "published_at" => "2026-06-01T00:00:00.000Z"}),
      video("old", %{"published_at" => "2025-01-01T00:00:00.000Z"}),
      video("new", %{"published_at" => "2026-03-01T00:00:00.000Z"})
    ]

    assert Trailers.candidates(results) == ["new", "old", "unofficial"]
  end

  test "only YouTube trailers and teasers are candidates" do
    results = [
      video("clip", %{"type" => "Clip"}),
      video("vimeo", %{"site" => "Vimeo"}),
      video("featurette", %{"type" => "Featurette"}),
      %{"site" => "YouTube", "type" => "Trailer"},
      video("ok")
    ]

    assert Trailers.candidates(results) == ["ok"]
    assert Trailers.candidates(nil) == []
    assert Trailers.candidates([]) == []
  end

  test "no more than three are tried, and each once" do
    results = for k <- ~w(a b c d e), do: video(k)
    assert length(Trailers.candidates(results ++ [video("a")])) == 3
  end
end
