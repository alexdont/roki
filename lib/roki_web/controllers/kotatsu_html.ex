defmodule RokiWeb.KotatsuHTML do
  use RokiWeb, :html

  embed_templates "kotatsu_html/*"

  @doc "App-facing proxied image URL for a kotatsu source image."
  def kotatsu_image(source, url) when is_binary(url) and url != "" do
    ~p"/manga/kotatsu/image?#{%{source: source, url: url}}"
  end

  def kotatsu_image(_source, _url), do: nil

  @doc "Group the source catalog by locale, English first, multilingual last."
  def sources_by_locale(sources) do
    sources
    |> Enum.group_by(& &1.locale)
    |> Enum.sort_by(fn
      {"en", _} -> {0, ""}
      {"", _} -> {2, ""}
      {locale, _} -> {1, locale}
    end)
    |> Enum.map(fn {locale, list} -> {locale_label(locale), Enum.sort_by(list, & &1.title)} end)
  end

  defp locale_label(""), do: "Multilingual"

  defp locale_label(code) do
    names = %{
      "en" => "English",
      "fr" => "French",
      "es" => "Spanish",
      "de" => "German",
      "it" => "Italian",
      "pt" => "Portuguese",
      "ru" => "Russian",
      "ja" => "Japanese",
      "zh" => "Chinese",
      "ko" => "Korean",
      "id" => "Indonesian",
      "vi" => "Vietnamese",
      "th" => "Thai",
      "ar" => "Arabic",
      "tr" => "Turkish",
      "pl" => "Polish",
      "uk" => "Ukrainian",
      "nl" => "Dutch",
      "be" => "Belarusian",
      "cs" => "Czech",
      "hi" => "Hindi",
      "ta" => "Tamil",
      "my" => "Burmese",
      "fil" => "Filipino"
    }

    Map.get(names, code, String.upcase(code))
  end

  @doc "Source descriptions may carry site HTML — reduce to plain text."
  def description_text(nil), do: nil

  def description_text(html) do
    html
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace(~r/&nbsp;/, " ")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.trim()
  end

  @doc "Human chapter label."
  def chapter_label(ch) do
    cond do
      ch.title not in [nil, ""] and ch.number > 0 -> "#{format_number(ch.number)} · #{ch.title}"
      ch.title not in [nil, ""] -> ch.title
      ch.number > 0 -> "Chapter #{format_number(ch.number)}"
      true -> "Unnamed chapter"
    end
  end

  defp format_number(n) do
    if n == trunc(n), do: Integer.to_string(trunc(n)), else: Float.to_string(n)
  end
end
