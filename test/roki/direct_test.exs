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
    # Preferences in order: the account's language first, then the title's own.
    assert Roki.Direct.master_playlist(tracks, 1_000_000, ["en", "ko"]) =~ ~s(NAME="Korean",LANGUAGE="ko",DEFAULT=YES)
    assert Roki.Direct.master_playlist(tracks, 1_000_000, ["ru", "ko"]) =~ ~s(NAME="Russian",LANGUAGE="ru",DEFAULT=YES)
  end

  test "a part's playlists name the part, its files carry it in their names" do
    tracks = [%{file: "audio0", lang: "eng", name: "English"}, %{file: "audio1", lang: "kor", name: "Korean"}]
    subs = [%{file: "sub0", lang: "fre", name: "French"}, %{file: "ext-en-os12", lang: "en", name: "English (OpenSubtitles)"}]

    pl = Roki.Direct.master_playlist(tracks, 1_000_000, "ko", subs, 1800)
    assert pl =~ ~s(NAME="English",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=YES,URI="audio0.m3u8?from=1800")
    assert pl =~ ~s(NAME="Korean",LANGUAGE="ko",DEFAULT=YES,AUTOSELECT=YES,URI="audio1.m3u8?from=1800")
    assert pl =~ ~s(TYPE=SUBTITLES,GROUP-ID="subs",NAME="French",LANGUAGE="fr",DEFAULT=NO,AUTOSELECT=NO,URI="sub0.m3u8?from=1800")
    assert pl =~ ~s(URI="ext-en-os12.m3u8?from=1800")
    assert pl =~ ~s(AUDIO="aud",SUBTITLES="subs"\nvideo.m3u8?from=1800\n)

    # From the start, the names are plain.
    plain = Roki.Direct.master_playlist(tracks, 1_000_000, "ko", subs)
    assert plain =~ ~s(URI="audio0.m3u8")
    refute plain =~ "from="
    assert plain =~ "\nvideo.m3u8\n"

    assert Roki.Direct.part_name("media", ".mp4", 0) == "media.mp4"
    assert Roki.Direct.part_name("media", ".mp4", 1800) == "media-1800.mp4"
    assert Roki.Direct.part_name("done", "", 1800) == "done-1800"
    assert Roki.Direct.part_query(0) == ""
    assert Roki.Direct.part_query(1800) == "?from=1800"
  end

  test "H.264 is decodable everywhere; the rest only where the browser says so" do
    assert Roki.Direct.decodable?("h264", %{})
    assert Roki.Direct.decodable?("x264", %{hevc: false})
    refute Roki.Direct.decodable?("hevc", %{})
    assert Roki.Direct.decodable?("hevc", %{hevc: true})
    refute Roki.Direct.decodable?("mpeg4", %{hevc: true, av1: true})
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

  describe "the audio of a converted file" do
    @streams [
      %{index: 0, kind: "video", codec: "hevc", lang: ""},
      %{index: 1, kind: "audio", codec: "eac3", lang: "fre"}
    ]
    @audios [%{index: 1, codec: "eac3", lang: "fre", file: "audio0", name: "French"}]

    # `-ac:0` is output stream 0 of any kind, the video, so the audio stayed 5.1 and a browser could
    # not decode the AAC written for it.
    test "is mixed down to stereo on the audio stream itself, not on stream 0" do
      cmd = Roki.Direct.command("http://x/f.mkv", "/tmp/d", @streams, @audios, [], 0)
      assert cmd =~ "'-ac:a:0' '2'"
      refute cmd =~ "'-ac:0'"
    end

    test "is mixed down the same way in a part begun later" do
      cmd = Roki.Direct.command("http://x/f.mkv", "/tmp/d", @streams, @audios, [], 75)
      assert cmd =~ "'-ac:a:0' '2'"
    end
  end
end
