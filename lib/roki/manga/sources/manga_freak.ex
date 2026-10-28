defmodule Roki.Manga.Sources.MangaFreak do
  @base_url "https://ww2.mangafreak.me"

  alias Guise

  @doc """
  Fetches full manga info: title, cover, metadata, genres, synopsis, and chapters.
  """
  def get_manga(manga_slug) do
    url = "#{@base_url}/Manga/#{manga_slug}"

    case Req.get(url, headers: Guise.headers("https://ww2.mangafreak.me/")) do
      {:ok, %{status: 200, body: body}} ->
        doc = Floki.parse_document!(body)
        {:ok, parse_manga(doc, manga_slug)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_manga(doc, manga_slug) do
    data_div = Floki.find(doc, ".manga_series_data")
    divs = Floki.find(data_div, "> div")
    direction = extract_field(divs, "Type:")

    %{
      title: doc |> Floki.find("h1") |> Floki.text() |> String.trim(),
      cover_url:
        doc
        |> Floki.find(".manga_series_image img")
        |> Floki.attribute("src")
        |> List.first(),
      alt_titles: extract_field(divs, "Alternative Title:"),
      status: extract_field(divs, "This is"),
      reading_direction: direction,
      reading_mode: detect_reading_mode(direction),
      written_by: extract_field(divs, "Written By:"),
      illustrated_by: extract_field(divs, "Illustrated By:"),
      year: extract_field(divs, "Year Published:"),
      genres:
        doc
        |> Floki.find(".series_sub_genre_list a")
        |> Enum.map(&Floki.text/1),
      synopsis:
        doc
        |> Floki.find(".manga_series_description p")
        |> Floki.text()
        |> String.trim(),
      chapters: extract_chapters(doc, manga_slug),
      chapter_dates: extract_chapter_dates(doc, manga_slug)
    }
  end

  defp detect_reading_mode(nil), do: "paged"

  defp detect_reading_mode(direction) do
    if String.contains?(direction, "Left") do
      "scroll"
    else
      "paged"
    end
  end

  defp extract_field(divs, prefix) do
    divs
    |> Enum.find_value(fn div ->
      text = Floki.text(div) |> String.trim()
      if String.starts_with?(text, prefix), do: text
    end)
  end

  defp extract_chapters(doc, manga_slug) do
    prefix = "/Read1_#{manga_slug}_"

    doc
    |> Floki.find("a")
    |> Floki.attribute("href")
    |> Enum.filter(&String.starts_with?(&1, prefix))
    |> Enum.map(fn href ->
      href |> String.replace_prefix(prefix, "")
    end)
    |> Enum.uniq()
    |> Enum.sort_by(&chapter_sort_key/1)
  end

  defp extract_chapter_dates(doc, manga_slug) do
    prefix = "/Read1_#{manga_slug}_"

    doc
    |> Floki.find(".manga_series_list table tr")
    |> Enum.reduce(%{}, fn tr, acc ->
      tds = Floki.find(tr, "td")

      case tds do
        [link_td, date_td] ->
          href = link_td |> Floki.find("a") |> Floki.attribute("href") |> List.first()
          date = Floki.text(date_td) |> String.trim()

          if href && String.starts_with?(href, prefix) do
            chapter_id = String.replace_prefix(href, prefix, "")
            Map.put(acc, chapter_id, date)
          else
            acc
          end

        _ ->
          acc
      end
    end)
  end

  defp chapter_sort_key(ch), do: Chapter.sort_key(ch)

  @doc """
  Searches MangaFreak for manga matching the query.
  Returns `{:ok, [%{title, slug, cover_url}]}` or `{:error, reason}`.
  """
  def search(query) do
    url = "#{@base_url}/Find/#{URI.encode(query)}"

    case Req.get(url, headers: Guise.headers("https://ww2.mangafreak.me/")) do
      {:ok, %{status: 200, body: body}} ->
        doc = Floki.parse_document!(body)

        results =
          doc
          |> Floki.find(".manga_search_item")
          |> Enum.map(fn item ->
            title_link = Floki.find(item, "h3 a") |> List.first()
            img = Floki.find(item, "img") |> List.first()

            href = if title_link, do: Floki.attribute(title_link, "href") |> List.first()
            title = if title_link, do: Floki.text(title_link) |> String.trim()
            cover_url = if img, do: Floki.attribute(img, "src") |> List.first()

            slug =
              if href do
                href
                |> String.replace_prefix("/Manga/", "")
                |> String.trim_trailing("/")
              end

            %{title: title, slug: slug, cover_url: cover_url}
          end)
          |> Enum.reject(fn r -> is_nil(r.slug) or r.slug == "" end)

        {:ok, results}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches image URLs for a specific chapter by parsing the reader page.
  """
  def get_chapter_images(manga_slug, chapter_id) do
    url = "#{@base_url}/Read1_#{manga_slug}_#{chapter_id}"

    case Req.get(url, headers: Guise.headers("https://ww2.mangafreak.me/")) do
      {:ok, %{status: 200, body: body}} ->
        images =
          body
          |> Floki.parse_document!()
          |> Floki.find("img")
          |> Floki.attribute("src")
          |> Enum.filter(&String.contains?(&1, "images.mangafreak.me"))

        {:ok, images}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end
end
