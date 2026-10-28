defmodule Roki.Manga.MangaFire do
  @base_url "https://mangafire.to"

  alias Guise

  @doc """
  Searches MangaFire for manga matching the query.
  Returns `{:ok, [%{title, slug, cover_url}]}` or `{:error, reason}`.
  """
  def search(query) do
    with {:ok, vrf} <- get_vrf(query) do
      url = "#{@base_url}/ajax/manga/search?keyword=#{URI.encode_www_form(query)}&vrf=#{URI.encode_www_form(vrf)}"

      case Req.get(url, headers: ajax_headers()) do
        {:ok, %{status: 200, body: body}} ->
          case decode(body) do
            {:ok, %{"status" => 200, "result" => %{"html" => html}}} ->
              {:ok, parse_search_results(html)}

            _ ->
              {:ok, []}
          end

        {:ok, %{status: status}} ->
          {:error, "HTTP #{status}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Fetches full manga info: title, cover, metadata, genres, synopsis, and chapters.
  """
  def get_manga(slug) do
    case Req.get("#{@base_url}/manga/#{slug}", headers: headers()) do
      {:ok, %{status: 200, body: body}} ->
        doc = Floki.parse_document!(body)
        hash_id = extract_hash_id(slug)
        chapters_data = fetch_chapter_list(hash_id)
        {:ok, parse_manga_detail(doc, chapters_data)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches image URLs for a specific chapter.
  """
  def get_chapter_images(slug, chapter_id) do
    hash_id = extract_hash_id(slug)

    with {:ok, data_id} <- get_chapter_data_id(hash_id, chapter_id),
         {:ok, vrf} <- get_vrf("chapter@#{data_id}") do
      url = "#{@base_url}/ajax/read/chapter/#{data_id}?vrf=#{URI.encode_www_form(vrf)}"

      case Req.get(url, headers: ajax_headers()) do
        {:ok, %{status: 200, body: body}} ->
          case decode(body) do
            {:ok, %{"status" => 200, "result" => %{"images" => images}}} ->
              urls =
                Enum.map(images, fn
                  [url, _, offset] when is_integer(offset) and offset > 0 ->
                    "#{url}#scrambled_#{offset}"

                  [url | _] ->
                    url
                end)

              {:ok, urls}

            _ ->
              {:error, "Failed to parse chapter images response"}
          end

        {:ok, %{status: status}} ->
          {:error, "HTTP #{status}"}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  # --- VRF Generation ---

  defp get_vrf(input) do
    url = "http://127.0.0.1:4100/?input=#{URI.encode_www_form(input)}"

    case Req.get(url, receive_timeout: 30_000) do
      {:ok, %{status: 200, body: %{"vrf" => vrf}}} ->
        {:ok, vrf}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"vrf" => vrf}} -> {:ok, vrf}
          _ -> {:error, "VRF server returned unexpected response"}
        end

      {:ok, %{status: status, body: body}} ->
        error = if is_map(body), do: body["error"], else: body
        {:error, "VRF server error (#{status}): #{error}"}

      {:error, reason} ->
        {:error, "VRF server unreachable: #{inspect(reason)}"}
    end
  end

  # --- Chapter List ---

  defp fetch_chapter_list(hash_id) do
    Roki.Manga.Cache.fetch({:mangafire_chapters, hash_id}, :timer.hours(1), fn ->
      fetch_chapter_list_uncached(hash_id)
    end)
  end

  defp fetch_chapter_list_uncached(hash_id) do
    case get_vrf("#{hash_id}@chapter@en") do
      {:ok, vrf} ->
        url = "#{@base_url}/ajax/read/#{hash_id}/chapter/en?vrf=#{URI.encode_www_form(vrf)}"

        case Req.get(url, headers: ajax_headers()) do
          {:ok, %{status: 200, body: body}} ->
            case decode(body) do
              {:ok, %{"status" => 200, "result" => %{"html" => html}}} ->
                parse_chapter_list_html(html)

              _ ->
                {[], %{}}
            end

          _ ->
            {[], %{}}
        end

      _ ->
        {[], %{}}
    end
  end

  defp parse_chapter_list_html(html) do
    doc = Floki.parse_document!(html)

    items =
      doc
      |> Floki.find("a[data-number]")
      |> Enum.map(fn a ->
        number = Floki.attribute(a, "data-number") |> List.first()
        data_id = Floki.attribute(a, "data-id") |> List.first()
        {number, data_id}
      end)
      |> Enum.reject(fn {n, d} -> is_nil(n) or is_nil(d) end)

    chapters =
      items
      |> Enum.map(fn {number, _} -> number end)
      |> Enum.sort_by(&chapter_sort_key/1)

    id_map = Map.new(items)

    {chapters, id_map}
  end

  defp get_chapter_data_id(hash_id, chapter_id) do
    {_chapters, id_map} = fetch_chapter_list(hash_id)

    case Map.get(id_map, to_string(chapter_id)) do
      nil -> {:error, "Chapter #{chapter_id} not found in chapter list"}
      data_id -> {:ok, data_id}
    end
  end

  # --- Parsing ---

  defp parse_search_results(html) do
    doc = Floki.parse_document!(html)

    doc
    |> Floki.find("a.unit")
    |> Enum.map(fn a ->
      href = Floki.attribute(a, "href") |> List.first()
      img = Floki.find(a, "img") |> List.first()
      title = Floki.find(a, "h6") |> Floki.text() |> String.trim()
      cover_url = if img, do: Floki.attribute(img, "src") |> List.first()

      slug =
        if href do
          href
          |> String.replace_prefix("/manga/", "")
          |> String.trim_trailing("/")
        end

      %{title: title, slug: slug, cover_url: cover_url}
    end)
    |> Enum.reject(fn r -> is_nil(r.slug) or r.slug == "" end)
  end

  defp parse_manga_detail(doc, {chapters, _id_map}) do
    type =
      doc
      |> Floki.find(".min-info a")
      |> List.first()
      |> case do
        nil -> nil
        el -> Floki.text(el) |> String.trim()
      end

    %{
      title:
        doc
        |> Floki.find("h1")
        |> Floki.text()
        |> String.trim(),
      cover_url:
        doc
        |> Floki.find(".poster img")
        |> Floki.attribute("src")
        |> List.first(),
      alt_titles:
        doc
        |> Floki.find("h6")
        |> Floki.text()
        |> String.trim()
        |> case do
          "" -> nil
          text -> text
        end,
      status:
        doc
        |> Floki.find(".info p")
        |> Floki.text()
        |> String.trim()
        |> case do
          "" -> nil
          text -> text
        end,
      reading_direction: type,
      reading_mode: detect_reading_mode(type),
      written_by: extract_meta(doc, "Author:"),
      illustrated_by: nil,
      year: extract_meta(doc, "Published:"),
      genres:
        doc
        |> Floki.find(".meta a[href*=\"/genre/\"]")
        |> Enum.map(fn el -> el |> Floki.text() |> String.trim() end)
        |> Enum.reject(&(&1 == "")),
      synopsis:
        doc
        |> Floki.find(".description")
        |> Floki.text()
        |> String.trim(),
      chapters: chapters,
      chapter_dates: %{}
    }
  end

  defp detect_reading_mode(nil), do: "paged"

  defp detect_reading_mode(type) do
    if type in ["Manhwa", "Manhua"] do
      "scroll"
    else
      "paged"
    end
  end

  defp extract_meta(doc, label) do
    doc
    |> Floki.find(".meta > div")
    |> Enum.find_value(fn div ->
      spans = Floki.find(div, "span")

      case spans do
        [label_span | rest] ->
          label_text = Floki.text(label_span) |> String.trim()

          if label_text == label and rest != [] do
            rest
            |> Enum.map(&Floki.text/1)
            |> Enum.join("")
            |> String.trim()
            |> case do
              "" -> nil
              text -> text
            end
          end

        _ ->
          nil
      end
    end)
  end

  defp extract_hash_id(slug) do
    slug |> String.split(".") |> List.last()
  end

  defp chapter_sort_key(ch), do: Chapter.sort_key(ch)

  defp headers do
    Guise.headers("https://mangafire.to/")
  end

  defp ajax_headers do
    headers() ++ [{"x-requested-with", "XMLHttpRequest"}]
  end

  defp decode(body) when is_map(body), do: {:ok, body}
  defp decode(body) when is_binary(body), do: Jason.decode(body)
  defp decode(_), do: {:error, "unexpected response"}
end
