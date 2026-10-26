defmodule Roki.AnimeCorner do
  @moduledoc """
  Anime Corner's weekly rankings (animecorner.me), the poll people post on Reddit every week:
  "Fall 2026 Anime Rankings – Week 3", a table of the season's anime with each one's share of
  the votes, and at the season's end an "Anime of the Season" ranking.

  A post is read once and kept for a while (it does not change), its titles matched to TMDB
  titles so the page shows them as posters that play: first among the season's own list, then
  by a TMDB search for what that list does not have. Anime Corner names a season of a show
  ("The Apothecary Diaries Season 3") where TMDB has the show; what names the season is cut
  off before comparing, and a long title is tried ever shorter ("Bleach: Thousand-Year Blood
  War – The Calamity" down to "Bleach").
  """

  @base "https://animecorner.me"
  @ua "Mozilla/5.0 (compatible; roki.ee)"
  # A post never changes; the list of posted weeks grows by one a week.
  @post_ttl_s 6 * 3600
  @weeks_ttl_s 3600
  @match_ttl_s 7 * 24 * 3600
  @most_weeks 14

  @doc "The address of a week's post, or of the season's final ranking (`:final`)."
  def url(season, week), do: "#{@base}/#{slug(season, week)}/"

  @doc "The post's slug: `fall-2026-anime-rankings-week-3`, `summer-2026-anime-of-the-season-rankings`."
  def slug({year, name}, :final), do: "#{name}-#{year}-anime-of-the-season-rankings"
  def slug({year, name}, week) when is_integer(week), do: "#{name}-#{year}-anime-rankings-week-#{week}"

  @doc "The week named in an address: `\"3\"` → 3, `\"final\"` → :final, else nil (the latest)."
  def week("final"), do: :final

  def week(value) when is_binary(value) do
    case Integer.parse(value) do
      {n, ""} when n in 1..@most_weeks -> n
      _ -> nil
    end
  end

  def week(_value), do: nil

  @doc "A week as the address writes it."
  def week_param(:final), do: "final"
  def week_param(n) when is_integer(n), do: Integer.to_string(n)

  @doc "A week as the page says it."
  def week_label(:final), do: "Season final"
  def week_label(n) when is_integer(n), do: "Week #{n}"

  @doc """
  The weeks posted for a season, latest first — `[:final, 12, 11, …]` once the season's own
  ranking is out, else `[3, 2, 1]`. Found by asking for each post; remembered for an hour.
  """
  def weeks(season) do
    case Roki.TTLCache.fetch({:corner_weeks, season}, @weeks_ttl_s, fn -> {:ok, find_weeks(season)} end) do
      {:ok, weeks} -> weeks
      _ -> []
    end
  end

  defp find_weeks(season) do
    [:final | Enum.to_list(@most_weeks..1//-1)]
    |> Task.async_stream(fn w -> {w, exists?(url(season, w))} end,
      max_concurrency: 8,
      timeout: 20_000,
      on_timeout: :kill_task
    )
    |> Enum.flat_map(fn
      {:ok, {w, true}} -> [w]
      _ -> []
    end)
  end

  @doc """
  The ranking of a week (`nil` for the latest posted): `{:ok, %{week:, url:, entries:}}`, each
  entry `%{rank: 1, title: "…", votes: 20.15}`; `{:error, :no_ranking}` when nothing is posted
  for the season.
  """
  def ranking(season, nil) do
    case weeks(season) do
      [latest | _] -> ranking(season, latest)
      [] -> {:error, :no_ranking}
    end
  end

  def ranking(season, week) do
    Roki.TTLCache.fetch({:corner_post, season, week}, @post_ttl_s, fn ->
      with {:ok, html} <- get(url(season, week)),
           [_ | _] = entries <- parse(html) do
        {:ok, %{week: week, url: url(season, week), entries: entries}}
      else
        [] -> {:error, :no_ranking}
        {:error, :not_found} -> {:error, :no_ranking}
        error -> error
      end
    end)
  end

  @doc """
  The ranking's entries as TMDB titles, in rank order, each with its place and share as a
  badge and a note: `{:ok, %{week:, url:, weeks:, items:, missing:}}` — `missing` the titles
  nothing on TMDB was found for. The season's own list is the first place looked, so most
  cost nothing; the rest are one search each, remembered for a week.
  """
  def items(uuid, season, week) do
    with {:ok, post} <- ranking(season, week) do
      Roki.TTLCache.fetch({:corner_items, season, post.week}, @post_ttl_s, fn ->
        pool = for i <- pool(uuid, season), do: {key(i.title), i}

        {items, missing} =
          Enum.reduce(post.entries, {[], []}, fn e, {items, missing} ->
            case find(e.title, pool, uuid) do
              nil -> {items, [e.title | missing]}
              item -> {[decorate(item, e) | items], missing}
            end
          end)

        {:ok,
         %{
           week: post.week,
           url: post.url,
           weeks: weeks(season),
           items: Enum.reverse(items),
           missing: Enum.reverse(missing)
         }}
      end)
    end
  end

  defp decorate(item, %{rank: rank, votes: votes}) do
    share = if is_number(votes), do: " · #{:erlang.float_to_binary(votes * 1.0, decimals: 2)}% of the vote", else: ""
    Map.merge(item, %{badge: "##{rank}", note: "No. #{rank}#{share}"})
  end

  # The season's anime as the Anime page lists them, every page of it (a few at most).
  defp pool(uuid, season), do: pool(uuid, season, 1, [])

  defp pool(uuid, season, n, acc) when n <= 10 do
    case Roki.Browse.page(:anime, :popular, n, uuid, season) do
      {:ok, items, true} -> pool(uuid, season, n + 1, acc ++ items)
      {:ok, items, false} -> acc ++ items
      _ -> acc
    end
  end

  defp pool(_uuid, _season, _n, acc), do: acc

  # The title among the season's, by its name cut ever shorter: the same name first, then one
  # that begins or contains the other (long enough that it means something), else a search.
  defp find(title, pool, uuid) do
    keys = title |> variants() |> Enum.map(&key/1) |> Enum.reject(&(&1 == ""))

    Enum.find_value(keys, fn k -> Enum.find_value(pool, fn {pk, i} -> if pk == k, do: i end) end) ||
      Enum.find_value(keys, fn k ->
        Enum.find_value(pool, fn {pk, i} ->
          if String.length(pk) >= 8 and String.length(k) >= 8 and (String.contains?(k, pk) or String.starts_with?(pk, k)),
            do: i
        end)
      end) ||
      search(uuid, title)
  end

  # TMDB's own search for the cleaned title, the first show it gives; remembered for a week.
  defp search(uuid, title) do
    text = clean(title)

    result =
      Roki.TTLCache.fetch({:corner_search, text}, @match_ttl_s, fn ->
        Roki.Laev.public(uuid, fn ->
          case Laev.Tmdb.search(text) do
            {:ok, results, _more?} -> {:ok, Enum.find(results, &(&1.type == "tv")) || :none}
            error -> error
          end
        end)
      end)

    case result do
      {:ok, %{} = item} -> item
      _ -> nil
    end
  end

  @doc """
  The title without what names a season of it: "Season 3", "3rd Season", "2nd-3rd STAGE",
  "Part 2", "Cour 2", "Final Season", a year in brackets.
  """
  def clean(title) do
    title
    |> String.replace(~r/[’‘`]/u, "'")
    |> String.replace(~r/\s*\(\d{4}\)/u, "")
    |> String.replace(~r/\s+(?:the\s+)?final\s+season\b.*$/iu, "")
    |> String.replace(~r/\s+season\s+\d+\b.*$/iu, "")
    |> String.replace(~r/\s+\d+(?:st|nd|rd|th)(?:-\d+(?:st|nd|rd|th))?\s+(?:season|stage|cour)\b.*$/iu, "")
    |> String.replace(~r/\s+(?:part|cour)\s+\d+\b.*$/iu, "")
    |> String.trim()
  end

  @doc "The cleaned title, then ever shorter: what comes before a dash, before a colon."
  def variants(title) do
    full = clean(title)

    cuts =
      for sep <- [" – ", " — ", " - ", ": "],
          [head, _ | _] <- [String.split(full, sep)],
          head = String.trim(head),
          head != "",
          do: head

    Enum.uniq([full | cuts])
  end

  @doc "What is compared: the cleaned title in lower-case letters and digits only (½ counts as 12)."
  def key(title) do
    title
    |> clean()
    |> String.downcase()
    |> String.replace("½", "12")
    |> String.replace(~r/[^a-z0-9]+/u, "")
  end

  # ── the post ──────────────────────────────────────────────────────

  @doc """
  The ranking table of a post's HTML: `[%{rank:, title:, votes:}]` for every row with a place,
  a title and a share ("1st | Firefly Wedding | 9.23%"). Empty when there is no such table.
  """
  def parse(html) do
    ~r/<tr[^>]*>(.*?)<\/tr>/s
    |> Regex.scan(html)
    |> Enum.flat_map(fn [_, row] ->
      cells = for [_, cell] <- Regex.scan(~r/<td[^>]*>(.*?)<\/td>/s, row), do: text(cell)

      with [place, title, votes | _] <- cells,
           [_, rank] <- Regex.run(~r/^(\d+)(?:st|nd|rd|th)$/, place),
           true <- title != "" do
        [%{rank: String.to_integer(rank), title: title, votes: percent(votes)}]
      else
        _ -> []
      end
    end)
  end

  defp percent(text) do
    case Regex.run(~r/(\d+(?:\.\d+)?)\s*%/, text) do
      [_, n] -> String.to_float(if(n =~ ".", do: n, else: n <> ".0"))
      _ -> nil
    end
  end

  # A cell's words: tags gone, entities read, spaces tidied.
  defp text(cell) do
    cell
    |> String.replace(~r/<[^>]+>/, " ")
    |> unescape()
    |> String.replace(~r/\s+/u, " ")
    |> String.trim()
  end

  @named %{
    "amp" => "&",
    "quot" => "\"",
    "apos" => "'",
    "lt" => "<",
    "gt" => ">",
    "nbsp" => " ",
    "ndash" => "–",
    "mdash" => "—",
    "rsquo" => "’",
    "lsquo" => "‘",
    "rdquo" => "”",
    "ldquo" => "“",
    "hellip" => "…",
    "frac12" => "½"
  }

  @doc false
  def unescape(text) do
    Regex.replace(~r/&(#x[0-9a-fA-F]+|#\d+|[a-zA-Z0-9]+);/, text, fn whole, name ->
      case name do
        "#x" <> hex -> <<String.to_integer(hex, 16)::utf8>>
        "#" <> dec -> <<String.to_integer(dec)::utf8>>
        word -> Map.get(@named, word, whole)
      end
    end)
  end

  # ── the site ──────────────────────────────────────────────────────

  defp get(url) do
    case Req.get(url, headers: [{"user-agent", @ua}], retry: false, receive_timeout: 15_000) do
      {:ok, %{status: 200, body: body}} when is_binary(body) -> {:ok, body}
      {:ok, %{status: 404}} -> {:error, :not_found}
      {:ok, %{status: s}} -> {:error, {:http, s}}
      {:error, e} -> {:error, e}
    end
  end

  defp exists?(url) do
    case Req.head(url, headers: [{"user-agent", @ua}], retry: false, receive_timeout: 15_000, redirect: false) do
      {:ok, %{status: 200}} -> true
      {:ok, %{status: 405}} -> match?({:ok, _}, get(url))
      _ -> false
    end
  rescue
    _ -> false
  end
end
