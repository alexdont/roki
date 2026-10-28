defmodule Roki.Manga.Fabledex do
  @moduledoc """
  Sync from the fabledex.com story-structure API into the local
  `roki_manga_arcs` table — arcs (titles, descriptions, chapter spans),
  volumes (numbers, chapter spans, release dates, covers) and per-chapter units (titles, summaries, characters, page counts).

  Pages never call fabledex: they render the saved row (`get/2`). A
  sync runs when the user hits Refresh (alongside the source scrape),
  and in the background on a details view when the row is missing or
  older than `@stale_after` — so new arcs / chapter titles uploaded to
  fabledex land locally without anyone waiting on the API.

  Story resolution is automatic: the /stories listing carries each
  story's external ids (MAL, AniList, …) and title variants, so a manga
  links via the user's MAL link when it has one, and by title (English /
  romaji / original) otherwise. The listing endpoint ignores query
  filters, so matching happens client-side.

  The token lives in config/fabledex.secret.exs (gitignored), same
  pattern as the MAL credentials in config/mal.secret.exs.
  """

  require Logger

  alias Roki.Manga.Library
  alias Roki.Repo

  @stale_after :timer.hours(24)

  # ── Reading the local copy ──────────────────────────────────────────

  @doc "The saved story row for `{source, slug}`, or nil if never synced."
  def get(source, slug) do
    sql = """
    select a.story_slug, a.story, a.arcs, a.units, a.volumes, a.synced_at
      from roki_manga_arcs a
      join roki_manga_titles t on t.id = a.manga_id
     where t.source = $1 and t.slug = $2
    """

    case Repo.query!(sql, [source, slug]) do
      %{rows: [[story_slug, story, arcs, units, volumes, synced_at]]} ->
        %{
          story_slug: story_slug,
          story: story || %{},
          arcs: arcs || [],
          units: units || [],
          volumes: volumes || [],
          synced_at: synced_at
        }

      _ ->
        nil
    end
  end

  @doc """
  Saved arcs as `%{id, position, title, description, from, to, ongoing}`
  maps sorted by position — `[]` for nil / unmatched rows.
  """
  def arcs(%{arcs: arcs}) when is_list(arcs) do
    arcs
    |> Enum.map(fn a ->
      %{
        id: a["id"],
        position: a["position"],
        title: a["title"],
        named: true,
        description: a["description"],
        from: a["from"],
        to: a["to"],
        ongoing: !!a["ongoing"]
      }
    end)
    |> Enum.sort_by(& &1.position)
  end

  def arcs(_), do: []

  @doc """
  Saved volumes in the same shape as `arcs/1` (so the arc browser can
  show either), sorted by number: `position` is the volume number,
  `title` its name or "Volume N", `named` whether it has a real name
  (a bare "Volume N" is no spoiler), plus `cover_url` and `released_on`.
  Volumes without a chapter span are dropped — nothing to fold into them.
  `[]` for nil / unmatched rows.
  """
  def volumes(%{volumes: volumes}) when is_list(volumes) do
    for v <- volumes || [], is_integer(v["from"]), is_integer(v["to"]) do
      %{
        id: v["id"],
        position: v["number"],
        title: v["title"] || "Volume #{v["number"]}",
        named: is_binary(v["title"]) and v["title"] != "",
        description: v["description"],
        from: v["from"],
        to: v["to"],
        ongoing: !!v["ongoing"],
        cover_url: v["cover_url"],
        released_on: v["released_on"] || v["en_released_on"]
      }
    end
    |> Enum.sort_by(& &1.position)
  end

  def volumes(_), do: []

  @doc "Saved chapter titles as `%{number => title}` (titled units only)."
  def chapter_titles(%{units: units}) when is_list(units) do
    for %{"number" => n, "title" => t} <- units,
        is_integer(n),
        is_binary(t),
        t != "",
        into: %{},
        do: {n, t}
  end

  def chapter_titles(_), do: %{}

  @doc "The arc covering integer chapter `num`, or nil."
  def arc_for(arcs, num) when is_integer(num) do
    Enum.find(arcs, fn a -> num >= a.from and num <= a.to end)
  end

  def arc_for(_arcs, _num), do: nil

  @doc "True when `row` is missing or older than the staleness window."
  def stale?(nil), do: true

  def stale?(%{synced_at: %NaiveDateTime{} = at}) do
    NaiveDateTime.diff(NaiveDateTime.utc_now(), at, :millisecond) > @stale_after
  end

  def stale?(_), do: true

  # ── Syncing ─────────────────────────────────────────────────────────

  @doc """
  Fire-and-forget `sync/3` when `row` is missing or stale. Used on page
  views, so the page renders the saved copy and the fresh one shows up
  on the next load.
  """
  def sync_async_if_stale(row, source, slug, opts) do
    if stale?(row) do
      Task.Supervisor.start_child(Roki.TaskSupervisor, fn -> sync(source, slug, opts) end)
    end

    :ok
  end

  @doc """
  Pull fresh story data from fabledex and save it for `{source, slug}`.
  Options as resolution hints:

    * `:mal_id`     — linked MAL manga id (integer or string)
    * `:anilist_id` — AniList manga id, when a caller has one
    * `:titles`     — title candidates, best first (nils tolerated)
    * `:alt_titles` — the source's alt titles (list, or one delimited
      string as most scrapers store it); tried after `:titles`

  Returns `{:ok, row}` (row.story_slug is nil when nothing matched) or
  `:error` on any API failure — the existing saved row is then left
  untouched, so an outage never wipes local data.
  """
  def sync(source, slug, opts) do
    with {:ok, stories} <- fetch_stories() do
      case match_story(stories, opts) do
        nil ->
          save(source, slug, %{story_slug: nil, story: %{}, arcs: [], volumes: [], units: []})

        story ->
          story_slug = story["slug"]
          q = edition_query(story)

          with {:ok, arcs} <- fetch_list("/api/v1/stories/#{story_slug}/arcs#{q}", "arcs"),
               {:ok, volumes} <-
                 fetch_list("/api/v1/stories/#{story_slug}/volumes#{q}", "volumes"),
               {:ok, units} <- fetch_list("/api/v1/stories/#{story_slug}/units#{q}", "units") do
            save(source, slug, %{
              story_slug: story_slug,
              story: story_summary(story),
              arcs: Enum.map(arcs, &arc_row/1),
              volumes: Enum.map(volumes, &volume_row/1),
              units: Enum.map(units, &unit_row/1)
            })
          else
            _ ->
              Logger.warning(
                "fabledex sync failed for #{source}/#{slug} (story #{story_slug}#{q}); kept saved copy"
              )

              :error
          end
      end
    else
      _ ->
        Logger.warning(
          "fabledex sync failed for #{source}/#{slug} (stories listing); kept saved copy"
        )

        :error
    end
  end

  # Edition param for the arcs / units calls: the story's reading
  # edition by its real slug (it's "manhwa" / "webtoon" on Korean
  # titles, not "manga"). No reading edition → let the API default.
  defp edition_query(story) do
    case reading_editions(story) do
      [%{"slug" => ed} | _] when is_binary(ed) -> "?edition=" <> URI.encode_www_form(ed)
      _ -> ""
    end
  end

  defp save(source, slug, attrs) do
    attrs = Map.put(attrs, :synced_at, NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second))

    id = Library.series_id(source, slug)

    Repo.query!(
      """
      insert into roki_manga_arcs (manga_id, story_slug, story, arcs, units, volumes, synced_at, inserted_at, updated_at)
      values ($1, $2, $3::text::jsonb,
              array(select jsonb_array_elements($4::text::jsonb)),
              array(select jsonb_array_elements($5::text::jsonb)),
              array(select jsonb_array_elements($6::text::jsonb)),
              $7, now(), now())
      on conflict (manga_id) do update
        set story_slug = excluded.story_slug, story = excluded.story, arcs = excluded.arcs,
            units = excluded.units, volumes = excluded.volumes, synced_at = excluded.synced_at,
            updated_at = now()
      """,
      [
        id,
        attrs.story_slug,
        Jason.encode!(attrs.story),
        # One JSON array per column, unpacked into a jsonb[] by Postgres. Note `::text::jsonb`
        # rather than `::jsonb`: a bare jsonb cast makes Postgrex encode the string we pass *as*
        # JSON, so the column ends up holding one long JSON string instead of an array of
        # objects, and every reader then gets text where it expects a map.
        Jason.encode!(attrs.arcs),
        Jason.encode!(attrs.units),
        Jason.encode!(attrs.volumes),
        attrs.synced_at
      ]
    )

    {:ok, get(source, slug)}
  end

  # ── Story matching ──────────────────────────────────────────────────

  @doc false
  def match_story(stories, opts) do
    ids =
      for {kind, id} <- [mal: opts[:mal_id], anilist: opts[:anilist_id]],
          id,
          do: {kind, to_string(id)}

    candidates = (opts[:titles] || []) ++ split_alt_titles(opts[:alt_titles])
    titles = for t <- candidates, is_binary(t), n = normalize(t), n != "", do: n

    Enum.find(stories, fn s -> Enum.any?(ids, &(&1 in external_ids(s))) end) ||
      Enum.find_value(titles, fn t -> Enum.find(stories, &(t in title_keys(&1))) end)
  end

  # Comic editions the reader can line up with chapters — manga,
  # manhwa, manhua, webtoon — in fabledex's position order. Anime
  # editions are excluded: their MAL/AniList ids live in different id
  # namespaces, so matching them would invite collisions.
  @reading_kinds ~w(manga manhwa manhua webtoon)

  defp reading_editions(story) do
    (story["editions"] || [])
    |> Enum.filter(&(&1["kind"] in @reading_kinds))
    |> Enum.sort_by(&(&1["position"] || 0))
  end

  defp external_ids(story) do
    for ed <- reading_editions(story),
        ids = ed["external_ids"],
        is_map(ids),
        {kind, id} <- Map.take(ids, ["mal", "anilist", "kitsu", "mangadex", "mangaupdates"]),
        is_binary(id),
        do: {String.to_atom(kind), id}
  end

  defp title_keys(story) do
    slugs =
      Enum.flat_map(reading_editions(story), fn ed ->
        [get_in(ed, ["external_ids", "mal_slug"]), get_in(ed, ["external_ids", "anilist_slug"])]
      end)

    ([story["title"], story["romaji_title"], story["original_title"], story["slug"]] ++ slugs)
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&normalize/1)
    |> Enum.reject(&(&1 == ""))
  end

  # Scrapers store alt titles as a list or as one string delimited by
  # ";" or "," (often prefixed "Alternative Title:").
  defp split_alt_titles(list) when is_list(list), do: Enum.flat_map(list, &split_alt_titles/1)

  defp split_alt_titles(str) when is_binary(str) do
    str
    |> String.replace(~r/^\s*alternative titles?\s*:/iu, "")
    |> String.split(~r/[;,]/u)
    |> Enum.map(&String.trim/1)
  end

  defp split_alt_titles(_), do: []

  defp normalize(title) do
    title
    |> String.downcase()
    |> String.replace(~r/[^a-z0-9]+/u, " ")
    |> String.trim()
  end

  # ── Row shaping (what gets saved) ───────────────────────────────────

  defp story_summary(story) do
    manga = List.first(reading_editions(story)) || %{}

    %{
      "title" => story["title"],
      "romaji_title" => story["romaji_title"],
      "original_title" => story["original_title"],
      "author" => story["author"],
      "updated_at" => story["updated_at"],
      "status" => manga["status"],
      "units_count" => manga["units_count"],
      "external_ids" => manga["external_ids"] || %{}
    }
  end

  defp arc_row(a) do
    %{
      "id" => a["id"],
      "position" => a["position"],
      "title" => a["title"],
      "description" => a["description"],
      "from" => a["from"],
      "to" => a["to"],
      "ongoing" => !!a["ongoing"]
    }
  end

  defp volume_row(v) do
    Map.take(v, ~w(id number title description from to released_on en_released_on cover_url))
    |> Map.put("ongoing", !!v["ongoing"])
  end

  defp unit_row(u) do
    %{
      "number" => u["number"],
      "title" => u["title"],
      "romaji_title" => u["romaji_title"],
      "original_title" => u["original_title"],
      "summary" => u["summary"],
      "kind" => u["kind"],
      "part" => u["part"],
      "characters" => u["characters"] || [],
      "pages" => get_in(u, ["extra", "pages"]),
      "released_on" => u["released_on"],
      "volume" => u["volume"]
    }
  end

  # ── HTTP ────────────────────────────────────────────────────────────

  defp fetch_stories, do: fetch_list("/api/v1/stories", "stories")

  defp fetch_list(path, key) do
    case get(path) do
      {:ok, %{^key => list}} when is_list(list) -> {:ok, list}
      _ -> :error
    end
  end

  defp get(path) do
    token = Application.get_env(:roki, :fabledex_token)
    base = Application.get_env(:roki, :fabledex_url, "https://fabledex.com")

    with true <- is_binary(token),
         {:ok, %Req.Response{status: 200, body: body}} when is_map(body) <-
           Req.get(base <> path, auth: {:bearer, token}, retry: false, receive_timeout: 8_000) do
      {:ok, body}
    else
      _ -> :error
    end
  end
end
