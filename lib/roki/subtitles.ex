defmodule Roki.Subtitles do
  @moduledoc """
  A subtitle file, from whatever the user has, as WebVTT — the one format the study
  sidebar reads.

  The conversions themselves are laev's (`Laev.Subtitles`: SubRip and ASS/SSA to
  WebVTT). This adds the part a file upload needs first: working out the text
  encoding. Subtitle files in the wild are UTF-8 (usually), UTF-8 with a byte-order
  mark, UTF-16, or Latin-1/Windows-1252 for French and other Western languages; a
  file that is none of the Unicode ones is read as Latin-1, which is right for French
  and wrong for, say, Shift-JIS Japanese (those need a proper encoding detector).
  """

  @doc "Convert an uploaded subtitle file to WebVTT, by its content and then its name."
  def to_vtt(name, content) when is_binary(name) and is_binary(content) do
    text = to_utf8(content)

    cond do
      String.starts_with?(text, "WEBVTT") -> text
      ass?(name) -> Laev.Subtitles.ass_to_vtt(text)
      true -> Laev.Subtitles.srt_to_vtt(text)
    end
  end

  defp ass?(name), do: name |> String.downcase() |> String.ends_with?([".ass", ".ssa"])

  # UTF-8 as is, a BOM dropped; UTF-16 by its BOM; else Latin-1.
  defp to_utf8(<<0xFF, 0xFE, rest::binary>>), do: utf16(rest, :little)
  defp to_utf8(<<0xFE, 0xFF, rest::binary>>), do: utf16(rest, :big)
  defp to_utf8(<<0xEF, 0xBB, 0xBF, rest::binary>>), do: to_utf8(rest)

  defp to_utf8(content) do
    if String.valid?(content),
      do: content,
      else: :unicode.characters_to_binary(content, :latin1, :utf8)
  end

  defp utf16(bytes, endianness) do
    case :unicode.characters_to_binary(bytes, {:utf16, endianness}, :utf8) do
      text when is_binary(text) -> text
      _ -> ""
    end
  end
end
