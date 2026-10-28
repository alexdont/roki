defmodule Roki.Manga.Atsumaru do
  @base_url "https://atsu.moe"

  alias Guise

  def search(query) do
    params =
      URI.encode_query(%{
        "q" => query,
        "query_by" => "title,englishTitle,otherNames,authors",
        "query_by_weights" => "4,3,2,1",
        "include_fields" => "id,title,englishTitle,poster,posterSmall,posterMedium,type,isAdult,status,year",
        "limit" => "12",
        "num_typos" => "4,3,2,1"
      })

    url = "#{@base_url}/collections/manga/documents/search?#{params}"

    case Req.get(url, headers: headers()) do
      {:ok, %{status: 200, body: body}} ->
        data = decode(body)

        results =
          (data["hits"] || [])
          |> Enum.map(fn hit ->
            doc = hit["document"]

            %{
              title: doc["title"] || doc["englishTitle"],
              slug: doc["id"],
              cover_url: poster_url(doc["posterMedium"] || doc["poster"])
            }
          end)
          |> Enum.reject(fn r -> is_nil(r.slug) or r.slug == "" end)

        {:ok, results}

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
        case extract_manga_data(body) do
          nil -> {:error, "Failed to parse manga data"}
          data -> {:ok, parse_manga(data)}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_chapter_images(slug, chapter_number) do
    case fetch_all_chapters(slug) do
      {:ok, chapters} ->
        case find_chapter_by_number(chapters, chapter_number) do
          nil ->
            {:error, "Chapter not found"}

          chapter ->
            page_count = chapter["pageCount"] || 0
            chapter_id = chapter["id"]

            urls =
              Enum.map(0..(page_count - 1), fn page ->
                "#{@base_url}/static/pages/#{slug}/#{chapter_id}/#{page}.webp"
              end)

            {:ok, urls}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp find_chapter_by_number(chapters, number_str) do
    Enum.find(chapters, fn ch -> chapter_number_string(ch) == number_str end)
  end

  defp fetch_all_chapters(slug) do
    url = "#{@base_url}/api/manga/allChapters?mangaId=#{slug}"

    case Req.get(url, headers: headers()) do
      {:ok, %{status: 200, body: body}} ->
        data = decode(body)
        {:ok, data["chapters"] || []}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_manga_data(html) do
    case Regex.run(~r/window\.mangaPage\s*=\s*(\{.*?\});\s*\n/s, html) do
      [_, json] ->
        case Jason.decode(json) do
          {:ok, %{"mangaPage" => data}} -> data
          {:ok, data} -> data
          _ -> nil
        end

      _ ->
        nil
    end
  end

  defp parse_manga(data) do
    chapters =
      if data["hasMoreChapters"] do
        case fetch_all_chapters(data["id"]) do
          {:ok, all} -> all
          _ -> data["chapters"] || []
        end
      else
        data["chapters"] || []
      end

    chapter_numbers =
      chapters
      |> Enum.sort_by(& &1["number"])
      |> Enum.map(&chapter_number_string/1)
      |> Enum.uniq()

    type = data["type"]

    %{
      title: data["title"] || data["englishTitle"],
      cover_url: poster_url(data["poster"]["largeImage"] || data["poster"]["image"]),
      alt_titles: format_alt_titles(data["otherNames"]),
      status: data["status"],
      reading_direction: type,
      reading_mode: detect_reading_mode(type),
      written_by: format_authors(data["authors"]),
      illustrated_by: nil,
      year: if(data["released"], do: to_string(DateTime.from_unix!(div(data["released"], 1000)).year)),
      genres: Enum.map(data["genres"] || [], & &1["name"]),
      synopsis: data["synopsis"] || "",
      chapters: chapter_numbers,
      chapter_dates: build_chapter_dates(chapters)
    }
  end

  defp detect_reading_mode(type) when type in ["Manwha", "Manhua"], do: "scroll"
  defp detect_reading_mode(_), do: "paged"

  defp format_alt_titles(nil), do: nil
  defp format_alt_titles([]), do: nil
  defp format_alt_titles(names), do: Enum.join(names, "; ")

  defp format_authors(nil), do: nil
  defp format_authors([]), do: nil

  defp format_authors(authors) do
    authors
    |> Enum.map(fn
      %{"name" => name} -> name
      name when is_binary(name) -> name
      _ -> nil
    end)
    |> Enum.reject(&is_nil/1)
    |> Enum.join(", ")
    |> case do
      "" -> nil
      text -> text
    end
  end

  defp chapter_number_string(ch) do
    num = ch["number"]
    if is_float(num) and num != trunc(num) do
      to_string(num)
    else
      to_string(trunc(num || 0))
    end
  end

  defp build_chapter_dates(chapters) do
    Map.new(chapters, fn ch ->
      date =
        if ch["createdAt"] do
          ch["createdAt"]
          |> div(1000)
          |> DateTime.from_unix!()
          |> DateTime.to_date()
          |> Date.to_string()
        end

      {chapter_number_string(ch), date}
    end)
  end

  defp poster_url(nil), do: nil
  defp poster_url(path) do
    if String.starts_with?(path, "/") do
      @base_url <> path
    else
      "#{@base_url}/static/#{path}"
    end
  end

  defp headers do
    Guise.headers("https://atsu.moe/")
  end

  defp decode(body) when is_map(body), do: body
  defp decode(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} -> data
      _ -> %{}
    end
  end
  defp decode(_), do: %{}
end
