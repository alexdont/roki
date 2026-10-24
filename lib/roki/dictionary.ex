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

  defp fetch(lang, word), do: lookup_candidates(lang, word)

  # What a word on screen is looked up as, most likely first. Subtitles capitalise the first word
  # of a sentence (Maison → maison), glue a small word on with an apostrophe (d'aimer, l'homme,
  # qu'il) and hang pronouns on with a hyphen (dis-moi, donne-le): the entry is for the word
  # underneath, so each of those is peeled off in turn. The word exactly as written comes last
  # (a name).
  @doc false
  def candidates(word) do
    plain =
      word
      |> String.replace("’", "'")
      |> String.replace(~r/^[^\p{L}]+|[^\p{L}]+$/u, "")

    lower = String.downcase(plain)
    unelided = lower |> String.split("'") |> List.last()
    bare = unclitic(unelided)

    [lower, unelided, bare, word]
    |> Enum.reject(&(&1 in ["", nil]))
    |> Enum.uniq()
  end

  @clitics ~w(moi toi lui le la les leur nous vous y en ci là ce il elle on ils elles je tu t-il t-elle t-on)

  defp unclitic(word) do
    case String.split(word, "-", parts: 2) do
      [base, rest] when base != "" ->
        if rest in @clitics or rest |> String.split("-") |> Enum.all?(&(&1 in @clitics)),
          do: base,
          else: word

      _ ->
        word
    end
  end

  defp lookup_candidates(lang, word) do
    candidates(word)
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
      jlpt: jlpt(d["jlpt"]),
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

  # "jlpt-n5" … "jlpt-n1": the easiest level it appears at (N5 is the first one learned).
  defp jlpt([_ | _] = levels) do
    levels
    |> Enum.flat_map(fn l ->
      case Regex.run(~r/n([1-5])/i, to_string(l)) do
        [_, n] -> [String.to_integer(n)]
        _ -> []
      end
    end)
    |> case do
      [] -> nil
      ns -> "N" <> Integer.to_string(Enum.max(ns))
    end
  end

  defp jlpt(_), do: nil

  defp wiktionary(lang, word, depth \\ 0) do
    url =
      "https://en.wiktionary.org/api/rest_v1/page/definition/" <>
        URI.encode(word, &URI.char_unreserved?/1)

    case Req.get(url, headers: [{"user-agent", @agent}], receive_timeout: 6_000, retry: false) do
      {:ok, %{status: 200, body: %{} = body}} ->
        entries = (body[lang] || []) |> Enum.take(3) |> Enum.map(&wiktionary_entry(&1, word))
        {:ok, entries |> Enum.map(&with_lemma(&1, lang, word, depth)) |> Enum.map(&finish/1)}

      {:ok, %{status: 404}} ->
        {:ok, []}

      {:ok, %{status: s}} ->
        {:error, {:wiktionary, s}}

      {:error, e} ->
        {:error, e}
    end
  end

  # One part-of-speech section. Wiktionary describes an inflected word ("aimé", "mangeons",
  # "suis") only by what form it is — "past participle of aimer" — so those definitions are kept
  # apart (`forms`) from real meanings (`plain`), and the word they point to (`lemma`) is noted.
  defp wiktionary_entry(e, word) do
    defs = e["definitions"] || []

    {form_defs, plain_defs} =
      Enum.split_with(defs, &String.contains?(&1["definition"] || "", "form-of-definition"))

    lemma =
      Enum.find_value(defs, fn d ->
        case Regex.run(
               ~r/form-of-definition-link"><i[^>]*><a [^>]*title="([^"]+)"/,
               d["definition"] || ""
             ) do
          [_, lemma] -> clean(lemma)
          _ -> nil
        end
      end)

    # A form with several readings nests them in a list under a lead-in ("inflection of
    # manger:"): the readings are the useful part, the lead-in only when nothing else is there.
    {nested, leads} =
      Enum.split_with(form_defs, &(not String.contains?(&1["definition"] || "", "<ol")))

    forms =
      case nested do
        [] -> Enum.map(leads, &(&1["definition"] |> clean() |> String.split(":") |> hd()))
        _ -> Enum.map(nested, &clean(&1["definition"]))
      end

    %{
      word: word,
      reading: nil,
      pos: [e["partOfSpeech"]] |> Enum.reject(&is_nil/1),
      plain:
        plain_defs
        |> Enum.map(&clean(&1["definition"]))
        |> Enum.reject(&(&1 == ""))
        |> Enum.take(4),
      forms: forms |> Enum.reject(&(&1 == "")) |> Enum.uniq() |> Enum.take(3),
      lemma: if(lemma && String.downcase(lemma) != String.downcase(word), do: lemma)
    }
  end

  # An inflected form gets what the word it comes from means — the part someone reading a
  # subtitle wants — ahead of the grammar.
  defp with_lemma(%{lemma: lemma, forms: [_ | _]} = entry, lang, _word, 0)
       when is_binary(lemma) do
    gloss =
      case TTLCache.fetch({:dict_lemma, lang, lemma}, @ttl_s, fn ->
             lemma_gloss(lang, lemma, entry.pos)
           end) do
        {:ok, text} when is_binary(text) -> text
        _ -> nil
      end

    %{entry | plain: if(gloss, do: ["#{lemma}: #{gloss}"], else: []) ++ entry.plain}
  end

  defp with_lemma(entry, _lang, _word, _depth), do: entry

  defp lemma_gloss(lang, lemma, pos) do
    with {:ok, entries} <- wiktionary(lang, lemma, 1) do
      glossed = Enum.reject(entries, &(&1.meanings == []))
      pick = Enum.find(glossed, &(&1.pos == pos)) || List.first(glossed)

      {:ok,
       pick &&
         pick.meanings
         |> Enum.map(&String.slice(&1, 0, 70))
         |> Enum.uniq()
         |> Enum.take(2)
         |> Enum.join("; ")}
    end
  end

  defp finish(%{plain: plain, forms: forms} = entry) do
    entry
    |> Map.drop([:plain, :forms, :lemma])
    |> Map.put(:meanings, Enum.take(plain ++ forms, 4))
  end

  defp clean(nil), do: ""

  defp clean(html) do
    html
    |> String.replace(~r/<style.*?<\/style>/s, "")
    |> String.replace(~r/<[^>]*>/, "")
    |> String.replace("presubject ", "")
    |> String.replace("&nbsp;", " ")
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
    |> String.trim()
  end
end
