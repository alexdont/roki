defmodule Roki.FriendsTest do
  use ExUnit.Case, async: true

  alias Roki.Friends

  test "a score reads against the friend's own average" do
    assert Friends.verdict(9.0, 7.2) == :great
    assert Friends.verdict(8.0, 7.2) == :good
    assert Friends.verdict(7.0, 7.2) == :typical
    assert Friends.verdict(6.5, 7.2) == :below
    assert Friends.verdict(5.0, 7.2) == :poor
    assert Friends.verdict(nil, 7.2) == nil
    assert Friends.verdict(8.0, nil) == nil
    assert Friends.words(:great) == "loved it"
    assert Friends.words(nil) == nil
  end

  test "a friend's line says the score and what it means, or just that they saw it" do
    assert Friends.describe(%{username: "alex", score: 8.5, verdict: :good}) ==
             "alex ★ 8.5 · more than their usual"

    assert Friends.describe(%{username: "alex", score: 8.0, verdict: nil}) == "alex ★ 8"
    assert Friends.describe(%{username: "mom", score: nil, verdict: nil}) == "mom · seen"
  end

  test "the poster's chip" do
    assert Friends.chip(nil) == nil
    assert Friends.chip(0) == nil
    assert Friends.chip(3) == "3"
    assert Friends.chip(12) == "9+"
  end

  test "nothing for a visitor" do
    assert Friends.seen(nil) == %{}
    assert Friends.on_title(nil, "movie", 1) == []
  end
end
