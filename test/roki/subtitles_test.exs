defmodule Roki.SubtitlesTest do
  use ExUnit.Case, async: true

  alias Laev.Subtitles

  @srt "1\n00:00:01,000 --> 00:00:03,500\nBonjour\n\n2\n00:00:04,000 --> 00:00:06,000\nÀ bientôt\n"

  test "SubRip becomes WebVTT: header added, decimal comma replaced" do
    vtt = Subtitles.to_vtt("episode.srt", @srt)
    assert String.starts_with?(vtt, "WEBVTT")
    assert vtt =~ "00:00:01.000 --> 00:00:03.500"
    refute vtt =~ ","
    assert vtt =~ "À bientôt"
  end

  test "WebVTT is left as it is — not given a second header" do
    vtt = "WEBVTT\n\n00:00:01.000 --> 00:00:02.000\nhi\n"
    assert Subtitles.to_vtt("a.vtt", vtt) == vtt
    # decided by the content, not the name: a .srt that is really WebVTT
    assert Subtitles.to_vtt("misnamed.srt", vtt) == vtt
  end

  test "ASS keeps its dialogue lines and loses the styling" do
    ass = """
    [Events]
    Format: Layer, Start, End, Style, Name, MarginL, MarginR, MarginV, Effect, Text
    Dialogue: 0,0:00:01.00,0:00:03.50,Default,,0,0,0,,{\\an8}Bonjour\\Nle monde
    """

    vtt = Subtitles.to_vtt("episode.ASS", ass)
    assert vtt =~ "00:00:01.000 --> 00:00:03.500"
    assert vtt =~ "Bonjour\nle monde"
    refute vtt =~ "an8"
  end

  describe "encodings" do
    test "UTF-8 with a byte-order mark" do
      assert Subtitles.to_vtt("a.srt", <<0xEF, 0xBB, 0xBF>> <> @srt) =~ "À bientôt"
    end

    test "Latin-1, as older French subtitle files are" do
      latin1 = :unicode.characters_to_binary(@srt, :utf8, :latin1)
      refute String.valid?(latin1)
      # Laev 0.1.55's guess read this short Western file as Shift-JIS (a lone 0xC0 is a
      # half-width katakana there); 0.1.56 fixed the walk, so laev is trusted again.
      assert Subtitles.to_vtt("a.srt", latin1) =~ "À bientôt"
    end

    test "a real Shift-JIS file is detected and converted" do
      # こんにちは in Shift-JIS: every high byte in a pair.
      sjis = <<0x82, 0xB1, 0x82, 0xF1, 0x82, 0xC9, 0x82, 0xBF, 0x82, 0xCD>>
      body = "1\n00:00:01,000 --> 00:00:02,000\n" <> sjis <> "\n"
      assert Subtitles.to_vtt("a.srt", body) =~ "こんにちは"
    end

    test "UTF-16, either byte order" do
      le = <<0xFF, 0xFE>> <> :unicode.characters_to_binary(@srt, :utf8, {:utf16, :little})
      be = <<0xFE, 0xFF>> <> :unicode.characters_to_binary(@srt, :utf8, {:utf16, :big})
      assert Subtitles.to_vtt("a.srt", le) =~ "À bientôt"
      assert Subtitles.to_vtt("a.srt", be) =~ "À bientôt"
    end

    test "a truncated UTF-16 file does not crash" do
      assert is_binary(Subtitles.to_vtt("a.srt", <<0xFF, 0xFE, 0x31>>))
    end
  end
end
