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

  describe "MusicBrainz" do
    test "a film is searched within a year of its release, a show by name alone" do
      assert Soundtrack.query("Heat", %{type: "movie", year: "1995"}) ==
               ~s(releasegroup:"Heat" AND secondarytype:soundtrack AND firstreleasedate:[1994 TO 1996])

      assert Soundtrack.query("Game of Thrones", %{type: "tv", year: "2011"}) ==
               ~s(releasegroup:"Game of Thrones" AND secondarytype:soundtrack)

      # Quotes in a name are escaped, not ended.
      assert Soundtrack.query(~s(The "Movie"), %{type: "movie", year: nil}) =~
               ~s(releasegroup:"The \\"Movie\\"")
    end

    test "the albums kept are the ones named after the title, oldest first, a handful at most" do
      groups =
        [
          %{
            "id" => "a",
            "title" => "Heat (Music From the Motion Picture)",
            "score" => 100,
            "primary-type" => "Album",
            "first-release-date" => "1995-12-19",
            "artist-credit" => [%{"name" => "Various Artists"}]
          },
          # A search matches on words: this is not the film's.
          %{"id" => "b", "title" => "Body Heat", "score" => 90, "primary-type" => "Album"},
          %{"id" => "c", "title" => "Heat", "score" => 40, "primary-type" => "Album"},
          %{
            "id" => "d",
            "title" => "Heat: The Score",
            "score" => 80,
            "primary-type" => "Album",
            "first-release-date" => "1996"
          },
          %{"id" => "e", "title" => "Heat", "score" => 80, "primary-type" => "Single"}
        ] ++
          for(
            n <- 1..6,
            do: %{
              "id" => "x#{n}",
              "title" => "Heat #{n}",
              "score" => 60,
              "primary-type" => "Album"
            }
          )

      albums = Soundtrack.pick_albums(groups, "Heat")

      assert Enum.map(albums, & &1.id) == ["a", "d", "x1", "x2", "x3", "x4", "x5", "x6"]

      assert hd(albums) == %{
               id: "a",
               title: "Heat (Music From the Motion Picture)",
               year: "1995",
               artist: "Various Artists",
               tracks: nil
             }

      assert Soundtrack.pick_albums(nil, "Heat") == []
    end

    test "the tracks are the fullest release's, numbered through its discs, with the artist and length" do
      releases = [
        %{"media" => [%{"tracks" => [%{"title" => "Only one", "length" => 1000}]}]},
        %{
          "media" => [
            %{
              "tracks" => [
                %{
                  "title" => "Heat",
                  "length" => 461_826,
                  "artist-credit" => [
                    %{"name" => "Elliot Goldenthal", "joinphrase" => " feat. "},
                    %{"name" => "Kronos Quartet"}
                  ]
                }
              ]
            },
            %{
              "tracks" => [
                %{
                  "title" => "Condensers",
                  "recording" => %{
                    "length" => 155_000,
                    "artist-credit" => [%{"artist" => %{"name" => "Elliot Goldenthal"}}]
                  }
                }
              ]
            }
          ]
        }
      ]

      assert Soundtrack.parse_tracks(releases) == [
               %{
                 n: 1,
                 title: "Heat",
                 artist: "Elliot Goldenthal feat. Kronos Quartet",
                 secs: 461
               },
               %{n: 2, title: "Condensers", artist: "Elliot Goldenthal", secs: 155}
             ]

      assert Soundtrack.parse_tracks([]) == []
    end

    test "an artist credited in kana is named by the Latin sort name, first name first" do
      releases = [
        %{
          "media" => [
            %{
              "tracks" => [
                %{
                  "title" => "Tank!",
                  "artist-credit" => [
                    %{
                      "name" => "シートベルツ",
                      "artist" => %{"name" => "シートベルツ", "sort-name" => "Seatbelts, The"}
                    }
                  ]
                },
                %{
                  "title" => "Rush",
                  "artist-credit" => [
                    %{
                      "name" => "菅野よう子",
                      "artist" => %{"sort-name" => "Kanno, Yoko"},
                      "joinphrase" => " & "
                    },
                    %{"name" => "シートベルツ", "artist" => %{"sort-name" => "シートベルツ"}}
                  ]
                }
              ]
            }
          ]
        }
      ]

      assert [%{artist: "The Seatbelts"}, %{artist: "Yoko Kanno & シートベルツ"}] =
               Soundtrack.parse_tracks(releases)
    end
  end

  test "a YouTube search carries the words that are there, each once" do
    assert Soundtrack.youtube(["Hans Zimmer", nil, "Dust", "", "Interstellar"]) ==
             "https://www.youtube.com/results?search_query=Hans+Zimmer+Dust+Interstellar"

    assert Soundtrack.youtube(["Kronos Quartet", "Heat", "Heat"]) ==
             "https://www.youtube.com/results?search_query=Kronos+Quartet+Heat"
  end
end
