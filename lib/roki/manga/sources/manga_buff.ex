defmodule Roki.Manga.Sources.MangaBuff do
  @base_url "https://mangabuff.ru"

  alias Guise

  @doc """
  Searches MangaBuff for manga matching the query.
  Returns `{:ok, [%{title, slug, cover_url}]}` or `{:error, reason}`.
  """
  def search(query) do
    url = "#{@base_url}/search/suggestions?q=#{URI.encode_www_form(query)}"

    case Req.get(url, headers: headers() ++ [{"x-requested-with", "XMLHttpRequest"}]) do
      {:ok, %{status: 200, body: body}} ->
        items = if is_list(body), do: body, else: decode_json(body)

        results =
          Enum.map(items, fn item ->
            %{
              title: item["name"],
              slug: item["slug"],
              cover_url: if(item["image"], do: "#{@base_url}/x70#{item["image"]}")
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

  @doc """
  Fetches full manga info from MangaBuff.
  """
  def get_manga(slug) do
    url = "#{@base_url}/manga/#{slug}"

    case Req.get(url, headers: headers(), redirect: false) do
      {:ok, %{status: 200, body: body} = resp} ->
        csrf = extract_csrf(body)
        cookies = extract_cookies(resp)
        manga_id = extract_manga_id(body)

        # Fetch metadata from suggestions API (returns genres, type, status, etc.)
        # Search by Russian name from h1 (slug-based search often returns nothing)
        doc = Floki.parse_document!(body)
        manga_name = doc |> Floki.find("h1") |> Floki.text() |> String.trim()
        api_data = fetch_manga_api_data(manga_name, slug)

        chapters_result =
          if manga_id && csrf do
            fetch_chapters(manga_id, csrf, cookies, slug)
          else
            {[], %{}}
          end

        {:ok, parse_manga(body, slug, api_data, chapters_result)}

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
    [vol, ch] = parse_chapter_id(chapter_id)
    url = "#{@base_url}/manga/#{slug}/#{vol}/#{ch}"

    case Req.get(url, headers: headers()) do
      {:ok, %{status: 200, body: body}} ->
        doc = Floki.parse_document!(body)

        # Collect both src and data-src from img tags on CDN
        images =
          doc
          |> Floki.find("img")
          |> Enum.flat_map(fn el ->
            src = Floki.attribute(el, "src") |> List.first()
            data_src = Floki.attribute(el, "data-src") |> List.first()
            [src, data_src] |> Enum.reject(&is_nil/1)
          end)
          |> Enum.filter(&mangabuff_cdn?/1)
          |> Enum.map(&ensure_absolute/1)
          |> Enum.uniq()

        if images == [] do
          {:error, "No chapter images found"}
        else
          {:ok, images}
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # --- Chapter fetching via CSRF-protected POST ---

  defp fetch_chapters(manga_id, csrf, cookies, slug) do
    post_headers =
      headers() ++
        [
          {"x-requested-with", "XMLHttpRequest"},
          {"x-csrf-token", csrf},
          {"cookie", cookies}
        ]

    case Req.post("#{@base_url}/chapters/load",
           headers: post_headers,
           form: [manga_id: manga_id],
           redirect: false
         ) do
      {:ok, %{status: 200, body: body}} ->
        html = if is_map(body), do: body["content"], else: body
        if html, do: parse_chapter_html(html, slug), else: {[], %{}}

      _ ->
        {[], %{}}
    end
  end

  defp parse_chapter_html(html, slug) do
    pattern = ~r{href="https://mangabuff\.ru/manga/#{Regex.escape(slug)}/(\d+)/(\d+(?:\.\d+)?)"}

    links = Regex.scan(pattern, html)

    chapters =
      links
      |> Enum.map(fn [_, vol, ch] -> "v#{vol}-c#{ch}" end)
      |> Enum.uniq()
      |> Enum.sort_by(&chapter_sort_key/1)

    # Extract dates from data-chapter-date attributes
    date_pattern =
      ~r{href="https://mangabuff\.ru/manga/#{Regex.escape(slug)}/(\d+)/(\d+(?:\.\d+)?)"[^>]*data-chapter-date="([^"]+)"}

    chapter_dates =
      Regex.scan(date_pattern, html)
      |> Enum.reduce(%{}, fn [_, vol, ch, date], acc ->
        Map.put(acc, "v#{vol}-c#{ch}", date)
      end)

    {chapters, chapter_dates}
  end

  defp extract_csrf(body) do
    case Regex.run(~r/meta name="csrf-token" content="([^"]+)"/, body) do
      [_, token] -> token
      _ -> nil
    end
  end

  defp extract_cookies(resp) do
    resp.headers
    |> Map.get("set-cookie", [])
    |> Enum.map(fn v -> String.split(v, ";") |> List.first() end)
    |> Enum.join("; ")
  end

  defp extract_manga_id(body) do
    case Regex.run(~r/data-id="(\d+)"/, body) do
      [_, id] -> id
      _ -> nil
    end
  end

  # --- Suggestions API for metadata ---

  defp fetch_manga_api_data(name, slug) do
    query = if name != "", do: name, else: slug
    url = "#{@base_url}/search/suggestions?q=#{URI.encode_www_form(query)}"

    case Req.get(url, headers: headers() ++ [{"x-requested-with", "XMLHttpRequest"}]) do
      {:ok, %{status: 200, body: body}} ->
        items = if is_list(body), do: body, else: decode_json(body)
        # Match by slug for exact result
        Enum.find(items, %{}, fn item -> item["slug"] == slug end)

      _ ->
        %{}
    end
  end

  # --- Manga page parsing ---

  defp parse_manga(body, slug, api_data, {chapters, chapter_dates}) do
    # Type from API (e.g. %{"name" => "Манга"})
    type_name = get_in(api_data, ["type", "name"]) || ""

    reading_mode =
      if type_name in ["Манхва", "Маньхуа"], do: "scroll", else: "paged"

    # Title from og:title (server-rendered), strip the " - Манга читать онлайн" suffix
    og_title = extract_meta_content(body, "og:title")

    title =
      case og_title do
        nil -> api_data["name"] || slug
        t -> t |> String.replace(~r/\s*-\s*Манга читать онлайн$/, "") |> String.trim()
      end

    # Synopsis from og:description (server-rendered)
    synopsis = extract_meta_content(body, "og:description") || ""

    # Cover from og:image or fallback
    cover_url =
      extract_meta_content(body, "og:image") ||
        "#{@base_url}/img/manga/posters/#{slug}.jpg"

    # Genres from API data
    genres =
      (api_data["genres"] || [])
      |> Enum.map(fn g -> g["name"] end)
      |> Enum.reject(&is_nil/1)

    # Status from API
    status_name = get_in(api_data, ["status", "name"])

    # Year from release date
    year =
      case api_data["release"] do
        <<y::binary-size(4), _::binary>> -> y
        _ -> nil
      end

    %{
      title: title,
      cover_url: cover_url,
      alt_titles: nil,
      status: status_name,
      reading_direction: if(type_name != "", do: type_name),
      reading_mode: reading_mode,
      written_by: nil,
      illustrated_by: nil,
      year: year,
      genres: genres,
      synopsis: synopsis,
      chapters: chapters,
      chapter_dates: chapter_dates
    }
  end

  defp extract_meta_content(body, property) do
    case Regex.run(
           ~r/<meta\s+(?:property|name)="#{Regex.escape(property)}"\s+content="([^"]*)"/,
           body
         ) do
      [_, content] -> decode_html_entities(content)
      _ -> nil
    end
  end

  defp decode_html_entities(str) do
    str
    |> String.replace("&amp;", "&")
    |> String.replace("&lt;", "<")
    |> String.replace("&gt;", ">")
    |> String.replace("&quot;", "\"")
    |> String.replace("&#39;", "'")
  end

  # --- Helpers ---

  defp mangabuff_cdn?(url) do
    String.contains?(url, "mangabuff.ru")
  end

  defp ensure_absolute("//" <> rest), do: "https://#{rest}"
  defp ensure_absolute("/" <> _ = path), do: "#{@base_url}#{path}"
  defp ensure_absolute(url), do: url

  defp parse_chapter_id(chapter_id) do
    case Regex.run(~r/^v(.+)-c(.+)$/, chapter_id) do
      [_, volume, number] -> [volume, number]
      _ -> ["1", chapter_id]
    end
  end

  defp chapter_sort_key(ch), do: Chapter.sort_key(ch)

  defp decode_json(body) when is_binary(body) do
    case Jason.decode(body) do
      {:ok, data} when is_list(data) -> data
      _ -> []
    end
  end

  defp decode_json(_), do: []

  defp headers do
    Guise.headers("#{@base_url}/")
  end
end
