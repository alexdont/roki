defmodule Roki.SubsTest do
  use ExUnit.Case, async: true

  @id "0123456789abcde1"

  setup do
    dir = Laev.Remux.dir(@id)
    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf(dir) end)
    %{dir: dir}
  end

  @vtt """
  WEBVTT

  1
  00:00:01.000 --> 00:00:03.000 line:90%
  First

  00:03.500 --> 00:05.000
  Second
  line two

  00:00:09.000 --> 00:00:12.000
  Third
  """

  test "a WebVTT text parses into timed cues" do
    assert [%{from: 1.0, to: 3.0, settings: " line:90%", text: "First"}, %{from: 3.5, to: 5.0, text: "Second\nline two"}, %{from: 9.0, to: 12.0}] =
             Roki.Subs.parse(@vtt)
  end

  test "laev's stream gets subtitle renditions cut like its segments, on its clock", %{dir: dir} do
    File.write!(Path.join(dir, "index.m3u8"), "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.000,\nseg00000.ts\n#EXTINF:4.000,\nseg00001.ts\n#EXTINF:4.000,\nseg00002.ts\n#EXT-X-ENDLIST\n")
    File.write!(Path.join(dir, "subs.json"), ~s([{"index":3,"lang":"fre","file":"sub0"}]))
    File.write!(Path.join(dir, "sub0.vtt"), @vtt)
    File.write!(Path.join(dir, "ext-en-os12.vtt"), @vtt)

    assert [%{file: "ext-en-os12", lang: "en", name: "English (OpenSubtitles)"}, %{file: "sub0", lang: "fre", name: "French"}] =
             Roki.Subs.tracks(@id)

    pl = Roki.Subs.playlist(@id, "sub0")
    assert pl =~ "#EXTINF:4.000,\nsub0.0.vtt\n#EXTINF:4.000,\nsub0.1.vtt\n#EXTINF:4.000,\nsub0.2.vtt\n#EXT-X-ENDLIST"

    # Piece 0 (0–4 s) has the first two cues, the second crossing its end; piece 1 (4–8 s) the second only.
    piece0 = Roki.Subs.segment(@id, "sub0", 0)
    assert String.starts_with?(piece0, "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:126000,LOCAL:00:00:00.000\n\n00:00:01.000")
    assert piece0 =~ "00:00:01.000 --> 00:00:03.000 line:90%\nFirst"
    assert piece0 =~ "00:00:03.500 --> 00:00:05.000\nSecond\nline two"
    refute piece0 =~ "Third"
    piece1 = Roki.Subs.segment(@id, "sub0", 1)
    assert piece1 =~ "Second"
    refute piece1 =~ "First"
    assert Roki.Subs.segment(@id, "sub0", 2) =~ "Third"
    assert Roki.Subs.segment(@id, "sub0", 7) == nil

    [r1, r2] = Roki.Subs.renditions(Roki.Subs.tracks(@id))
    assert r1 == ~s|#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English (OpenSubtitles)",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=NO,URI="ext-en-os12.m3u8"|
    assert r2 =~ ~s|NAME="French",LANGUAGE="fr"|

    wrapped = Roki.Direct.wrap_media("index.m3u8", Roki.Subs.tracks(@id))
    assert wrapped =~ ~s|#EXT-X-STREAM-INF:BANDWIDTH=8000000,SUBTITLES="subs"\nindex.m3u8|
    assert wrapped =~ "TYPE=SUBTITLES"
  end
end
