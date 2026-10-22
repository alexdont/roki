defmodule Roki.Dictionary do
  @moduledoc """
  What a word on screen means, for the study player: hover a word in the subtitles and a card
  says what it is. Two public sources, no keys:

    * Japanese — Jisho (jisho.org), which also understands conjugated forms: 食べました finds
      食べる, with its reading.
    * Everything else — Wiktionary's definition API, entries in the language asked for
      (a French word's French entry, defined in English).

  Answers are shared and remembered for a day: a word is asked once, whoever hovers it.
  `{:ok, %{entries: [%{word, reading, pos, meanings}]}}` — an empty list when nothing is known;
  upstream trouble is `{:error, _}` and never remembered.
  """

  alias Roki.TTLCache

  @ttl_s 24 * 3600
  @max_len 48
  @agent "roki-ee/1.0 (+https://roki.ee; subtitle study player)"

  @langs ~w(ja fr es de it pt ru ko zh nl pl tr sv ar la)

  def lang?(lang), do: lang in @langs

  def lookup(lang, word) when is_binary(word) do
    word = word |> String.trim() |> String.slice(0, @max_len)

    cond do
      word == "" -> {:ok, %{entries: []}}
      lang not in @langs -> {:ok, %{entries: []}}
      true -> TTLCache.fetch({:dict, lang, word}, @ttl_s, fn -> fetch(lang, word) end)
    end
  end

  defp fetch("ja", word) do
    case Req.get("https://jisho.org/api/v1/search/words",
           params: [keyword: word],
           headers: [{"user-agent", @agent}],
           receive_timeout: 6_000,
           retry: false
         ) do
      {:ok, %{status: 200, body: %{"data" => data}}} when is_list(data) ->
        {:ok, %{entries: data |> Enum.take(4) |> Enum.map(&jisho_entry/1)}}

      {:ok, %{status: s}} ->
        {:error, {:jisho, s}}

      {:error, e} ->
        {:error, e}
    end
  end

  # Subtitles capitalise the first word of a sentence, so the plain lower-case word is tried
  # first (Maison → maison, "house"), then the word exactly as written (a name).
  defp fetch(lang, word) do
    [String.downcase(word), word]
    |> Enum.uniq()
    |> Enum.reduce_while({:ok, []}, fn candidate, _acc ->
      case wiktionary(lang, candidate) do
        {:ok, []} -> {:cont, {:ok, []}}
        other -> {:halt, other}
      end
    end)
    |> wrap()
  end

  defp wrap({:ok, entries}), do: {:ok, %{entries: entries}}
  defp wrap(other), do: other

  defp jisho_entry(d) do
    first = List.first(d["japanese"] || []) || %{}
    senses = Enum.take(d["senses"] || [], 3)

    %{
      word: first["word"] || first["reading"] || d["slug"],
      reading: if(first["word"], do: first["reading"]),
      pos:
        senses
        |> Enum.flat_map(&(&1["parts_of_speech"] || []))
        |> Enum.reject(&(&1 == "Wikipedia definition"))
        |> Enum.uniq()
        |> Enum.take(2),
      meanings:
        for(
          s <- senses,
          d <- [Enum.take(s["english_definitions"] || [], 4)],
          d != [],
          do: Enum.join(d, "; ")
        )
    }
  end

  defp wiktionary(lang, word) do
    url =
      "https://en.wiktionary.org/api/rest_v1/page/definition/" <>
        URI.encode(word, &URI.char_unreserved?/1)

    case Req.get(url, headers: [{"user-agent", @agent}], receive_timeout: 6_000, retry: false) do
      {:ok, %{status: 200, body: %{} = body}} ->
        {:ok, (body[lang] || []) |> Enum.take(3) |> Enum.map(&wiktionary_entry(&1, word))}

      {:ok, %{status: 404}} ->
        {:ok, []}

      {:ok, %{status: s}} ->
        {:error, {:wiktionary, s}}

      {:error, e} ->
        {:error, e}
    end
  end

  defp wiktionary_entry(e, word) do
    meanings =
      (e["definitions"] || [])
      |> Enum.map(&clean(&1["definition"]))
      |> Enum.reject(&(&1 == ""))
      |> Enum.take(4)

    %{
      word: word,
      reading: nil,
      pos: [e["partOfSpeech"]] |> Enum.reject(&is_nil/1),
      meanings: meanings
    }
  end

  defp clean(nil), do: ""

  defp clean(html) do
    html
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.trim()
  end
end
