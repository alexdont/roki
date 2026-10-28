defmodule Roki.Manga.MangaLib do
  @api_url "https://api2.mangalib.me/api"
  @img_cdn "https://img3.mixlib.me"

  alias Guise

  @doc """
  Searches MangaLib for manga matching the query.
  Returns `{:ok, [%{title, slug, cover_url}]}` or `{:error, reason}`.
  """
  def search(query) do
    url =
      "https://api.cdnlibs.org/api/manga?q=#{URI.encode_www_form(query)}&site_id[]=1&fields[]=rate_avg&fields[]=rate&fields[]=releaseDate"

    case Req.get(url, headers: Guise.headers("https://mangalib.me/")) do
      {:ok, %{status: 200, body: body}} ->
        case decode(body) do
          {:ok, %{"data" => data}} when is_list(data) ->
            results =
              Enum.map(data, fn item ->
                title = item["eng_name"] || item["rus_name"] || item["name"]
                slug = item["slug_url"]
                cover_url = get_in(item, ["cover", "default"])

                %{title: title, slug: slug, cover_url: cover_url}
              end)
              |> Enum.reject(fn r -> is_nil(r.slug) or r.slug == "" end)

            {:ok, results}

          _ ->
            {:ok, []}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  def get_manga(slug_url) do
    url = "#{@api_url}/manga/#{slug_url}?fields[]=summary&fields[]=genres&fields[]=authors"

    with {:ok, %{status: 200, body: body}} <-
           Req.get(url, headers: Guise.headers("https://mangalib.me/")),
         {:ok, %{"data" => data}} <- decode(body) do
      chapters_url = "#{@api_url}/manga/#{slug_url}/chapters"

      chapters =
        case Req.get(chapters_url, headers: Guise.headers("https://mangalib.me/")) do
          {:ok, %{status: 200, body: ch_body}} ->
            case decode(ch_body) do
              {:ok, %{"data" => ch_list}} -> ch_list
              _ -> []
            end

          _ ->
            []
        end

      {:ok, parse_manga(data, chapters)}
    else
      {:ok, %{status: status}} -> {:error, "HTTP #{status}"}
      {:error, reason} -> {:error, reason}
    end
  end

  def get_chapter_images(slug_url, chapter_id) do
    [volume, number] = parse_chapter_id(chapter_id)
    url = "#{@api_url}/manga/#{slug_url}/chapter?number=#{number}&volume=#{volume}"

    case Req.get(url, headers: Guise.headers("https://mangalib.me/")) do
      {:ok, %{status: 200, body: body}} ->
        case decode(body) do
          {:ok, %{"data" => %{"pages" => pages}}} ->
            images =
              pages
              |> Enum.sort_by(& &1["slug"])
              |> Enum.map(fn page -> "#{@img_cdn}#{page["url"]}" end)

            {:ok, images}

          _ ->
            {:error, "Failed to parse chapter data"}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_manga(data, chapters) do
    type_label = get_in(data, ["type", "label"])

    %{
      title: data["eng_name"] || data["rus_name"] || data["name"],
      cover_url: get_in(data, ["cover", "default"]),
      alt_titles: [data["name"], data["rus_name"]] |> Enum.filter(& &1) |> Enum.join(" / "),
      status: get_in(data, ["status", "label"]),
      reading_direction: type_label,
      reading_mode: if(type_label in ["Манхва", "Маньхуа"], do: "scroll", else: "paged"),
      written_by: extract_people(data, "authors"),
      illustrated_by: nil,
      year: data["releaseDateString"],
      genres: Enum.map(data["genres"] || [], & &1["name"]),
      synopsis: data["summary"] || "",
      chapters: parse_chapters(chapters),
      chapter_dates: parse_chapter_dates(chapters)
    }
  end

  defp extract_people(data, key) do
    case data[key] do
      [_ | _] = people -> people |> Enum.map(& &1["name"]) |> Enum.join(", ")
      _ -> nil
    end
  end

  defp parse_chapters(chapters) do
    chapters
    |> Enum.map(fn ch -> "v#{ch["volume"]}-c#{ch["number"]}" end)
    |> Enum.sort_by(&chapter_sort_key/1)
  end

  defp parse_chapter_dates(chapters) do
    first_branch_date = fn ch ->
      case ch["branches"] do
        [%{"created_at" => date} | _] when is_binary(date) ->
          date |> String.slice(0, 10)

        _ ->
          nil
      end
    end

    chapters
    |> Enum.reduce(%{}, fn ch, acc ->
      key = "v#{ch["volume"]}-c#{ch["number"]}"
      date = first_branch_date.(ch)
      if date, do: Map.put(acc, key, date), else: acc
    end)
  end

  defp parse_chapter_id(chapter_id) do
    case Regex.run(~r/^v(.+)-c(.+)$/, chapter_id) do
      [_, volume, number] -> [volume, number]
      _ -> [nil, chapter_id]
    end
  end

  defp chapter_sort_key(ch), do: Chapter.sort_key(ch)

  defp decode(body) when is_map(body), do: {:ok, body}
  defp decode(body) when is_binary(body), do: Jason.decode(body)
  defp decode(_), do: {:error, "unexpected response"}
end
