defmodule Roki.Manga.Sources.Remanga do
  @base_url "https://api.remanga.org"
  @site_url "https://remanga.org"
  @media_url "https://remanga.org/media/"

  alias Guise

  @doc """
  Searches Remanga for manga matching the query.
  Returns `{:ok, [%{title, slug, cover_url}]}` or `{:error, reason}`.
  """
  def search(query) do
    url = "#{@base_url}/api/search/?query=#{URI.encode_www_form(query)}&count=20"

    case Req.get(url, headers: headers()) do
      {:ok, %{status: 200, body: %{"content" => items}}} when is_list(items) ->
        results =
          Enum.map(items, fn item ->
            %{
              title: item["main_name"],
              slug: item["dir"],
              cover_url: media_url(item, "mid")
            }
          end)
          |> Enum.reject(fn r -> is_nil(r.slug) or r.slug == "" end)

        {:ok, results}

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        case Jason.decode(body) do
          {:ok, %{"content" => items}} when is_list(items) ->
            results =
              Enum.map(items, fn item ->
                %{
                  title: item["main_name"],
                  slug: item["dir"],
                  cover_url: media_url(item, "mid")
                }
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

  @doc """
  Fetches full manga info from Remanga.
  Returns `{:ok, %{...}}` or `{:error, reason}`.
  """
  def get_manga(slug) do
    url = "#{@base_url}/api/titles/#{slug}/"

    case Req.get(url, headers: headers()) do
      {:ok, %{status: 200, body: body}} ->
        content = extract_content(body)

        if content do
          {:ok, parse_manga(content, slug)}
        else
          {:error, "No content in response"}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Fetches image URLs for a specific chapter.
  Uses cached chapter_id -> db_id mapping from get_manga.
  """
  def get_chapter_images(slug, chapter_id) do
    # Look up the db_id from cached mapping
    chapter_map = get_chapter_map(slug)

    case Map.get(chapter_map, chapter_id) do
      nil ->
        {:error, "Chapter #{chapter_id} not found for #{slug}"}

      db_id ->
        url = "#{@base_url}/api/titles/chapters/#{db_id}/"

        case Req.get(url, headers: headers()) do
          {:ok, %{status: 200, body: body}} ->
            content = extract_content(body)
            pages = if content, do: content["pages"], else: nil

            if is_list(pages) do
              images =
                pages
                |> List.flatten()
                |> Enum.map(fn page -> page["link"] end)
                |> Enum.reject(&is_nil/1)

              if images == [] do
                {:error, "No chapter images found"}
              else
                {:ok, images}
              end
            else
              {:error, "No pages in chapter response"}
            end

          {:ok, %{status: status}} ->
            {:error, "HTTP #{status}"}

          {:error, reason} ->
            {:error, reason}
        end
    end
  end

  # --- Chapter map caching ---

  defp get_chapter_map(slug) do
    Roki.Manga.Cache.fetch({:remanga_chapter_map, slug}, :timer.hours(1), fn ->
      # If not cached, we need to fetch it by calling the manga API
      case Req.get("#{@base_url}/api/titles/#{slug}/", headers: headers()) do
        {:ok, %{status: 200, body: body}} ->
          content = extract_content(body)

          if content do
            branches = content["branches"] || []
            branch_id = pick_branch_id(branches)

            if branch_id do
              {_, chapter_map} = fetch_all_chapters(branch_id)
              chapter_map
            else
              %{}
            end
          else
            %{}
          end

        _ ->
          %{}
      end
    end)
  end

  # --- Manga parsing ---

  defp parse_manga(content, slug) do
    type_name = get_in(content, ["type", "name"]) || ""

    reading_mode =
      if type_name in ["Манхва", "Маньхуа"], do: "scroll", else: "paged"

    cover_url =
      case get_in(content, ["cover", "high"]) do
        nil -> nil
        "/" <> _ = path -> @site_url <> path
        path -> @media_url <> path
      end

    alt_titles = content["secondary_name"]

    status = get_in(content, ["status", "name"])

    genres =
      (content["genres"] || [])
      |> Enum.map(fn g -> g["name"] end)
      |> Enum.reject(&is_nil/1)

    synopsis =
      (content["description"] || "")
      |> strip_html_tags()

    year = content["issue_year"]

    written_by =
      (content["publishers"] || [])
      |> Enum.filter(fn p -> p["type"] == "author" end)
      |> Enum.map(fn p -> p["name"] end)
      |> case do
        [] -> nil
        names -> Enum.join(names, ", ")
      end

    # Fetch chapters from the first branch
    branches = content["branches"] || []
    branch_id = pick_branch_id(branches)

    {chapters, chapter_dates, chapter_map} =
      if branch_id do
        {ch_list, ch_map} = fetch_all_chapters(branch_id)

        dates =
          ch_list
          |> Enum.reduce(%{}, fn ch, acc ->
            Map.put(acc, ch.id, ch.date)
          end)

        sorted =
          ch_list
          |> Enum.map(& &1.id)
          |> Enum.sort_by(&chapter_sort_key/1)

        {sorted, dates, ch_map}
      else
        {[], %{}, %{}}
      end

    # Prime the cache so get_chapter_images can look up db_ids
    if chapter_map != %{} do
      cache_key = {:remanga_chapter_map, slug}
      now = System.monotonic_time(:millisecond)

      case :ets.whereis(Roki.Manga.Cache) do
        :undefined -> :ok
        _ref -> :ets.insert(Roki.Manga.Cache, {cache_key, chapter_map, now + :timer.hours(1)})
      end
    end

    %{
      title: content["main_name"] || slug,
      cover_url: cover_url,
      alt_titles: alt_titles,
      status: status,
      reading_direction: if(type_name != "", do: type_name),
      reading_mode: reading_mode,
      written_by: written_by,
      illustrated_by: nil,
      year: if(year, do: to_string(year)),
      genres: genres,
      synopsis: synopsis,
      chapters: chapters,
      chapter_dates: chapter_dates
    }
  end

  # --- Chapter fetching with pagination ---

  defp fetch_all_chapters(branch_id) do
    fetch_chapters_page(branch_id, 1, [], %{})
  end

  defp fetch_chapters_page(branch_id, page, acc_chapters, acc_map) do
    url =
      "#{@base_url}/api/titles/chapters/?branch_id=#{branch_id}&ordering=index&count=100&page=#{page}"

    case Req.get(url, headers: headers()) do
      {:ok, %{status: 200, body: body}} ->
        content = extract_content(body)

        if content && is_list(content) && content != [] do
          {new_chapters, new_map} =
            Enum.reduce(content, {acc_chapters, acc_map}, fn ch, {ch_acc, map_acc} ->
              tome = ch["tome"] || 1
              chapter = ch["chapter"] || "0"
              ch_id = "v#{tome}-c#{chapter}"
              db_id = ch["id"]
              date = ch["upload_date"]

              {
                [%{id: ch_id, date: date} | ch_acc],
                Map.put(map_acc, ch_id, db_id)
              }
            end)

          # Check if there are more pages
          if length(content) == 100 do
            fetch_chapters_page(branch_id, page + 1, new_chapters, new_map)
          else
            {new_chapters, new_map}
          end
        else
          # Try extracting from paginated response format
          items = if is_map(body), do: body["content"], else: nil

          if is_list(items) && items != [] do
            {new_chapters, new_map} =
              Enum.reduce(items, {acc_chapters, acc_map}, fn ch, {ch_acc, map_acc} ->
                tome = ch["tome"] || 1
                chapter = ch["chapter"] || "0"
                ch_id = "v#{tome}-c#{chapter}"
                db_id = ch["id"]
                date = ch["upload_date"]

                {
                  [%{id: ch_id, date: date} | ch_acc],
                  Map.put(map_acc, ch_id, db_id)
                }
              end)

            if length(items) == 100 do
              fetch_chapters_page(branch_id, page + 1, new_chapters, new_map)
            else
              {new_chapters, new_map}
            end
          else
            {acc_chapters, acc_map}
          end
        end

      _ ->
        {acc_chapters, acc_map}
    end
  end

  defp pick_branch_id([]), do: nil

  defp pick_branch_id(branches) do
    # Pick the branch with the most chapters
    branches
    |> Enum.max_by(fn b -> b["count_chapters"] || 0 end, fn -> nil end)
    |> case do
      nil -> nil
      branch -> branch["id"]
    end
  end

  # --- Helpers ---

  defp extract_content(%{"content" => content}), do: content

  defp extract_content(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, %{"content" => content}} -> content
      _ -> nil
    end
  end

  defp extract_content(_), do: nil

  defp media_url(item, size) do
    case get_in(item, ["cover", size]) do
      nil ->
        # Fallback: try img field
        case item["img"] do
          nil -> nil
          "/" <> _ = path -> @site_url <> path
          path -> @media_url <> path
        end

      "/" <> _ = path ->
        @site_url <> path

      path ->
        @media_url <> path
    end
  end

  defp strip_html_tags(text) do
    text
    |> String.replace(~r/<[^>]+>/, "")
    |> String.trim()
  end

  defp chapter_sort_key(ch), do: Chapter.sort_key(ch)

  defp headers do
    Guise.headers("https://remanga.org/")
  end
end
