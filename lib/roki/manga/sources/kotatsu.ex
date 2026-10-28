defmodule Roki.Manga.Sources.Kotatsu do
  @moduledoc """
  Every parser the sidecar carries, behind one source key, exactly as the old reader had it: the
  extension and the series are both carried in the slug, so a series can never exist here under
  two names.

      "WEEBCENTRAL~" <> Base.url_encode64(the parser's own url)

  Chapters are number strings ("85", "10.5") here and objects with opaque urls there, so the
  details fetch keeps a number-to-url index beside them — which is also why it is cached: the
  page fetch needs that index to find the chapter again.
  """
  alias Roki.Manga.Sidecar
  alias Roki.TTLCache

  @details_ttl 1800

  @doc "The slug for a series: the parser's name and its own url for it."
  def build_slug(name, url) when is_binary(name) and is_binary(url),
    do: name <> "~" <> Base.url_encode64(url, padding: false)

  @doc "The parser and url back out of a slug, or `:error`."
  def parse_slug(slug) when is_binary(slug) do
    with [name | rest] when rest != [] <- String.split(slug, "~", parts: 3),
         {:ok, url} <- Base.url_decode64(hd(rest), padding: false) do
      {:ok, name, url}
    else
      _ -> :error
    end
  end

  def parse_slug(_), do: :error

  @doc "A series: title, cover, chapters in reading order."
  def get_manga(slug) do
    with {:ok, name, url} <- parse_slug(slug),
         {:ok, manga, index} <- details(name, url) do
      {:ok,
       %{
         title: manga["title"] || "",
         cover_url: Sidecar.image_url(name, manga["coverUrl"]),
         synopsis: manga["description"],
         genres: manga["tags"] || [],
         chapters: Enum.map(index, &elem(&1, 0))
       }}
    else
      :error -> {:error, "not a kotatsu slug"}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc "A chapter's pages, as addresses this server may fetch."
  def get_chapter_images(slug, chapter) do
    with {:ok, name, url} <- parse_slug(slug),
         {:ok, _manga, index} <- details(name, url),
         {_number, chapter_url} <- List.keyfind(index, chapter, 0) || :no_chapter,
         {:ok, pages} <- Sidecar.pages(name, chapter_url) do
      {:ok, for(p <- pages, do: Sidecar.image_url(name, p["imageUrl"]))}
    else
      :error -> {:error, "not a kotatsu slug"}
      :no_chapter -> {:error, "no such chapter"}
      {:error, reason} -> {:error, reason}
    end
  end

  # The details and the number-to-url index together, kept for half an hour: the page fetch
  # cannot find a chapter without the index, so caching one without the other would be useless.
  defp details(name, url) do
    TTLCache.fetch({:kotatsu, name, url}, @details_ttl, fn ->
      case Sidecar.manga(name, url) do
        {:ok, manga} -> {:ok, manga, index(manga)}
        {:error, reason} -> {:error, reason}
      end
    end)
    |> case do
      {:ok, manga, index} -> {:ok, manga, index}
      other -> other
    end
  end

  # Chapters as the rest of this app speaks of them. A parser may carry the same chapter several
  # times over (one per translation); the first branch seen wins, and English first when the
  # parser says which is which.
  defp index(%{"chapters" => chapters}) when is_list(chapters) do
    chapters
    |> Enum.sort_by(&(&1["branch"] not in [nil, "", "en", "English"]))
    |> Enum.reduce({[], MapSet.new()}, fn c, {acc, seen} ->
      number = number_of(c)

      if number == nil or MapSet.member?(seen, number) do
        {acc, seen}
      else
        {[{number, c["url"]} | acc], MapSet.put(seen, number)}
      end
    end)
    |> elem(0)
    |> Enum.reverse()
  end

  defp index(_), do: []

  # "12.0" reads as "12", "10.5" stays itself — the form the old reader's chapter strings take.
  defp number_of(%{"number" => n}) when is_number(n) do
    if n == trunc(n), do: Integer.to_string(trunc(n)), else: Float.to_string(n / 1)
  end

  defp number_of(%{"name" => name}) when is_binary(name) do
    case Regex.run(~r/(\d+(?:\.\d+)?)/, name) do
      [_, n] -> n
      _ -> nil
    end
  end

  defp number_of(_), do: nil
end
