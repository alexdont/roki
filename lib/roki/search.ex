defmodule Roki.Search do
  @moduledoc """
  Title search, the way laev's `watch` does it.

  * **Spelling variants.** TMDB does not cross-match British and American
    spellings — "In the Grey" is invisible to a "gray" query — so every variant is
    searched and the results merged.
  * **Year hint.** `heat 1995` ranks 1995 first, 1994 and 1996 next.
  * **IMDb ids.** `tt0113277` resolves to exactly one title.
  * **Ranking.** Exact-title matches first (newest first — a remake outranks the
    original), then TMDB popularity.
  * **Franchises.** On the first page, any curated list or TMDB collection the
    results belong to is offered above them — searching one Alien film offers all
    of Alien.

  Runs in the caller's laev scope when they have connected (their own TMDB key),
  else the site's. What it returns about a user — which results they have seen,
  how far through each list — is worked out afterwards, in their scope; the TMDB
  part is the same for everyone, so it is cached for ten minutes.

  ## Throttling

  The cache absorbs repeats. A miss — an actual TMDB request — spends from two
  budgets: 20 per minute per client (the signed-in user, or the IP) and 300 per
  minute across the whole site. Past either, `{:error, {:rate_limited, seconds}}`
  comes back with how long to wait.
  """

  alias Roki.{Lists, RateLimit, TTLCache}

  @pairs [
    {"gray", "grey"},
    {"color", "colour"},
    {"theater", "theatre"},
    {"harbor", "harbour"},
    {"armor", "armour"},
    {"honor", "honour"}
  ]

  @max_query 120
  @cache_ttl 10 * 60
  @client_limit 20
  @global_limit 300
  @window 60_000
  # Two films of one series is evidence by itself; one is only evidence when it
  # is the best result and a widely-seen one (laev's rule, same number).
  @hint_votes 2_000

  @imdb ~r/^tt\d{6,}$/

  @doc """
  `{:ok, items, more?, franchises, seen}` — `franchises` are list summaries with
  `:watched`, `seen` a set of `{type, id}` — or `{:error, reason}`.
  """
  def search(client, uuid, query, page \\ 1) when is_integer(page) and page >= 1 do
    q = clean(query)

    if q == "" do
      {:ok, [], false, [], MapSet.new()}
    else
      with {:ok, {items, more?, franchises}} <-
             TTLCache.fetch({:search, canonical(q), page}, @cache_ttl, fn ->
               upstream(client, uuid, q, page)
             end) do
        {:ok, Roki.Laev.annotate(uuid, items), more?, Lists.with_progress(uuid, franchises),
         Roki.Laev.seen_keys(uuid, items)}
      end
    end
  end

  @doc false
  def clean(query) do
    query
    |> to_string()
    |> String.replace(~r/\s+/, " ")
    |> String.trim()
    |> String.slice(0, @max_query)
  end

  defp upstream(client, uuid, q, page) do
    with :ok <- RateLimit.check(:search, client, @client_limit, @window),
         :ok <- RateLimit.check(:search_global, :all, @global_limit, @window) do
      Roki.Laev.public(uuid, fn -> lookup(uuid, q, page) end)
    end
  end

  defp lookup(uuid, q, page) do
    if Regex.match?(@imdb, q), do: imdb(uuid, q), else: text(uuid, q, page)
  end

  defp imdb(uuid, id) do
    case Laev.Tmdb.find_imdb(id) do
      {:ok, title} -> {:ok, {[title], false, franchises(uuid, [title])}}
      {:error, :not_found} -> {:ok, {[], false, []}}
      error -> error
    end
  end

  defp text(uuid, q, page) do
    {text, year} = split_year(q)

    answers = Enum.map(spelling_variants(text), &Laev.Tmdb.search(&1, page))

    case Enum.filter(answers, &match?({:ok, _, _}, &1)) do
      [] ->
        List.first(answers)

      oks ->
        results = oks |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq_by(&{&1.type, &1.id})
        more? = Enum.any?(oks, &elem(&1, 2))
        titles = rank_titles(results, text, year)
        {:ok, {titles, more?, if(page == 1, do: franchises(uuid, titles), else: [])}}
    end
  end

  # ── ported from laev (private there) ───────────────────────────────

  @doc false
  def split_year(query) do
    case Regex.run(~r/^(.*?)\s+((?:19|20)\d{2})\s*$/, String.trim(query)) do
      [_, rest, year] when rest != "" -> {rest, String.to_integer(year)}
      _ -> {query, nil}
    end
  end

  @doc false
  def spelling_variants(q) do
    d = String.downcase(q)

    extra =
      Enum.flat_map(@pairs, fn {a, b} ->
        cond do
          String.contains?(d, a) -> [String.replace(d, a, b)]
          String.contains?(d, b) -> [String.replace(d, b, a)]
          true -> []
        end
      end)

    Enum.uniq([q | extra])
  end

  @doc false
  def canonical(s) do
    d = s |> String.trim() |> String.downcase()
    Enum.reduce(@pairs, d, fn {a, b}, acc -> String.replace(acc, b, a) end)
  end

  # Exact-title matches first (newest first), then the rest by popularity. A
  # requested year trumps both, softly (±1: release dates shift between regions).
  @doc false
  def rank_titles(titles, query, year) do
    q = canonical(query)

    Enum.sort_by(titles, fn t ->
      yr = t.year && String.to_integer(t.year)

      year_rank =
        cond do
          year == nil -> 0
          yr == year -> 0
          is_integer(yr) and abs(yr - year) <= 1 -> 1
          true -> 2
        end

      if canonical(t.title || "") == q do
        {year_rank, 0, -(yr || 0)}
      else
        {year_rank, 1, -(t.popularity || 0)}
      end
    end)
  end

  # ── franchises ─────────────────────────────────────────────────────

  # Curated lists the results belong to, then TMDB's own collection when the
  # results point at one; smallest list first.
  defp franchises(uuid, titles) do
    (Laev.Franchises.detect(titles) ++ List.wrap(collection_franchise(uuid, titles)))
    |> Enum.uniq_by(& &1.name)
    |> Enum.sort_by(&length(&1.entries))
    |> Enum.map(&Lists.summary/1)
  end

  defp collection_franchise(uuid, titles) do
    with id when is_integer(id) <- likeliest_collection(titles),
         {:ok, franchise} <- Lists.tmdb_collection(id, uuid) do
      franchise
    else
      _ -> nil
    end
  end

  # The series most of the first page's films belong to; the best-ranked breaks a
  # tie. "dead man's chest" offers Pirates of the Caribbean; "pirate", which
  # returns obscure films of that name, does not dress one of them up as the answer.
  defp likeliest_collection(titles) do
    titles
    |> Enum.filter(&(&1.type == "movie"))
    |> Enum.take(8)
    |> Laev.Scope.async_stream(&collection_id_of/1,
      max_concurrency: 8,
      timeout: 15_000,
      on_timeout: :kill_task
    )
    |> Enum.with_index()
    |> Enum.flat_map(fn
      {{:ok, {id, votes}}, rank} when is_integer(id) -> [{id, {rank, votes}}]
      _ -> []
    end)
    |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
    |> Enum.max_by(fn {_id, hits} -> {length(hits), -best_rank(hits)} end, fn -> nil end)
    |> case do
      {id, hits} -> if convincing?(hits), do: id
      nil -> nil
    end
  end

  defp best_rank(hits), do: hits |> Enum.map(&elem(&1, 0)) |> Enum.min()

  defp convincing?(hits) do
    length(hits) > 1 or
      Enum.any?(hits, fn {rank, votes} -> rank == 0 and votes >= @hint_votes end)
  end

  defp collection_id_of(%{id: id}) do
    case Laev.Tmdb.movie(id) do
      {:ok, %{"belongs_to_collection" => %{"id" => collection_id}} = details} ->
        {collection_id, details["vote_count"] || 0}

      _ ->
        nil
    end
  end
end
