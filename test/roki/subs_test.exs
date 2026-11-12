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
    assert [
             %{from: 1.0, to: 3.0, settings: " line:90%", text: "First"},
             %{from: 3.5, to: 5.0, text: "Second\nline two"},
             %{from: 9.0, to: 12.0}
           ] =
             Roki.Subs.parse(@vtt)
  end

  # A conversion begun 5 s into a 12 s film (ffmpeg seeks to the keyframe before: 4 s),
  # keeping the film's own clock; the pieces and the page both count in it.
  test "a direct part counts in the film's own time, from where it began", %{dir: dir} do
    if ffmpeg = System.find_executable("ffmpeg") do
      args =
        ~w(-nostdin -loglevel error -y -f lavfi -i testsrc=size=64x64:rate=25 -f lavfi -i sine=frequency=440 -t 12
        -map 0:v -map 1:a -c:v libx264 -g 50 -keyint_min 50 -sc_threshold 0 -c:a aac) ++
          [Path.join(dir, "src.mp4")]

      {_, 0} = System.cmd(ffmpeg, args, stderr_to_stdout: true)

      part =
        ~w(-nostdin -loglevel error -y -ss 5 -i) ++
          [Path.join(dir, "src.mp4")] ++
          ~w(-copyts -map 0:v:0 -map 0:a:0 -c copy -movflags frag_keyframe+empty_moov+default_base_moof+delay_moov+frag_discont
        -min_frag_duration 2000000 -f mp4) ++ [Path.join(dir, "media-5.mp4")]

      {_, 0} = System.cmd(ffmpeg, part, stderr_to_stdout: true)

      File.write!(
        Path.join(dir, "audio.json"),
        ~s([{"index":1,"codec":"aac","lang":"","file":"audio0","name":"Track 1"}])
      )

      File.write!(Path.join(dir, "subs.json"), ~s([{"index":2,"lang":"fre","file":"sub0"}]))

      File.write!(
        Path.join(dir, "sub0-5.vtt"),
        "WEBVTT\n\n00:00:02.000 --> 00:00:03.500\nBefore\n\n00:00:04.800 --> 00:00:06.000\nFirst\n\n00:00:09.000 --> 00:00:10.000\nLater\n"
      )

      File.write!(
        Path.join(dir, "ext-en-os1.vtt"),
        "WEBVTT\n\n00:00:05.000 --> 00:00:05.500\nFetched\n"
      )

      File.write!(Path.join(dir, "done-5"), "")

      {:ok, scan} = Fmp4.scan(Path.join(dir, "media-5.mp4"))
      assert_in_delta scan.start, 4.0, 0.05
      assert [first | _] = scan.fragments
      assert_in_delta first.time, 4.0, 0.05
      assert Roki.Direct.parts(@id) == [5]
      assert_in_delta Roki.Direct.start_at(@id, 5), 4.0, 0.05
      assert Roki.Direct.ready?(@id, 5)

      # The video playlist counts from the part's start; the file names carry the part.
      video = Roki.Direct.media_playlist(@id, 5, "media")
      assert video =~ ~s(#EXT-X-MAP:URI="media-5.mp4")
      assert video =~ "#EXT-X-ENDLIST"
      assert Roki.Direct.playlist(@id, 5) =~ ~s(URI="sub0.m3u8?from=5")

      # The release's subtitle is the part's own file; the fetched one serves every part.
      assert [%{file: "ext-en-os1"}, %{file: "sub0", name: "French"}] = Roki.Subs.tracks(@id, 5)
      assert [%{file: "ext-en-os1"}] = Roki.Subs.tracks(@id, 0)

      pl = Roki.Subs.playlist(@id, "sub0", 5)
      assert pl =~ "sub0.0.vtt?from=5"
      assert pl =~ "#EXT-X-ENDLIST"

      # The first piece covers the film from 4 s: the cue that ends before it is left out, the
      # one running into it is in, on the film's clock (the fragments carry it: no map offset).
      piece = Roki.Subs.segment(@id, "sub0", 0, 5)
      assert piece =~ "X-TIMESTAMP-MAP=MPEGTS:0,LOCAL:00:00:00.000"
      assert piece =~ "00:00:04.800 --> 00:00:06.000\nFirst"
      refute piece =~ "Before"
      assert Roki.Subs.segment(@id, "ext-en-os1", 0, 5) =~ "Fetched"
    end
  end

  test "laev's stream gets subtitle renditions cut like its segments, on its clock", %{dir: dir} do
    File.write!(
      Path.join(dir, "index.m3u8"),
      "#EXTM3U\n#EXT-X-TARGETDURATION:4\n#EXTINF:4.000,\nseg00000.ts\n#EXTINF:4.000,\nseg00001.ts\n#EXTINF:4.000,\nseg00002.ts\n#EXT-X-ENDLIST\n"
    )

    File.write!(Path.join(dir, "subs.json"), ~s([{"index":3,"lang":"fre","file":"sub0"}]))
    File.write!(Path.join(dir, "sub0.vtt"), @vtt)
    File.write!(Path.join(dir, "ext-en-os12.vtt"), @vtt)

    assert [
             %{file: "ext-en-os12", lang: "en", name: "English (OpenSubtitles)"},
             %{file: "sub0", lang: "fre", name: "French"}
           ] =
             Roki.Subs.tracks(@id)

    pl = Roki.Subs.playlist(@id, "sub0")

    assert pl =~
             "#EXTINF:4.000,\nsub0.0.vtt\n#EXTINF:4.000,\nsub0.1.vtt\n#EXTINF:4.000,\nsub0.2.vtt\n#EXT-X-ENDLIST"

    # Piece 0 (0–4 s) has the first two cues, the second crossing its end; piece 1 (4–8 s) the second only.
    piece0 = Roki.Subs.segment(@id, "sub0", 0)

    assert String.starts_with?(
             piece0,
             "WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:126000,LOCAL:00:00:00.000\n\n00:00:01.000"
           )

    assert piece0 =~ "00:00:01.000 --> 00:00:03.000 line:90%\nFirst"
    assert piece0 =~ "00:00:03.500 --> 00:00:05.000\nSecond\nline two"
    refute piece0 =~ "Third"
    piece1 = Roki.Subs.segment(@id, "sub0", 1)
    assert piece1 =~ "Second"
    refute piece1 =~ "First"
    assert Roki.Subs.segment(@id, "sub0", 2) =~ "Third"
    assert Roki.Subs.segment(@id, "sub0", 7) == nil

    [r1, r2] = Roki.Subs.renditions(Roki.Subs.tracks(@id))

    assert r1 ==
             ~s|#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="English (OpenSubtitles)",LANGUAGE="en",DEFAULT=NO,AUTOSELECT=NO,URI="ext-en-os12.m3u8"|

    assert r2 =~ ~s|NAME="French",LANGUAGE="fr"|

    wrapped = Roki.Direct.wrap_media("index.m3u8", Roki.Subs.tracks(@id))
    assert wrapped =~ ~s|#EXT-X-STREAM-INF:BANDWIDTH=8000000,SUBTITLES="subs"\nindex.m3u8|
    assert wrapped =~ "TYPE=SUBTITLES"
  end
end
