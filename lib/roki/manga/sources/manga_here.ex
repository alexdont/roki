defmodule Roki.Manga.Sources.MangaHere do
  @moduledoc """
  MangaHere, carried over from the old reader unchanged but for its name. Its parsing is tuned to
  that site's markup and is not ours to improve while porting — `search/1`, `get_manga/1` and
  `get_chapter_images/2` are the three functions every source here answers.
  """
  @base_url "https://www.mangahere.cc"

  alias Guise

  @doc """
  Searches MangaHere for manga matching the query.
  Returns `{:ok, [%{title, slug, cover_url}]}` or `{:error, reason}`.
  """
  def search(query) do
    url = "#{@base_url}/search?title=#{URI.encode_www_form(query)}"

    case Req.get(url, headers: Guise.headers("https://www.mangahere.cc/"), redirect: false) do
      {:ok, %{status: status, body: body}} when status in [200, 301, 302] ->
        doc = Floki.parse_document!(body)

        results =
          doc
          |> Floki.find(".manga-list-4-list > li")
          |> Enum.map(fn li ->
            link = Floki.find(li, "a") |> List.first()
            img = Floki.find(li, "img") |> List.first()

            href = if link, do: Floki.attribute(link, "href") |> List.first()
            title = if img, do: Floki.attribute(img, "alt") |> List.first()
            title = title || if link, do: Floki.text(link) |> String.trim()
            cover_url = if img, do: Floki.attribute(img, "src") |> List.first() |> fix_scheme()

            slug =
              if href do
                href
                |> String.replace_prefix("/manga/", "")
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

  def get_manga(manga_slug) do
    url = "#{@base_url}/manga/#{manga_slug}/"

    case Req.get(url, headers: Guise.headers("https://www.mangahere.cc/")) do
      {:ok, %{status: 200, body: body}} ->
        doc = Floki.parse_document!(body)
        {:ok, parse_manga(doc, manga_slug)}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp parse_manga(doc, _manga_slug) do
    cover_url =
      doc
      |> Floki.find("img.detail-info-cover-img")
      |> Floki.attribute("src")
      |> List.first()
      |> fix_scheme()

    %{
      title:
        doc
        |> Floki.find(".detail-info-right-title-font")
        |> Floki.text()
        |> String.trim(),
      cover_url: cover_url,
      alt_titles: nil,
      status:
        doc
        |> Floki.find(".detail-info-right-title-tip")
        |> Floki.text()
        |> String.trim()
        |> case do
          "" -> nil
          text -> text
        end,
      reading_direction: nil,
      reading_mode: "scroll",
      written_by:
        doc
        |> Floki.find("a[href*=\"/search/author/\"]")
        |> Enum.map(&Floki.text/1)
        |> Enum.join(", ")
        |> case do
          "" -> nil
          text -> text
        end,
      illustrated_by: nil,
      year: nil,
      genres:
        doc
        |> Floki.find(".detail-info-right-tag-list a")
        |> Enum.map(fn el -> el |> Floki.text() |> String.trim() end)
        |> Enum.reject(&(&1 == "")),
      synopsis:
        doc
        |> Floki.find(".fullcontent")
        |> Floki.text()
        |> String.trim(),
      chapters: extract_chapters(doc),
      chapter_dates: extract_chapter_dates(doc)
    }
  end

  defp fix_scheme(nil), do: nil
  defp fix_scheme("//" <> rest), do: "https://#{rest}"
  defp fix_scheme(url), do: url

  defp extract_chapters(doc) do
    doc
    |> Floki.find(".detail-main-list li a")
    |> Floki.attribute("href")
    |> Enum.map(&extract_chapter_number/1)
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
    |> Enum.sort_by(&chapter_sort_key/1)
  end

  defp extract_chapter_number(href) do
    case Regex.run(~r"/c(\d+(?:\.\d+)?)/", href) do
      [_, num] -> num
      _ -> nil
    end
  end

  defp extract_chapter_dates(doc) do
    doc
    |> Floki.find(".detail-main-list li")
    |> Enum.reduce(%{}, fn li, acc ->
      href =
        li
        |> Floki.find("a")
        |> Floki.attribute("href")
        |> List.first()

      date =
        li
        |> Floki.find(".title2")
        |> Floki.text()
        |> String.trim()

      case {href, date} do
        {nil, _} ->
          acc

        {href, date} when date != "" ->
          case extract_chapter_number(href) do
            nil -> acc
            ch -> Map.put(acc, ch, date)
          end

        _ ->
          acc
      end
    end)
  end

  defp chapter_sort_key(ch), do: Chapter.sort_key(ch)

  def get_chapter_images(manga_slug, chapter_id) do
    url = "#{@base_url}/manga/#{manga_slug}/c#{chapter_id}/1.html"

    case Req.get(url, headers: Guise.headers("https://www.mangahere.cc/")) do
      {:ok, %{status: 200, body: body}} ->
        case extract_packed_images(body) do
          {:ok, images} -> {:ok, images}
          {:error, _} -> fetch_images_via_api(body, manga_slug, chapter_id)
        end

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_packed_images(body) do
    # The packed JS arguments follow the function body: }('template',radix,count,'dict'.split('|'),0,{}))
    # We match the arguments portion after the function definition
    pattern =
      ~r/eval\(function\(p,a,c,k,e,d\).*?\}\('((?:[^'\\]|\\.)*)'\s*,\s*(\d+)\s*,\s*\d+\s*,\s*'((?:[^'\\]|\\.)*)'\s*\.split\('\|'\)/s

    case Regex.run(pattern, body) do
      [_, template, radix_str, dict_str] ->
        radix = String.to_integer(radix_str)
        dictionary = String.split(dict_str, "|")
        unpacked = unpack_dean_edwards(template, radix, dictionary)
        extract_urls_from_js(unpacked)

      _ ->
        {:error, "Could not find packed JS on chapter page"}
    end
  end

  defp unpack_dean_edwards(template, radix, dictionary) do
    Regex.replace(~r/\b\w+\b/, template, fn token ->
      case base_n_to_int(token, radix) do
        {:ok, index} ->
          case Enum.at(dictionary, index) do
            nil -> token
            "" -> token
            word -> word
          end

        :error ->
          token
      end
    end)
  end

  defp base_n_to_int(str, radix) do
    str
    |> String.to_charlist()
    |> Enum.reduce_while({:ok, 0}, fn char, {:ok, acc} ->
      digit =
        cond do
          char >= ?0 and char <= ?9 -> char - ?0
          char >= ?a and char <= ?z -> char - ?a + 10
          char >= ?A and char <= ?Z -> char - ?A + 36
          true -> nil
        end

      if digit != nil and digit < radix do
        {:cont, {:ok, acc * radix + digit}}
      else
        {:halt, :error}
      end
    end)
  end

  defp extract_urls_from_js(js) do
    urls =
      Regex.scan(
        ~r{(//(?:zjcdn\.org|[a-z]+\.mangahere\.[a-z]+|fmcdn\.mangahere\.com)/store/manga/[^'"\s\\]+)},
        js
      )
      |> Enum.map(fn [_, url] -> fix_scheme(url) end)

    if urls == [] do
      {:error, "No image URLs found in unpacked JS"}
    else
      {:ok, urls}
    end
  end

  # --- API-based image fetching for manga (non-manhwa) chapters ---

  defp fetch_images_via_api(body, manga_slug, chapter_id) do
    case extract_chapter_api_params(body) do
      {:ok, params} ->
        base_url = "#{@base_url}/manga/#{manga_slug}/c#{chapter_id}/chapterfun.ashx"
        pages = for p <- 1..params.imagecount, rem(p, 2) == 1, do: p

        api_headers =
          Guise.headers("#{@base_url}/manga/#{manga_slug}/c#{chapter_id}/1.html") ++
            [{"x-requested-with", "XMLHttpRequest"}]

        images =
          pages
          |> Task.async_stream(
            fn page ->
              url = "#{base_url}?cid=#{params.chapterid}&page=#{page}&key=#{params.dm5_key}"

              case Req.get(url, headers: api_headers) do
                {:ok, %{status: 200, body: resp_body}} when is_binary(resp_body) ->
                  extract_paged_images(resp_body)

                _ ->
                  []
              end
            end,
            max_concurrency: 4,
            timeout: 15_000,
            ordered: true
          )
          |> Enum.flat_map(fn
            {:ok, urls} -> urls
            _ -> []
          end)

        if images == [] do
          {:error, "No images found via chapterfun API"}
        else
          {:ok, images}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp extract_chapter_api_params(body) do
    with [_, cid] <- Regex.run(~r/var\s+chapterid\s*=\s*(\d+)/, body),
         [_, count] <- Regex.run(~r/var\s+imagecount\s*=\s*(\d+)/, body) do
      dm5_key = extract_dm5_key(body) || ""
      {:ok, %{chapterid: cid, imagecount: String.to_integer(count), dm5_key: dm5_key}}
    else
      _ -> {:error, "Could not extract chapter API params (chapterid/imagecount)"}
    end
  end

  defp extract_dm5_key(body) do
    pattern =
      ~r/eval\(function\(p,a,c,k,e,d\).*?\}\('((?:[^'\\]|\\.)*)'\s*,\s*(\d+)\s*,\s*\d+\s*,\s*'((?:[^'\\]|\\.)*)'\s*\.split\('\|'\)/s

    Regex.scan(pattern, body)
    |> Enum.find_value(fn [_, template, radix_str, dict_str] ->
      radix = String.to_integer(radix_str)
      dictionary = String.split(dict_str, "|")
      unpacked = unpack_dean_edwards(template, radix, dictionary)

      case Regex.run(~r/var\s+guidkey\s*=\s*([^;]+);/, unpacked) do
        [_, expr] ->
          # The template preserves JS escape sequences like \' — unescape before parsing
          expr
          |> String.replace("\\'", "'")
          |> then(&Regex.scan(~r/'([^']*)'/, &1))
          |> Enum.map(fn [_, v] -> v end)
          |> Enum.join()
          |> case do
            "" -> nil
            key -> key
          end

        _ ->
          nil
      end
    end)
  end

  defp extract_paged_images(body) do
    pattern =
      ~r/eval\(function\(p,a,c,k,e,d\).*?\}\('((?:[^'\\]|\\.)*)'\s*,\s*(\d+)\s*,\s*\d+\s*,\s*'((?:[^'\\]|\\.)*)'\s*\.split\('\|'\)/s

    case Regex.run(pattern, body) do
      [_, template, radix_str, dict_str] ->
        radix = String.to_integer(radix_str)
        dictionary = String.split(dict_str, "|")
        unpacked = unpack_dean_edwards(template, radix, dictionary)

        with [_, pix] <- Regex.run(~r/var\s+pix\s*=\s*"([^"]+)"/, unpacked),
             [_, pvalue_str] <- Regex.run(~r/var\s+pvalue\s*=\s*\[([^\]]+)\]/, unpacked) do
          Regex.scan(~r/"([^"]+)"/, pvalue_str)
          |> Enum.map(fn [_, filename] -> "https:" <> pix <> filename end)
        else
          _ -> []
        end

      _ ->
        []
    end
  end
end
