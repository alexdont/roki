defmodule Roki.WatchedAtTest do
  @moduledoc """
  When a title was watched, against when its player was opened — the rule that stopped six
  seconds of testing from moving three hours of marked episodes into this week.
  """
  use ExUnit.Case, async: true

  alias Roki.Laev

  @anime %{type: "tv", id: 196_950, mal_id: 51_553, title: "Witch Hat Atelier"}
  @film %{type: "movie", id: 603, mal_id: nil, title: "The Matrix"}

  @opened 1_792_692_897
  @mal 1_790_250_430
  @session 1_793_000_000

  test "a session here beats everything, because it is the one thing that was measured" do
    at =
      Laev.watched_at(
        Map.put(@anime, :watched_at, @opened),
        %{{"mal", 51_553} => @session},
        %{51_553 => @mal},
        %{}
      )

    assert at == @session
  end

  test "a measurement worth more than a minute stands in for a session" do
    row = Map.put(@anime, :watched_at, @opened)

    assert Laev.watched_at(row, %{}, %{51_553 => @mal}, %{{"mal", 51_553} => 3600}) == @opened
  end

  test "six seconds of opening it does not, and MyAnimeList's own date wins" do
    row = Map.put(@anime, :watched_at, @opened)

    assert Laev.watched_at(row, %{}, %{51_553 => @mal}, %{{"mal", 51_553} => 6}) == @mal
    # Nor does no measurement at all.
    assert Laev.watched_at(row, %{}, %{51_553 => @mal}, %{}) == @mal
  end

  test "with nothing better to go on the shelf's own answer is kept, not thrown away" do
    row = Map.put(@anime, :watched_at, @opened)

    assert Laev.watched_at(row, %{}, %{}, %{}) == @opened
  end

  test "a film has no outside date, so its own stamp is all there is" do
    assert Laev.watched_at(Map.put(@film, :watched_at, @opened), %{}, %{}, %{}) == @opened

    # And a session still wins where there is one.
    assert Laev.watched_at(
             Map.put(@film, :watched_at, @opened),
             %{{"movie", 603} => @session},
             %{},
             %{}
           ) == @session
  end

  test "an undated row stays undated" do
    assert Laev.watched_at(Map.put(@anime, :watched_at, 0), %{}, %{}, %{}) == 0
  end
end
