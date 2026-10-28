defmodule Roki.Manga.KotatsuSource do
  @moduledoc """
  Native-source adapter that makes kotatsu-backed extensions
  first-class citizens of the app: registered in `Sources` under the
  single key `"kotatsu"`, speaking the same three-function contract
  as the hand-written scrapers (`search/1`, `get_manga/1`,
  `get_chapter_images/2`) so the details page, save flow, v3
  readers, progress/stints/chapter counting and history all work
  unchanged.

  The extension and manga identity are carried in the slug:

      "WEEBCENTRAL~<base64url of the kotatsu manga url>"

  Chapter identity: the app models chapters as number strings
  ("85", "10.5"). Kotatsu chapters are objects with float numbers +
  opaque urls, possibly duplicated across branches (translations/
  scanlators) — we keep the dominant branch (preferring English),
  dedupe by number, and keep a number→url index (cached with the
  details) for `get_chapter_images/2`.

  Image URLs handed to the rest of the app are SIDECAR proxy URLs
  (`http://127.0.0.1:8420/sources/NAME/image?url=…`): they are
  fetchable server-side by the reader package's image proxy and the
  dimension prober without any referer/cookie knowledge — the
  sidecar adds the parser's own headers on the way out.
  """

  alias Roki.Manga.Cache
  alias Roki.Manga.MangaSource.Kotatsu

  @details_ttl :timer.minutes(30)

  # ── Slug codec ────────────────────────────────────────────────────
  # "NAME~b64url(manga_url)" — the slug is PURE identity, nothing
  # else, so the same manga can never exist under two slugs. (A
  # legacy 3-part form with an embedded title existed briefly; the
  # third segment is parsed and used as a seed if present.)

  def build_slug(source_name, url) when is_binary(source_name) and is_binary(url) do
    source_name <> "~" <> Base.url_encode64(url, padding: false)
  end

  def parse_slug(slug) when is_binary(slug) do
    with [name | encoded_parts] when encoded_parts != [] <- String.split(slug, "~", parts: 3),
         {:ok, url} <- Base.url_decode64(hd(encoded_parts), padding: false) do
      seed_title =
        case encoded_parts do
          [_, seed] ->
            case Base.url_decode64(seed, padding: false) do
              {:ok, title} -> title
              _ -> nil
            end

          _ ->
            nil
        end

      {:ok, name, url, seed_title}
    else
      _ -> :error
    end
  end

  def parse_slug(_), do: :error

  # ── Title seed registry ───────────────────────────────────────────
  # getDetails on a stateless skeleton may KEEP the seed's fields —
  # several parser families (Madara etc.) never re-parse title/cover
  # in details, so a blank skeleton comes back blank. The seed title
  # travels OUT-OF-BAND instead of in the slug: browse links carry
  # `?st=` (registered here when the details page loads), and saved
  # manga fall back to the stored metadata title.

  @seed_ttl :timer.hours(24)

  def remember_title(name, url, title)
      when is_binary(title) and title != "" and is_binary(name) and is_binary(url) do
    if :ets.whereis(Cache) != :undefined do
      :ets.insert(
        Cache,
        {{:kotatsu_seed, name, url}, title, System.monotonic_time(:millisecond) + @seed_ttl}
      )
    end

    :ok
  end

  def remember_title(_, _, _), do: :ok

  defp registered_title(name, url) do
    with ref when ref != :undefined <- :ets.whereis(Cache),
         [{_, title, expiry}] <- :ets.lookup(Cache, {:kotatsu_seed, name, url}),
         true <- expiry > System.monotonic_time(:millisecond) do
      title
    else
      _ -> nil
    end
  end

  defp metadata_title(slug) do
    case Roki.Manga.Library.get_manga_metadata("kotatsu", slug) do
      %{data: %{"title" => t}} when is_binary(t) and t != "" -> t
      _ -> nil
    end
  end

  # Any user's saved row carries the title too — covers titles that
  # entered the library without a metadata row (e.g. via migration).
  defp saved_title(slug) do
    import Ecto.Query, only: [from: 2]

    Roki.Repo.one(
      from s in Roki.Manga.Library.SavedManga,
        where: s.source == "kotatsu" and s.slug == ^slug and s.title != "",
        limit: 1,
        select: s.title
    )
  end

  defp seed_title_for(name, url, slug, slug_seed) do
    non_empty(slug_seed) || registered_title(name, url) || metadata_title(slug) ||
      saved_title(slug)
  end

  # ── Native source contract ────────────────────────────────────────

  @doc """
  Cross-extension text search is done per-extension on the search
  page (`MangaController.search`'s kotatsu fan-out) — the aggregate
  "kotatsu" source itself has nothing sensible to search.
  """
  def search(_query), do: {:ok, []}

  def get_manga(slug) do
    with {:ok, name, url, slug_seed} <- parse_slug(slug),
         seed_title = seed_title_for(name, url, slug, slug_seed),
         {:ok, manga, index} <- cached_details(name, url, seed_title),
         {:title, title} when title != "" <-
           {:title, non_empty(manga.title) || non_empty(seed_title) || ""} do
      {:ok,
       %{
         title: title,
         cover_url: sidecar_image_url(name, manga.cover_url),
         alt_titles: nil,
         status: state_label(manga.state),
         reading_direction: nil,
         reading_mode: detect_reading_mode(manga.tags),
         written_by: if(manga.authors != [], do: Enum.join(manga.authors, ", ")),
         illustrated_by: nil,
         year: nil,
         genres: manga.tags,
         synopsis: strip_html(manga.description),
         chapters: Enum.map(index, &elem(&1, 0)),
         chapter_dates: chapter_dates(index)
       }}
    else
      :error -> {:error, "Invalid kotatsu slug"}
      # Parser kept the blank seed and we have no seed title — an
      # honest failure beats a row that silently fails validation.
      {:title, _} -> {:error, "Source returned no title"}
      {:error, reason} -> {:error, source_error(reason)}
    end
  end

  def get_chapter_images(slug, chapter) do
    with {:ok, name, url, slug_seed} <- parse_slug(slug),
         seed_title = seed_title_for(name, url, slug, slug_seed),
         {:ok, _manga, index} <- cached_details(name, url, seed_title),
         {_num, ch, _} <- List.keyfind(index, chapter, 0) || :no_chapter,
         {:ok, pages} <- Kotatsu.pages(name, ch.url) do
      {:ok, Enum.map(pages, &sidecar_image_url(name, &1.image_url))}
    else
      :error -> {:error, "Invalid kotatsu slug"}
      :no_chapter -> {:error, "Chapter not found"}
      {:error, reason} -> {:error, source_error(reason)}
    end
  end

  # ── Details cache ─────────────────────────────────────────────────
  # Cache.fetch caches whatever the fn returns — including errors. A
  # cached error triggers one fresh attempt per call (and replaces
  # the cache entry on success), so transient failures never stick
  # for the whole TTL.

  defp cached_details(name, url, seed_title) do
    key = {:kotatsu_details, name, url}
    cached = Cache.fetch(key, @details_ttl, fn -> fetch_details(name, url, seed_title) end)

    if retry_cached?(cached, seed_title) do
      case fetch_details(name, url, seed_title) do
        {:ok, _, _} = ok ->
          if :ets.whereis(Cache) != :undefined do
            :ets.insert(Cache, {key, ok, System.monotonic_time(:millisecond) + @details_ttl})
          end

          ok

        error ->
          # keep serving the cached value if it was at least ok
          case cached do
            {:ok, _, _} -> cached
            _ -> error
          end
      end
    else
      cached
    end
  end

  # Retry past a cached value when it's an error, or when it's a
  # degraded success (blank title / no cover — e.g. cached before a
  # seed title was available to recover them with).
  defp retry_cached?({:ok, manga, _}, seed_title) do
    (non_empty(manga.title) == nil or non_empty(manga.cover_url) == nil) and
      non_empty(seed_title) != nil
  end

  defp retry_cached?(_error, _seed_title), do: true

  defp fetch_details(name, url, seed_title) do
    case Kotatsu.details(%{source: name, url: url}) do
      {:ok, manga, chapters} ->
        # Bake the seed into the record so the cache holds a usable
        # entry (and retry_cached? stops re-fetching it).
        manga = %{manga | title: non_empty(manga.title) || non_empty(seed_title) || ""}
        {:ok, recover_cover(manga, name, url, seed_title), chapter_index(chapters)}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Some parsers (Madara-family sites in particular) only carry covers
  # on LIST pages and return none from details — but the app requires
  # a cover to save a manga. Recover it from the extension's own
  # search results, matched by url. Best-effort; cached with the
  # details either way.
  defp recover_cover(%{cover_url: cover} = manga, _name, _url, _seed)
       when is_binary(cover) and cover != "",
       do: manga

  defp recover_cover(manga, name, url, seed_title) do
    with title when is_binary(title) and title != "" <-
           non_empty(manga.title) || non_empty(seed_title),
         {:ok, results} <- Kotatsu.search(name, title, 1),
         %{cover_url: cover} when is_binary(cover) and cover != "" <-
           Enum.find(results, &(&1.ref.url == url)) || Enum.find(results, &(&1.title == title)) do
      %{manga | cover_url: cover}
    else
      _ -> manga
    end
  end

  defp non_empty(s) when is_binary(s) and s != "", do: s
  defp non_empty(_), do: nil

  # Build the app-facing chapter list: dominant branch → dedupe by
  # formatted number → [{number_string, chapter, seq}] in reading
  # order. Chapters without usable numbers fall back to their
  # sequence position so oneshots/extras still get stable ids.
  defp chapter_index(chapters) do
    branch = dominant_branch(chapters)

    chapters
    |> Enum.filter(&(&1.branch == branch))
    |> order_ascending()
    |> Enum.with_index(1)
    |> Enum.map(fn {ch, seq} ->
      num = if ch.number > 0, do: format_number(ch.number), else: Integer.to_string(seq)
      {num, ch, seq}
    end)
    |> Enum.uniq_by(&elem(&1, 0))
  end

  # The app's convention (and the strip reader's auto-append) is
  # oldest-first, but some parsers return newest-first — which made
  # "scroll past the end" load the PREVIOUS chapter. Detect direction
  # by chapter numbers (fallback: upload dates) and flip when needed.
  defp order_ascending(list) do
    numbered = Enum.filter(list, &(&1.number > 0))

    descending? =
      case numbered do
        [first | _] when length(numbered) >= 2 ->
          first.number > List.last(numbered).number

        _ ->
          case {List.first(list), List.last(list)} do
            {%{uploaded_at: %DateTime{} = a}, %{uploaded_at: %DateTime{} = b}} ->
              DateTime.compare(a, b) == :gt

            _ ->
              false
          end
      end

    if descending?, do: Enum.reverse(list), else: list
  end

  defp dominant_branch(chapters) do
    chapters
    |> Enum.frequencies_by(& &1.branch)
    |> Enum.sort_by(fn {branch, count} ->
      english? = is_binary(branch) and String.match?(branch, ~r/en/i)
      {if(branch == nil or english?, do: 0, else: 1), -count}
    end)
    |> case do
      [{branch, _} | _] -> branch
      [] -> nil
    end
  end

  defp format_number(n) do
    if n == trunc(n), do: Integer.to_string(trunc(n)), else: to_string(n)
  end

  defp chapter_dates(index) do
    for {num, ch, _} <- index, ch.uploaded_at != nil, into: %{} do
      {num, Calendar.strftime(ch.uploaded_at, "%b %-d, %Y")}
    end
  end

  # ── Helpers ───────────────────────────────────────────────────────

  def sidecar_image_url(_name, nil), do: nil
  def sidecar_image_url(_name, ""), do: nil

  def sidecar_image_url(name, url) do
    base = Application.get_env(:roki, :kotatsu_url, "http://127.0.0.1:8420")
    base <> "/sources/" <> URI.encode(name) <> "/image?url=" <> URI.encode_www_form(url)
  end

  @doc "True when a URL points at the kotatsu sidecar's image proxy."
  def sidecar_image_url?(url) when is_binary(url) do
    base = Application.get_env(:roki, :kotatsu_url, "http://127.0.0.1:8420")
    String.starts_with?(url, base <> "/sources/")
  end

  def sidecar_image_url?(_), do: false

  defp state_label(:ongoing), do: "Ongoing"
  defp state_label(:finished), do: "Completed"
  defp state_label(:abandoned), do: "Cancelled"
  defp state_label(:paused), do: "On Hiatus"
  defp state_label(:upcoming), do: "Upcoming"
  defp state_label(_), do: nil

  @scroll_tags ~w(manhwa manhua webtoon long strip webcomic)

  defp detect_reading_mode(tags) do
    scroll? =
      Enum.any?(tags || [], fn tag ->
        t = String.downcase(tag)
        Enum.any?(@scroll_tags, &String.contains?(t, &1))
      end)

    if scroll?, do: "scroll", else: "paged"
  end

  defp strip_html(nil), do: ""

  defp strip_html(html) do
    html
    |> String.replace(~r/<br\s*\/?>/i, "\n")
    |> String.replace(~r/<[^>]*>/, " ")
    |> String.replace("&nbsp;", " ")
    |> String.replace(~r/[ \t]+/, " ")
    |> String.trim()
  end

  defp source_error({:cloudflare, src}), do: "#{src || "Source"} is behind a Cloudflare challenge"
  defp source_error(:not_found), do: "Not found"
  defp source_error(:rate_limited), do: "Rate limited by the source"
  defp source_error({:transport, _}), do: "Extension backend is not running"
  defp source_error({:upstream, %{detail: d}}) when is_binary(d), do: d
  defp source_error(other), do: inspect(other)
end
