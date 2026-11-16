defmodule Roki.RecommendationsTest do
  use Roki.DataCase, async: true

  alias Roki.Recommendations

  test "the badge says who vouched" do
    assert Recommendations.badge(["alex"]) == "👍 alex"
    assert Recommendations.badge(["alex", "mom", "max"]) == "👍 alex +2"
    assert Recommendations.badge([]) == nil
  end

  test "a visitor recommends nothing" do
    refute Recommendations.recommended?(nil, "movie", 949)
  end

  test "an unknown title has no recommenders, and the row starts empty" do
    assert Recommendations.by("movie", 999_999_999) == []
    assert is_list(Recommendations.row())
  end
end
