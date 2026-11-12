defmodule Roki.Search do
  @moduledoc """
  Title search, the way laev's `watch` does it — the rules are laev's own (`Laev.Search`,
  public since 0.1.55: what a query asks for, the spelling variants TMDB will not cross-match,
  the year hint, the ranking), run here in the site's scopes with the site's throttling.

  * **Spelling variants.** "In the Grey" is invisible to a "gray" query, so every variant is
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

  @max_query 120
  @cache_ttl 10 * 60
  @client_limit 20
  @global_limit 300
  @window 60_000
  # Two films of one series is evidence by itself; one is only evidence when it
  # is the best result and a widely-seen one (laev's rule, same number).
  @hint_votes 2_000

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
               with {:ok, {items, _, _}} = found <- upstream(client, uuid, q, page) do
                 Roki.Titles.remember_later(items)
                 found
               end
             end) do
        {:ok, Roki.Laev.annotate(uuid, items), more?, Lists.with_progress(uuid, franchises),
         Roki.Laev.seen_keys(uuid, items)}
      end
    end
  end

  @doc """
  Search, keeping only the titles of one genre. TMDB's search cannot filter, and laev drops the
  genre ids from its results, so each result page's titles have their genres read once
  (`Roki.Genres`, kept) and are filtered here. A page can hold few of one genre, so a call reads
  on until it has `@genre_want` titles, the end, or `@genre_pages` pages. With `exact` it is the
  pages `1..exact` and nothing more (coming back to a list that had that many).

  `{:ok, items, more?, franchises, seen, last_page}`: `last_page` is how far it read, which is the
  next call's start. No franchise lists: they are not filtered by genre.
  """
  def search_genre(client, uuid, query, from, genre, exact \\ nil) do
    if exact do
      results = RokiWeb.Place.pages(exact, &genre_page(client, uuid, query, &1, genre))

      case Enum.find(results, &(not match?({:ok, _, _, _}, &1))) do
        nil ->
          items = Enum.flat_map(results, fn {:ok, items, _, _} -> items end)
          {:ok, _, more?, _} = List.last(results)

          seen =
            Enum.reduce(results, MapSet.new(), fn {:ok, _, _, s}, acc -> MapSet.union(acc, s) end)

          {:ok, items, more?, [], seen, exact}

        error ->
          error
      end
    else
      genre_collect(client, uuid, query, from, genre, from, [], MapSet.new())
    end
  end

  @genre_want 8
  @genre_pages 5

  defp genre_collect(client, uuid, query, page, genre, from, acc, seen) do
    case genre_page(client, uuid, query, page, genre) do
      {:ok, items, more?, s} ->
        acc = acc ++ items
        seen = MapSet.union(seen, s)

        if more? and length(acc) < @genre_want and page - from + 1 < @genre_pages,
          do: genre_collect(client, uuid, query, page + 1, genre, from, acc, seen),
          else: {:ok, acc, more?, [], seen, page}

      error ->
        error
    end
  end

  defp genre_page(client, uuid, query, page, genre) do
    with {:ok, items, more?, _franchises, seen} <- search(client, uuid, query, page) do
      keys = for i <- items, do: {i.type, i.id}
      Roki.Genres.fill(keys, uuid, 60)
      known = Roki.Genres.known(keys)
      kept = Enum.filter(items, &Roki.Genres.match?(genre, &1.type, known[{&1.type, &1.id}]))
      {:ok, kept, more?, seen}
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
    case Laev.Search.parse(q) do
      %{imdb_id: id} when is_binary(id) -> imdb(uuid, id)
      parsed -> text(uuid, parsed, page)
    end
  end

  defp imdb(uuid, id) do
    case Laev.Tmdb.find_imdb(id) do
      {:ok, title} -> {:ok, {[title], false, franchises(uuid, "", [title])}}
      {:error, :not_found} -> {:ok, {[], false, []}}
      error -> error
    end
  end

  defp text(uuid, %{title: text, year: year}, page) do
    answers = Enum.map(Laev.Search.variants(text), &Laev.Tmdb.search(&1, page))

    case Enum.filter(answers, &match?({:ok, _, _}, &1)) do
      [] ->
        List.first(answers)

      oks ->
        results = oks |> Enum.flat_map(&elem(&1, 1)) |> Enum.uniq_by(&{&1.type, &1.id})
        more? = Enum.any?(oks, &elem(&1, 2))
        titles = Laev.Search.rank(results, text, year)
        {:ok, {titles, more?, if(page == 1, do: franchises(uuid, text, titles), else: [])}}
    end
  end

  @doc "A title reduced to one spelling and one case (`Laev.Search.canonical/1`): the cache's key."
  defdelegate canonical(title), to: Laev.Search

  # ── franchises ─────────────────────────────────────────────────────

  # First the lists the search names itself ("marvel", "star wars the last jedi" — the results
  # need not belong to them: a list is found by its name), then the curated lists the results
  # belong to and TMDB's own collection when the results point at one, smallest first.
  defp franchises(uuid, query, titles) do
    named = Lists.matching(query)

    found =
      (Laev.Franchises.detect(titles) ++ List.wrap(collection_franchise(uuid, titles)))
      |> Enum.sort_by(&length(&1.entries))

    (named ++ found)
    |> Enum.uniq_by(& &1.name)
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
