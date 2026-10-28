defmodule Roki.Manga.MangaKatana do
  @base_url "https://mangakatana.com"

  alias Guise

  def search(query) do
    url = "#{@base_url}/?search=#{URI.encode_www_form(query)}&search_by=book_name"

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
    url = "#{@base_url}/manga/#{slug}"

    case Req.get(url, headers: headers()) do
      {:ok, %{status: 200, body: body}} ->
        {:ok, parse_manga(body)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_chapter_images(slug, chapter) do
    url = "#{@base_url}/manga/#{slug}/c#{chapter}"

    case Req.get(url, headers: headers()) do
      {:ok, %{status: 200, body: body}} ->
        case Regex.run(~r/var thzq=\[([^\]]*)\]/, body) do
          [_, urls_str] ->
            urls =
              Regex.scan(~r/'([^']+)'/, urls_str)
              |> Enum.map(fn [_, url] -> url end)

            {:ok, urls}

          _ ->
            {:error, "Failed to parse chapter images"}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_search_results(html) do
    doc = Floki.parse_document!(html)

    doc
    |> Floki.find("div.item")
    |> Enum.map(fn item ->
      link = item |> Floki.find("h3.title a") |> List.first()
      img = item |> Floki.find("div.wrap_img img") |> List.first()

      href = if link, do: Floki.attribute(link, "href") |> List.first()
      title = if link, do: Floki.text(link) |> String.trim()
      cover_url = if img, do: Floki.attribute(img, "src") |> List.first()

      slug =
        if href do
          href
          |> String.replace_prefix("#{@base_url}/manga/", "")
          |> String.trim_trailing("/")
        end

      %{title: title, slug: slug, cover_url: cover_url}
    end)
    |> Enum.reject(fn r -> is_nil(r.slug) or r.slug == "" end)
  end

  defp parse_manga(html) do
    doc = Floki.parse_document!(html)

    title =
      doc
      |> Floki.find("h1.heading")
      |> Floki.text()
      |> String.trim()

    cover_url =
      doc
      |> Floki.find("div.cover img")
      |> Floki.attribute("src")
      |> List.first()

    alt_titles =
      doc
      |> Floki.find("div.alt_name")
      |> Floki.text()
      |> String.trim()
      |> case do
        "" -> nil
        text -> text
      end

    authors =
      doc
      |> Floki.find("a.author")
      |> Enum.map(&(Floki.text(&1) |> String.trim()))
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(", ")
      |> case do
        "" -> nil
        text -> text
      end

    status = extract_meta(doc, "Status:")

    genres =
      doc
      |> Floki.find("div.genres a")
      |> Enum.map(&(Floki.text(&1) |> String.trim()))
      |> Enum.reject(&(&1 == ""))

    synopsis =
      doc
      |> Floki.find("div.summary p")
      |> Floki.text()
      |> String.trim()

    chapters =
      doc
      |> Floki.find("div.chapters a[href*=\"/c\"]")
      |> Enum.map(fn a ->
        href = Floki.attribute(a, "href") |> List.first() || ""

        case Regex.run(~r{/c(.+)$}, href) do
          [_, num] -> num
          _ -> nil
        end
      end)
      |> Enum.reject(&is_nil/1)
      |> Enum.reverse()

    %{
      title: title,
      cover_url: cover_url,
      alt_titles: alt_titles,
      status: status,
      reading_direction: nil,
      reading_mode: "scroll",
      written_by: authors,
      illustrated_by: nil,
      year: nil,
      genres: genres,
      synopsis: synopsis,
      chapters: chapters,
      chapter_dates: %{}
    }
  end

  defp extract_meta(doc, label) do
    doc
    |> Floki.find("li.d-row-small")
    |> Enum.find_value(fn li ->
      label_text = li |> Floki.find("div.label") |> Floki.text() |> String.trim()

      if label_text == label do
        li |> Floki.find("div.value") |> Floki.text() |> String.trim()
      end
    end)
  end

  defp headers do
    Guise.headers("https://mangakatana.com/")
  end
end
