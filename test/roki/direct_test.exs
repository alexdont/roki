defmodule Roki.DirectTest do
  use ExUnit.Case, async: true

  test "a multi-audio master names every track as a rendition, the first the default" do
    tracks = [
      %{file: "audio0", lang: "kor", name: "Korean"},
      %{file: "audio1", lang: "rus", name: "Russian"},
      %{file: "audio2", lang: "", name: "Track 3"}
    ]

    pl = Roki.Direct.master_playlist(tracks, 12_000_000)

    assert pl =~ ~s(NAME="Korean",LANGUAGE="ko",DEFAULT=YES,AUTOSELECT=YES,URI="audio0.m3u8")
    assert pl =~ ~s(NAME="Russian",LANGUAGE="ru",DEFAULT=NO,AUTOSELECT=YES,URI="audio1.m3u8")
    assert pl =~ ~s(NAME="Track 3",DEFAULT=NO)
    assert pl =~ ~s(#EXT-X-STREAM-INF:BANDWIDTH=12000000,AUDIO="aud"\nvideo.m3u8)
    refute pl =~ "CODECS"
  end

  test "the preferred language is the default when the release has it" do
    tracks = [%{file: "audio0", lang: "rus", name: "Russian"}, %{file: "audio1", lang: "kor", name: "Korean"}]

    pl = Roki.Direct.master_playlist(tracks, 1_000_000, "ko")
    assert pl =~ ~s(NAME="Russian",LANGUAGE="ru",DEFAULT=NO)
    assert pl =~ ~s(NAME="Korean",LANGUAGE="ko",DEFAULT=YES)

    # A language the release lacks leaves the first track the default.
    assert Roki.Direct.master_playlist(tracks, 1_000_000, "en") =~ ~s(NAME="Russian",LANGUAGE="ru",DEFAULT=YES)
  end

  test "laev's master is cut to one rendition per file, named by language" do
    master = """
    #EXTM3U
    #EXT-X-VERSION:6
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_1",DEFAULT=YES,LANGUAGE="rus",CHANNELS="2",URI="s_Rus.m3u8"
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_2",DEFAULT=NO,LANGUAGE="rus",CHANNELS="2",URI="s_Rus.m3u8"
    #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="audio_3",DEFAULT=NO,LANGUAGE="kor",CHANNELS="2",URI="s_Korean.m3u8"
    #EXT-X-STREAM-INF:BANDWIDTH=10280966,CODECS="avc1.640029,mp4a.40.2",AUDIO="group_aud"
    s_0.m3u8
    """

    tidy = Roki.Direct.tidy_master(master, "ko")
    media = tidy |> String.split("\n") |> Enum.filter(&String.starts_with?(&1, "#EXT-X-MEDIA"))
    assert length(media) == 2
    # In the file's order: the first rendition stays first.
    assert String.starts_with?(hd(media), ~s(#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="Russian"))
    assert tidy =~ ~s(NAME="Russian",LANGUAGE="ru",DEFAULT=NO,AUTOSELECT=YES,URI="s_Rus.m3u8")
    assert tidy =~ ~s(NAME="Korean",LANGUAGE="ko",DEFAULT=YES,AUTOSELECT=YES,URI="s_Korean.m3u8")
    assert tidy =~ "#EXT-X-STREAM-INF:BANDWIDTH=10280966"
    assert tidy =~ "s_0.m3u8"
  end
end
