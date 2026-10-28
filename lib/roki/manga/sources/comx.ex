defmodule Roki.Manga.Sources.ComX do
  @moduledoc """
  Source module for com-x.life — Russian-language comics and manga reader.

  Uses a JS challenge bypass: first request gets a challenge page with a token,
  which we POST to /_v to receive a __guard_trust cookie, then use for all requests.
  """

  @base_url "https://com-x.life"

  alias Guise

  @doc """
  Searches Com-X for manga matching the query.
  Returns `{:ok, [%{title, slug, cover_url}]}` or `{:error, reason}`.
  """
  def search(query) do
    url = "#{@base_url}/search/#{URI.encode_www_form(query)}"

    with {:ok, html} <- fetch_page(url) do
      results =
        Regex.scan(
          ~r/class="readed d-flex short"><a href="(?:https:\/\/com-x\.life)?\/(\d+-[^"]+?)\.html"[^>]*>.*?data-src="([^"]+)".*?<\/a>.*?href="[^"]*\1\.html"[^>]*>\s*([^<]+)</,
          html
        )
        |> Enum.map(fn [_, slug, cover, title] ->
          %{
            title: String.trim(title),
            slug: slug,
            cover_url: @base_url <> cover
          }
        end)
        |> Enum.uniq_by(& &1.slug)

      {:ok, results}
    end
  end

  @doc """
  Fetches full manga info from Com-X.
  Returns `{:ok, %{...}}` or `{:error, reason}`.
  """
  def get_manga(slug) do
    url = "#{@base_url}/#{slug}.html"

    with {:ok, html} <- fetch_page(url) do
      parse_manga_page(html, slug)
    end
  end

  @doc """
  Fetches image URLs for a specific chapter.
  The chapter_id is the position number (e.g. "1", "2") which gets
  mapped to the internal com-x.life chapter ID via cached mapping.
  """
  def get_chapter_images(slug, chapter_id) do
    news_id = slug |> String.split("-", parts: 2) |> List.first()

    # Look up internal ID from cached chapter map
    internal_id = get_chapter_internal_id(slug, chapter_id)

    reader_id = internal_id || chapter_id
    url = "#{@base_url}/reader/#{news_id}/#{reader_id}"

    with {:ok, html} <- fetch_page(url) do
      case extract_json_data(html) do
        %{"images" => images, "host" => host} when is_list(images) and images != [] ->
          urls = Enum.map(images, fn path -> "https://#{host}/comix/#{path}" end)
          {:ok, urls}

        %{"images" => images} when is_list(images) and images != [] ->
          urls = Enum.map(images, fn path -> "https://img.com-x.life/comix/#{path}" end)
          {:ok, urls}

        _ ->
          {:error, "No images found in reader page"}
      end
    end
  end

  # --- Manga page parsing ---

  defp parse_manga_page(html, slug) do
    # Extract from Schema.org JSON-LD (ComicSeries type)
    schema = extract_comic_schema(html)
    data = extract_json_data(html)

    title = (schema && schema["name"]) || (data && data["title"]) || slug
    alt_title = schema && schema["alternativeHeadline"]
    alt_titles = if alt_title && alt_title != "", do: alt_title, else: nil

    cover_url =
      case extract_og_image(html) do
        nil -> schema && schema["image"]
        url -> url
      end

    synopsis = schema && schema["description"]

    year =
      case schema && schema["startDate"] do
        <<y::binary-size(4), _::binary>> -> y
        _ -> nil
      end

    genres = extract_genres(html)

    # Chapters from __DATA__
    {chapters, chapter_dates} =
      case data do
        %{"chapters" => ch_list} when is_list(ch_list) ->
          parse_chapters(ch_list, slug)

        _ ->
          {[], %{}}
      end

    {:ok,
     %{
       title: title,
       cover_url: cover_url,
       alt_titles: alt_titles,
       status: nil,
       reading_direction: nil,
       reading_mode: "scroll",
       written_by: nil,
       illustrated_by: nil,
       year: year,
       genres: genres,
       synopsis: synopsis,
       chapters: chapters,
       chapter_dates: chapter_dates
     }}
  end

  defp parse_chapters(ch_list, slug) do
    chapters =
      ch_list
      |> Enum.map(fn ch ->
        internal_id = to_string(ch["id"])
        posi = ch["posi"] || 0
        date = ch["date"]

        %{posi: posi, internal_id: internal_id, date: date}
      end)
      |> Enum.sort_by(& &1.posi)

    # Use position number as chapter ID (what users see)
    ids = Enum.map(chapters, fn ch -> to_string(ch.posi) end)

    dates =
      Enum.reduce(chapters, %{}, fn ch, acc ->
        Map.put(acc, to_string(ch.posi), ch.date)
      end)

    # Cache posi -> internal_id mapping for get_chapter_images
    chapter_map =
      Enum.reduce(chapters, %{}, fn ch, acc ->
        Map.put(acc, to_string(ch.posi), ch.internal_id)
      end)

    cache_chapter_map(slug, chapter_map)

    {ids, dates}
  end

  # --- Challenge bypass ---
  #
  # Flow: GET url → 302 to /_c?t=...&u=... (sets __guard_token cookie)
  #       GET /_c?... with cookie → challenge HTML with JS fingerprint code
  #       POST /_v with token + fingerprint → 200 (sets __guard_trust cookie)
  #       GET url with both cookies → 200 + actual content

  defp fetch_page(url) do
    # Try cached trust cookie first
    case get_cached_trust_cookie() do
      {trust, guard_token} ->
        case fetch_with_cookies(url, trust, guard_token) do
          {:ok, html} ->
            {:ok, html}

          _error ->
            # Cookie expired, solve challenge fresh
            clear_trust_cookie_cache()
            solve_challenge_and_fetch(url)
        end

      nil ->
        solve_challenge_and_fetch(url)
    end
  end

  defp fetch_with_cookies(url, trust_cookie, guard_token) do
    cookie = "__guard_trust=#{trust_cookie}; __guard_token=#{guard_token}"

    case Req.get(url,
           headers: [{"cookie", cookie} | ua_headers()],
           redirect: false
         ) do
      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        # Check if we got a redirect (challenge again) instead of content
        if String.length(body) < 500 and String.contains?(body, "302 Found") do
          {:error, "Trust cookie expired"}
        else
          {:ok, body}
        end

      {:ok, %{status: 302}} ->
        {:error, "Trust cookie expired"}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  defp solve_challenge_and_fetch(url) do
    case step1_get_redirect(url) do
      {:already_ok, body} ->
        {:ok, body}

      {:ok, guard_token, challenge_url} ->
        with {:ok, token} <- step2_get_challenge(challenge_url, guard_token),
             {:ok, trust_cookie} <- step3_post_challenge(url, token, guard_token),
             :ok <- cache_trust_cookie(trust_cookie, guard_token),
             {:ok, html} <- fetch_with_cookies(url, trust_cookie, guard_token) do
          {:ok, html}
        end

      {:error, _} = error ->
        error
    end
  end

  # Step 1: GET url → 302 redirect with __guard_token cookie
  defp step1_get_redirect(url) do
    case Req.get(url, headers: ua_headers(), redirect: false) do
      {:ok, %{status: 302} = resp} ->
        guard_token = extract_set_cookie(resp.headers, "__guard_token")
        location = Req.Response.get_header(resp, "location") |> List.first()

        challenge_url =
          cond do
            is_nil(location) -> nil
            String.starts_with?(location, "http") -> location
            true -> @base_url <> location
          end

        if guard_token && challenge_url do
          {:ok, guard_token, challenge_url}
        else
          {:error, "Missing guard_token or redirect location"}
        end

      {:ok, %{status: 200, body: body}} when is_binary(body) ->
        # No challenge needed, page returned directly
        {:already_ok, body}

      {:ok, %{status: status}} ->
        {:error, "HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # Step 2: GET /_c challenge page → extract token
  defp step2_get_challenge(challenge_url, guard_token) do
    case Req.get(challenge_url,
           headers: [{"cookie", "__guard_token=#{guard_token}"} | ua_headers()],
           redirect: false
         ) do
      {:ok, %{body: body}} when is_binary(body) ->
        case Regex.run(~r/token:\s*"([^"]+)"/, body) do
          [_, token] -> {:ok, token}
          _ -> {:error, "No token in challenge page"}
        end

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # Step 3: POST /_v with fingerprint → get __guard_trust cookie
  defp step3_post_challenge(url, token, guard_token) do
    body =
      URI.encode_query(%{
        "token" => token,
        "mode" => "modern",
        "workTime" => "150",
        "iterations" => "500",
        "webdriver" => "0",
        "touch" => "0",
        "screen_w" => "1920",
        "screen_h" => "1080",
        "screen_cd" => "24",
        "wgv" => "Google Inc. (NVIDIA)",
        "wgr" => "ANGLE (NVIDIA, NVIDIA GeForce RTX 3060 Direct3D11 vs_5_0 ps_5_0, D3D11)",
        "tz" => "-180",
        "dpr" => "1"
      })

    case Req.post("#{@base_url}/_v",
           body: body,
           headers: [
             {"content-type", "application/x-www-form-urlencoded"},
             {"referer", url},
             {"cookie", "__guard_token=#{guard_token}"}
             | ua_headers()
           ],
           redirect: false
         ) do
      {:ok, %{status: 200} = resp} ->
        case extract_set_cookie(resp.headers, "__guard_trust") do
          nil -> {:error, "No trust cookie in challenge response"}
          trust -> {:ok, trust}
        end

      {:ok, %{status: status}} ->
        {:error, "Challenge POST returned HTTP #{status}"}

      {:error, reason} ->
        {:error, inspect(reason)}
    end
  end

  # --- Cookie caching via ETS ---

  defp cache_trust_cookie(trust, guard_token) do
    ttl = :timer.hours(12)
    now = System.monotonic_time(:millisecond)

    case :ets.whereis(Roki.Manga.Cache) do
      :undefined -> :ok
      _ref -> :ets.insert(Roki.Manga.Cache, {:comx_trust_cookie, {trust, guard_token}, now + ttl})
    end

    :ok
  end

  defp get_cached_trust_cookie do
    Roki.Manga.Cache.fetch(:comx_trust_cookie, :timer.hours(12), fn -> nil end)
  rescue
    _ -> nil
  end

  # --- Chapter map caching (posi -> internal_id) ---

  defp cache_chapter_map(slug, chapter_map) do
    ttl = :timer.hours(6)
    now = System.monotonic_time(:millisecond)

    case :ets.whereis(Roki.Manga.Cache) do
      :undefined -> :ok
      _ref -> :ets.insert(Roki.Manga.Cache, {{:comx_chapter_map, slug}, chapter_map, now + ttl})
    end
  end

  defp get_chapter_internal_id(slug, chapter_id) do
    chapter_map =
      Roki.Manga.Cache.fetch({:comx_chapter_map, slug}, :timer.hours(6), fn ->
        # If not cached, fetch manga to populate the map
        case get_manga(slug) do
          {:ok, _} ->
            # get_manga will have cached the map, read it back
            case :ets.lookup(Roki.Manga.Cache, {:comx_chapter_map, slug}) do
              [{_, map, _}] -> map
              _ -> %{}
            end

          _ ->
            %{}
        end
      end)

    Map.get(chapter_map, chapter_id)
  end

  defp clear_trust_cookie_cache do
    case :ets.whereis(Roki.Manga.Cache) do
      :undefined -> :ok
      _ref -> :ets.delete(Roki.Manga.Cache, :comx_trust_cookie)
    end
  rescue
    _ -> :ok
  end

  # --- Extraction helpers ---

  defp extract_json_data(html) do
    # Find the start of window.__DATA__ and extract the JSON object
    case :binary.match(html, "window.__DATA__") do
      {pos, _} ->
        # Find the opening brace
        rest = binary_part(html, pos, byte_size(html) - pos)

        case :binary.match(rest, "{") do
          {brace_pos, _} ->
            json_rest = binary_part(rest, brace_pos, byte_size(rest) - brace_pos)
            extract_balanced_json(json_rest)

          :nomatch ->
            nil
        end

      :nomatch ->
        nil
    end
  end

  defp extract_balanced_json(str) do
    # Find the matching closing brace by counting depth
    extract_balanced_json(str, 0, 0, false)
  end

  defp extract_balanced_json(str, pos, depth, in_string) when pos < byte_size(str) do
    char = :binary.at(str, pos)

    cond do
      in_string and char == ?\\ ->
        # Skip escaped character
        extract_balanced_json(str, pos + 2, depth, true)

      in_string and char == ?" ->
        extract_balanced_json(str, pos + 1, depth, false)

      not in_string and char == ?" ->
        extract_balanced_json(str, pos + 1, depth, true)

      not in_string and char == ?{ ->
        extract_balanced_json(str, pos + 1, depth + 1, false)

      not in_string and char == ?} ->
        if depth == 1 do
          json_str = binary_part(str, 0, pos + 1)

          case Jason.decode(json_str) do
            {:ok, data} -> data
            _ -> nil
          end
        else
          extract_balanced_json(str, pos + 1, depth - 1, false)
        end

      true ->
        extract_balanced_json(str, pos + 1, depth, in_string)
    end
  end

  defp extract_balanced_json(_, _, _, _), do: nil

  defp extract_comic_schema(html) do
    Regex.scan(~r/type="application\/ld\+json">(.*?)<\/script>/s, html)
    |> Enum.find_value(fn [_, json_str] ->
      case Jason.decode(json_str) do
        {:ok, %{"@graph" => graph}} ->
          Enum.find(graph, fn item ->
            item["@type"] == "ComicSeries"
          end)

        _ ->
          nil
      end
    end)
  end

  defp extract_og_image(html) do
    case Regex.run(~r/og:image"\s+content="([^"]+)"/, html) do
      [_, url] -> url
      _ -> nil
    end
  end

  defp extract_genres(html) do
    Regex.scan(~r/href="\/tags\/[^"]*"[^>]*>([^<]+)</, html)
    |> Enum.map(fn [_, genre] -> String.trim(genre) end)
    |> Enum.reject(&(&1 == ""))
  end

  defp extract_set_cookie(%Req.Response{} = resp, name) do
    extract_set_cookie(resp.headers, name)
  end

  defp extract_set_cookie(headers, name) when is_map(headers) do
    # Req returns headers as %{"set-cookie" => ["val1", "val2"]}
    cookies = Map.get(headers, "set-cookie", [])

    Enum.find_value(List.wrap(cookies), fn v ->
      case Regex.run(~r/#{Regex.escape(name)}=([^;]+)/, v) do
        [_, val] -> val
        _ -> nil
      end
    end)
  end

  defp extract_set_cookie(headers, name) when is_list(headers) do
    headers
    |> Enum.filter(fn {k, _} -> String.downcase(k) == "set-cookie" end)
    |> Enum.find_value(fn {_, v} ->
      values = if is_list(v), do: v, else: [v]

      Enum.find_value(values, fn cookie_str ->
        case Regex.run(~r/#{Regex.escape(name)}=([^;]+)/, cookie_str) do
          [_, val] -> val
          _ -> nil
        end
      end)
    end)
  end

  defp ua_headers do
    Guise.headers("#{@base_url}/")
  end
end
