defmodule Roki.Subtitles do
  @moduledoc """
  A subtitle file as WebVTT for the player — laev's converters (`Laev.Subtitles.to_vtt/2`),
  with one reading of the bytes done first.

  Laev 0.1.55 detects the encoding of a file that is not UTF-8 (`Laev.Encoding`), and its
  guess has no frequency model: a Western file with a few accents — "À bientôt" in Latin-1 —
  happens to parse as Shift-JIS (a lone 0xC0 is a half-width katakana there, and "ôt" a valid
  pair) and comes out as mojibake. What tells the two apart is shape: in Shift-JIS, EUC-JP
  and GBK almost every high byte sits in a pair with another high byte, while a French or
  Spanish accent sits alone between ASCII letters. A file whose high bytes are all alone, and
  few, is read as a single-byte Western page here before laev sees it.
  """

  @doc "The file as WebVTT: `Laev.Subtitles.to_vtt/2`, after `western/1`."
  def to_vtt(name, body) when is_binary(body), do: Laev.Subtitles.to_vtt(name, western(body))
  def to_vtt(name, body), do: Laev.Subtitles.to_vtt(name, body)

  @doc """
  Bytes that are not UTF-8 but read as a Western single-byte page — every high byte alone
  between ASCII bytes, and no more than a tenth of the text — decoded as such to UTF-8 (CP1252
  when a byte of 0x80–0x9F is there, else Latin-1), so laev takes them as the UTF-8 they now
  are. Anything else is returned as it came.
  """
  def western(body) when is_binary(body) do
    cond do
      String.valid?(body) -> body
      lone_accents?(body) -> decode_western(body)
      true -> body
    end
  end

  # No two high bytes next to each other anywhere, and high bytes at most a tenth of the file.
  defp lone_accents?(body) do
    bytes = :binary.bin_to_list(body)
    high = Enum.count(bytes, &(&1 >= 0x80))

    high > 0 and high * 10 <= length(bytes) and
      not Enum.any?(Enum.chunk_every(bytes, 2, 1, :discard), fn [a, b] ->
        a >= 0x80 and b >= 0x80
      end)
  end

  defp decode_western(body) do
    if Enum.any?(:binary.bin_to_list(body), &(&1 in 0x80..0x9F)) and
         function_exported?(Laev.Encoding, :to_utf8, 1) do
      # Laev names the page for these (CP1252: quotes, dashes, the euro) and converts it.
      case Laev.Encoding.to_utf8(body) do
        text when is_binary(text) -> if String.valid?(text), do: text, else: latin1(body)
        _ -> latin1(body)
      end
    else
      latin1(body)
    end
  end

  defp latin1(body) do
    case :unicode.characters_to_binary(body, :latin1, :utf8) do
      text when is_binary(text) -> text
      _ -> body
    end
  end
end
