defmodule Roki.SoundtrackTest do
  use ExUnit.Case, async: true

  alias Roki.Soundtrack

  describe "MyAnimeList themes" do
    test "a theme line is split into its number, song, artist and episodes" do
      assert Soundtrack.theme(~s(#2: "Space Lion" by The Seatbelts \(ep 13\))) ==
               %{n: 2, song: "Space Lion", artist: "The Seatbelts", eps: "ep 13"}

      assert Soundtrack.theme(~s("Tank!" by The Seatbelts \(eps 1-25\))) ==
               %{n: nil, song: "Tank!", artist: "The Seatbelts", eps: "eps 1-25"}

      # A song with its Japanese name in brackets, an artist with a guest, and no episodes.
      assert Soundtrack.theme(
               ~s(#1: "Kimi no Shiranai Monogatari \(君の知らない物語\)" by supercell feat. nagi)
             ) ==
               %{
                 n: 1,
                 song: "Kimi no Shiranai Monogatari (君の知らない物語)",
                 artist: "supercell feat. nagi",
                 eps: nil
               }
    end

    test "a line that is not in that shape is kept as the song, and an empty one dropped" do
      assert Soundtrack.theme("Main theme (instrumental)") ==
               %{n: nil, song: "Main theme (instrumental)", artist: nil, eps: nil}

      assert Soundtrack.theme("  ") == nil
      assert Soundtrack.theme(nil) == nil
    end

    test "the answer's openings and endings are parsed, nothing else" do
      body = %{
        "opening_themes" => [%{"text" => ~s("Tank!" by The Seatbelts \(eps 1-25\))}],
        "ending_themes" => [%{"text" => ~s(#1: "The Real Folk Blues" by The Seatbelts)}, %{}]
      }

      assert %{openings: [%{song: "Tank!"}], endings: [%{n: 1, song: "The Real Folk Blues"}]} =
               Soundtrack.parse_themes(body)

      assert Soundtrack.parse_themes(%{}) == %{openings: [], endings: []}
    end
  end

  test "a YouTube search carries the words that are there, each once" do
    assert Soundtrack.youtube(["Hans Zimmer", nil, "Dust", "", "Interstellar"]) ==
             "https://www.youtube.com/results?search_query=Hans+Zimmer+Dust+Interstellar"

    assert Soundtrack.youtube(["Kronos Quartet", "Heat", "Heat"]) ==
             "https://www.youtube.com/results?search_query=Kronos+Quartet+Heat"
  end
end
