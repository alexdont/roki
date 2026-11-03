defmodule Roki.AniSkipTest do
  use ExUnit.Case, async: true

  test "parse keeps openings and endings, mixed ones as the same kind, and the cut's length" do
    body = %{
      "found" => true,
      "results" => [
        %{
          "interval" => %{"startTime" => 54.711, "endTime" => 145.111},
          "skipType" => "op",
          "episodeLength" => 1435.122
        },
        %{
          "interval" => %{"startTime" => 1338.255, "endTime" => 1428.255},
          "skipType" => "ed",
          "episodeLength" => 1435.028
        },
        %{
          "interval" => %{"startTime" => 223, "endTime" => 313},
          "skipType" => "mixed-ed",
          "episodeLength" => 1492
        },
        %{
          "interval" => %{"startTime" => 10, "endTime" => 20},
          "skipType" => "recap",
          "episodeLength" => 1435
        },
        %{"interval" => %{"startTime" => 30, "endTime" => 20}, "skipType" => "op"}
      ]
    }

    assert [
             %{kind: "op", from: 54.711, to: 145.111, length: 1435.122},
             %{kind: "ed", from: 1338.255},
             %{kind: "ed", from: 223.0, length: 1492.0}
           ] = Roki.AniSkip.parse(body)

    assert Roki.AniSkip.parse(%{"found" => false}) == []
  end

  test "offline in the test suite, and nothing asked for a missing id" do
    assert Roki.AniSkip.times(40748, 1) == {:ok, []}
    assert Roki.AniSkip.times(nil, 1) == {:ok, []}
  end
end
