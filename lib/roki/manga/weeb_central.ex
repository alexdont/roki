defmodule Roki.Manga.WeebCentral do
  @base_url "https://weebcentral.com"

  alias Guise

  def search(query) do
    params =
      URI.encode_query(%{
        "text" => query,
        "sort" => "Best Match",
        "order" => "Descending",
        "official" => "Any",
        "display_mode" => "Full Display",
        "limit" => "12",
        "offset" => "0"
      })

    url = "#{@base_url}/search/data?#{params}"

    case Req.get(url, headers: headers()) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_search_results(body)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_manga(slug) do
    url = "#{@base_url}/series/#{slug}"

    case Req.get(url, headers: headers()) do
      {:ok, %{status: 200, body: body}} ->
        case fetch_full_chapter_list(slug) do
          {:ok, chapters} ->
            {:ok, parse_manga(body, chapters)}

          {:error, _} ->
            {:ok, parse_manga(body, [])}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_chapter_images(slug, chapter_number) do
    case fetch_full_chapter_list(slug) do
      {:ok, chapters} ->
        case Enum.find(chapters, fn {num, _id} -> num == chapter_number end) do
          nil ->
            {:error, "Chapter not found"}

          {_num, chapter_id} ->
            fetch_chapter_images(chapter_id)
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_chapter_images(chapter_id) do
    url = "#{@base_url}/chapters/#{chapter_id}/images?is_prev=False&current_page=1&reading_style=long_strip"

    case Req.get(url, headers: headers()) do
      {:ok, %{status: 200, body: body}} ->
        doc = Floki.parse_document!(body)

        images =
          doc
          |> Floki.find("img")
          |> Enum.flat_map(fn img -> Floki.attribute(img, "src") end)
          |> Enum.filter(&String.starts_with?(&1, "http"))

        {:ok, images}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp fetch_full_chapter_list(series_id) do
    url = "#{@base_url}/series/#{series_id}/full-chapter-list"

    case Req.get(url, headers: headers()) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_chapter_list(body)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_search_results(html) do
    doc = Floki.parse_document!(html)

    doc
    |> Floki.find("a[href*=\"/series/\"]")
    |> Enum.map(fn a ->
      href = Floki.attribute(a, "href") |> List.first() || ""
      img = Floki.find(a, "img") |> List.first()

      slug =
        case Regex.run(~r{/series/([A-Z0-9]+)}, href) do
          [_, id] -> id
          _ -> nil
        end

      cover_url = if img, do: Floki.attribute(img, "src") |> List.first()

      title =
        if img do
          alt = Floki.attribute(img, "alt") |> List.first() || ""
          String.replace(alt, ~r/\s*cover$/, "")
        end

      %{title: title, slug: slug, cover_url: cover_url}
    end)
    |> Enum.reject(fn r -> is_nil(r.slug) or r.slug == "" or is_nil(r.title) or r.title == "" end)
    |> Enum.uniq_by(& &1.slug)
  end

  defp parse_manga(html, chapters) do
    doc = Floki.parse_document!(html)

    title =
      doc
      |> Floki.find("title")
      |> Floki.text()
      |> String.replace(~r/\s*\|\s*Weeb Central$/, "")
      |> String.trim()

    cover_url =
      doc
      |> Floki.find("meta[property=\"og:image\"]")
      |> Floki.attribute("content")
      |> List.first()

    synopsis =
      doc
      |> Floki.find("p.whitespace-pre-wrap")
      |> List.first()
      |> case do
        nil -> ""
        p -> Floki.text(p) |> String.trim()
      end

    type = extract_meta_link(doc, "Type:")
    status = extract_meta_link(doc, "Status:")
    authors = extract_meta_links(doc, "Author(s):")
    year =
      doc
      |> Floki.find("span")
      |> Enum.find_value(fn span ->
        text = Floki.text(span) |> String.trim()
        if Regex.match?(~r/^\d{4}$/, text), do: text
      end)

    genres =
      doc
      |> Floki.find("a[href*=\"included_tag=\"]")
      |> Enum.map(fn a -> Floki.text(a) |> String.trim() end)
      |> Enum.reject(&(&1 == ""))

    # chapters is a list of {chapter_number_string, chapter_id}
    chapter_numbers = Enum.map(chapters, fn {num, _id} -> num end)

    %{
      title: title,
      cover_url: cover_url,
      alt_titles: nil,
      status: status,
      reading_direction: type,
      reading_mode: detect_reading_mode(type),
      written_by: if(authors != [], do: Enum.join(authors, ", ")),
      illustrated_by: nil,
      year: year,
      genres: genres,
      synopsis: synopsis,
      chapters: chapter_numbers,
      chapter_dates: %{}
    }
  end

  defp parse_chapter_list(html) do
    doc = Floki.parse_document!(html)

    doc
    |> Floki.find("a[href*=\"/chapters/\"]")
    |> Enum.map(fn a ->
      href = Floki.attribute(a, "href") |> List.first() || ""

      chapter_id =
        case Regex.run(~r{/chapters/([A-Z0-9]+)}, href) do
          [_, id] -> id
          _ -> nil
        end

      chapter_name =
        a
        |> Floki.find("span")
        |> Enum.find_value(fn span ->
          text = Floki.text(span) |> String.trim()
          case Regex.run(~r/^Chapter\s+(.+)$/, text) do
            [_, num] -> num
            _ -> nil
          end
        end)

      {chapter_name, chapter_id}
    end)
    |> Enum.reject(fn {name, id} -> is_nil(name) or is_nil(id) end)
    |> Enum.reverse()
  end

  defp detect_reading_mode(type) when is_binary(type) do
    t = String.downcase(type)
    if t in ["manhwa", "manhua"], do: "scroll", else: "paged"
  end
  defp detect_reading_mode(_), do: "paged"

  defp extract_meta_link(doc, label) do
    doc
    |> Floki.find("li")
    |> Enum.find_value(fn li ->
      strong_text =
        li |> Floki.find("strong") |> Floki.text() |> String.trim()

      if strong_text == label do
        li |> Floki.find("a") |> List.first() |> then(fn
          nil -> nil
          a -> Floki.text(a) |> String.trim()
        end)
      end
    end)
  end

  defp extract_meta_links(doc, label) do
    doc
    |> Floki.find("li")
    |> Enum.find_value([], fn li ->
      strong_text =
        li |> Floki.find("strong") |> Floki.text() |> String.trim()

      if strong_text == label do
        li
        |> Floki.find("a")
        |> Enum.map(fn a -> Floki.text(a) |> String.trim() end)
        |> Enum.reject(&(&1 == ""))
      end
    end)
  end

  defp headers do
    Guise.headers("https://weebcentral.com/")
  end
end
