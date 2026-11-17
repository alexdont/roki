defmodule Roki.TitlesGoneTest do
  use Roki.DataCase, async: false

  test "a title TMDB has no more is remembered as gone" do
    refute Roki.Titles.gone?("movie", 1_781_322)
    Roki.Titles.mark_gone("movie", 1_781_322)
    assert Roki.Titles.gone?("movie", 1_781_322)
    refute Roki.Titles.gone?("tv", 1_781_322)
  end
end
