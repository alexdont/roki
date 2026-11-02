defmodule Roki.Manga.Library do
  import Ecto.Query
  require Logger
  alias Roki.Repo
  alias Roki.Manga.Library.SavedManga
  alias Roki.Manga.Library.ReadingActivity
  alias Roki.Manga.Library.ChapterRead
  alias Roki.Manga.Library.LibraryEvent
  alias Roki.Manga.Library.MangaAnnotation
  alias Roki.Manga.Library.MangaMetadata
  alias Roki.Manga.Library.MangaMalLink
  alias Roki.Manga.Library.MangaTrackerToken
  alias Roki.Manga.Library.MangaCategory
  alias Roki.Manga.Library.MangaCategoryMembership
  alias Roki.Manga.Library.MangaTierlist
  alias Roki.Manga.Library.MangaGridSlot
  alias Roki.Manga.Library.PageOverride

  @tierlist_tiers ~w(sp s a b c d e unknown want pool)
  def tierlist_tiers, do: @tierlist_tiers

  @grid_modes ~w(overall manga manhwa)
  def grid_modes, do: @grid_modes

  @grid_default_labels [
    "Favorite",
    "Best Art",
    "First Manga",
    "Currently Reading",
    "Best Villain",
    "Best Plot Twist",
    "Underrated Gem",
    "Comfort Manga",
    "Best Fight",
    "Most Emotional",
    "Best Ending",
    "Best Opening",
    "Best Comeback",
    "Most Read",
    "Worst"
  ]
  def grid_default_labels, do: @grid_default_labels

  def manga_readers(source, slug, exclude_user_id) do
    from(s in SavedManga,
      join: u in "phoenix_kit_users",
      on: u.uuid == s.user_id,
      where: s.source == ^source and s.slug == ^slug,
      where: s.user_id != ^exclude_user_id,
      select: %{
        user_id: s.user_id,
        username: u.username,
        avatar_file_uuid: fragment("?->>'avatar_file_uuid'", u.custom_fields),
        last_chapter: s.last_chapter,
        last_page: s.last_page,
        updated_at: s.updated_at
      },
      order_by: [desc: s.updated_at],
      limit: 20
    )
    |> Repo.all()
  end

  @doc """
  Saved manga where the user has caught up to the latest scraped
  chapter — mirrors the home page's `isCaughtUp` JS predicate:
  not completed, `last_chapter` parses as a number, and that floor is
  ≥ `last_chapter_number` (or `total_chapters` when last_chapter_number
  is unset). Used by the bulk sync to know which titles to re-scrape.
  """
  def list_caught_up_saved_manga(user_id) do
    SavedManga
    |> where([s], s.user_id == ^user_id)
    |> where([s], s.completed == false or is_nil(s.completed))
    |> where([s], not is_nil(s.last_chapter))
    |> Repo.all()
    |> Enum.filter(&caught_up?/1)
  end

  defp caught_up?(%{last_chapter: lc} = m) when is_binary(lc) do
    threshold = m.last_chapter_number || m.total_chapters

    case parse_chapter_floor(lc) do
      nil -> false
      n -> is_integer(threshold) and threshold > 0 and n >= threshold
    end
  end

  defp caught_up?(_), do: false

  defp parse_chapter_floor(s) when is_binary(s) do
    case Float.parse(s) do
      {n, _suffix} -> trunc(n)
      :error -> nil
    end
  end

  defp parse_chapter_floor(_), do: nil

  def list_saved_manga(user_id, opts \\ []) do
    query =
      SavedManga
      |> where(user_id: ^user_id)
      |> order_by(desc: :updated_at)

    query =
      case opts[:category_id] do
        nil ->
          query

        id ->
          from s in query,
            join: m in MangaCategoryMembership,
            on: m.saved_manga_id == s.id,
            where: m.category_id == ^id
      end

    # `exclude_category_id` mirrors the JS "click active chip to
    # exclude" cycle: return every saved title EXCEPT those that
    # belong to this category. NOT IN against the membership rows
    # for this category — titles in other categories AND titles
    # with no category at all are kept.
    query =
      case opts[:exclude_category_id] do
        nil ->
          query

        id ->
          excluded_ids =
            from m in MangaCategoryMembership,
              where: m.category_id == ^id,
              select: m.saved_manga_id

          from s in query, where: s.id not in subquery(excluded_ids)
      end

    types = list_mal_media_types(user_id)

    query
    |> Repo.all()
    |> Enum.map(fn m -> %{m | mal_media_type: types[{m.source, m.slug}]} end)
  end

  @doc """
  A user's linked MyAnimeList media types as
  `%{{source, slug} => media_type}` (e.g. "manga" / "manhwa" /
  "manhua"), pulled from the cached link data.
  """
  def list_mal_media_types(user_id) do
    from(l in MangaMalLink,
      where: l.user_id == ^user_id,
      select: {{l.source, l.slug}, fragment("?->>'media_type'", l.data)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  A user's default page padding for the scroll (manhwa) reader, as
  `%{desktop: pct, mobile: pct}` — the shrink percentage the reader's
  padding slider applies, split evenly left/right.

  Defaults to 70% on desktop and 0% on mobile: a wide monitor renders a
  long strip absurdly wide without it, while a phone has no width to give
  away. Both the settings form and the reader read the defaults from here
  so the two can't drift apart.

  Takes the user's `custom_fields` map (or nil, for signed-out readers).
  """
  @default_page_padding %{desktop: 70, mobile: 0}

  def page_padding_defaults(custom_fields) do
    fields = custom_fields || %{}

    Map.new(@default_page_padding, fn {form_factor, fallback} ->
      value = fields["default_page_padding_#{form_factor}"]

      {form_factor,
       if(is_integer(value) and value >= 0 and value <= 90, do: value, else: fallback)}
    end)
  end

  # --- Categories ---

  def list_categories(user_id) do
    MangaCategory
    |> where(user_id: ^user_id)
    |> order_by([c], asc: c.position, asc: c.name)
    |> Repo.all()
  end

  def create_category(user_id, attrs) do
    max_pos =
      MangaCategory
      |> where(user_id: ^user_id)
      |> select([c], max(c.position))
      |> Repo.one() || -1

    %MangaCategory{}
    |> MangaCategory.changeset(Map.merge(attrs, %{user_id: user_id, position: max_pos + 1}))
    |> Repo.insert()
  end

  def reorder_categories(user_id, ordered_ids) do
    ordered_ids
    |> Enum.with_index()
    |> Enum.each(fn {id, pos} ->
      MangaCategory
      |> where(id: ^id, user_id: ^user_id)
      |> Repo.update_all(set: [position: pos])
    end)

    :ok
  end

  def rename_category(id, user_id, new_name) do
    case Repo.get_by(MangaCategory, id: id, user_id: user_id) do
      nil -> {:error, :not_found}
      cat -> cat |> MangaCategory.changeset(%{name: new_name}) |> Repo.update()
    end
  end

  def delete_category(id, user_id) do
    case Repo.get_by(MangaCategory, id: id, user_id: user_id) do
      nil -> {:error, :not_found}
      cat -> Repo.delete(cat)
    end
  end

  def set_manga_category(user_id, source, slug, category_id) do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: [category_id: category_id])
  end

  def toggle_manga_category(saved_manga_id, category_id) do
    case Repo.get_by(MangaCategoryMembership,
           saved_manga_id: saved_manga_id,
           category_id: category_id
         ) do
      nil ->
        %MangaCategoryMembership{}
        |> MangaCategoryMembership.changeset(%{
          saved_manga_id: saved_manga_id,
          category_id: category_id
        })
        |> Repo.insert()

        {:ok, :added}

      membership ->
        Repo.delete(membership)
        {:ok, :removed}
    end
  end

  def list_category_manga_keys(category_id, user_id) do
    SavedManga
    |> join(:inner, [s], m in MangaCategoryMembership, on: m.saved_manga_id == s.id)
    |> where([s, m], s.user_id == ^user_id and m.category_id == ^category_id)
    |> select([s], %{source: s.source, slug: s.slug})
    |> Repo.all()
  end

  def list_manga_category_ids(saved_manga_id) do
    MangaCategoryMembership
    |> where(saved_manga_id: ^saved_manga_id)
    |> select([m], m.category_id)
    |> Repo.all()
  end

  @doc """
  Map of category_id => number of saved manga in it, scoped to the
  user. Drives the count badges on the home page category chips.
  """
  def count_manga_per_category(user_id) do
    from(s in SavedManga,
      join: m in MangaCategoryMembership,
      on: m.saved_manga_id == s.id,
      where: s.user_id == ^user_id,
      group_by: m.category_id,
      select: {m.category_id, count(s.id)}
    )
    |> Repo.all()
    |> Map.new()
  end

  def list_category_memberships(user_id) do
    from(s in SavedManga,
      join: m in MangaCategoryMembership,
      on: m.saved_manga_id == s.id,
      where: s.user_id == ^user_id,
      select: {s.source, s.slug, m.category_id}
    )
    |> Repo.all()
    |> Enum.group_by(fn {src, slug, _} -> {src, slug} end, fn {_, _, c} -> c end)
  end

  def list_reading_stats(user_id) do
    SavedManga
    |> where(user_id: ^user_id)
    |> where(
      [s],
      s.reading_seconds > 0 or s.reading_seconds_adjusted > 0 or s.reading_seconds_offsite > 0
    )
    |> order_by(
      [s],
      desc:
        coalesce(s.reading_seconds_adjusted, s.reading_seconds) +
          coalesce(s.reading_seconds_offsite, 0)
    )
    |> Repo.all()
  end

  @doc """
  What this account has read, all in: `%{seconds:, series:, chapters:}`.

  `seconds` is the reader's own timing plus time entered by hand for reading done elsewhere —
  the same figure the stats page shows for manga — and `series` is how many series that spans.

  `chapters` is the chapter each of those series is up to, added together. That is deliberately
  not the number of chapters the reader has logged as finished: most of what an account has read
  was read before the reader existed (one series alone is at chapter 331 with two hours timed
  here), so the logged count says 569 where the answer is 8,422. A label that is not a number —
  "Extra", "Oneshot" — counts as nothing rather than as an error.
  """
  def reading_totals(user_uuid) do
    from(s in SavedManga,
      where: s.user_id == ^user_uuid,
      where:
        s.reading_seconds > 0 or s.reading_seconds_adjusted > 0 or s.reading_seconds_offsite > 0,
      select: %{
        seconds:
          type(
            coalesce(
              sum(
                coalesce(s.reading_seconds_adjusted, s.reading_seconds) +
                  coalesce(s.reading_seconds_offsite, 0)
              ),
              0
            ),
            :integer
          ),
        series: count(s.id),
        chapters:
          type(
            coalesce(
              sum(
                coalesce(
                  fragment("nullif(substring(? from '^[0-9]+'), '')::int", s.last_chapter),
                  0
                )
              ),
              0
            ),
            :integer
          )
      }
    )
    |> Repo.one()
  end

  @doc """
  Snap the user's `last_chapter` forward to `chapter`. Used by the
  "Continue from Ch. N" jump-ahead button on the manga details page so
  one click advances the resume pointer instead of leaving it on the
  older re-reading position.

  Idempotent and forward-only: no-op when the user has no saved entry,
  when `last_chapter` is already at-or-past `chapter`, or when the URL
  param somehow comes back stale on a refresh. Snapshots the prior
  `last_chapter` / `chapter_seconds` into the `prev_*` slots so the
  existing "swap to previous chapter" flow can still get you back to
  the re-read position with one tap.
  """
  def snap_to_chapter(user_id, source, slug, chapter, user_timezone \\ nil) do
    saved =
      SavedManga
      |> where(user_id: ^user_id, source: ^source, slug: ^slug)
      |> select([s], %{
        last_chapter: s.last_chapter,
        chapter_seconds: s.chapter_seconds,
        chapter_near_end: s.chapter_near_end,
        last_chapter_number: s.last_chapter_number,
        total_chapters: s.total_chapters
      })
      |> Repo.one()

    cond do
      is_nil(saved) ->
        :noop

      is_nil(saved.last_chapter) ->
        do_snap(user_id, source, slug, chapter, saved, user_timezone)

      chapter_gt?(chapter, saved.last_chapter) ->
        do_snap(user_id, source, slug, chapter, saved, user_timezone)

      true ->
        :noop
    end
  end

  defp do_snap(user_id, source, slug, chapter, saved, user_timezone) do
    now = DateTime.utc_now()

    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(
      set: [
        last_chapter: chapter,
        last_page: nil,
        # NOT NULL DEFAULT 0.0 (migration 20260520215302) — reset to the
        # column's natural zero rather than nil, which would violate the
        # constraint and 500 the controller.
        last_page_fraction: 0.0,
        last_chapter_total_pages: nil,
        chapter_seconds: 0,
        chapter_near_end: false,
        prev_chapter: saved.last_chapter,
        prev_chapter_seconds: saved.chapter_seconds || 0,
        prev_chapter_near_end: saved.chapter_near_end || false,
        visiting_chapter: nil,
        visiting_seconds: 0,
        completed: false,
        updated_at: now
      ]
    )

    # Milestone log: a forward snap can also be the moment the title
    # crosses into the caught-up category (see update_progress).
    thresholds = %{
      last_chapter_number: saved.last_chapter_number,
      total_chapters: saved.total_chapters
    }

    if not caught_up?(Map.put(thresholds, :last_chapter, saved.last_chapter)) and
         caught_up?(Map.put(thresholds, :last_chapter, chapter)) do
      log_caught_up(user_id, source, slug, chapter, user_timezone)
    end

    :ok
  end

  @doc """
  Returns the user's leaderboard position for `{source, slug}` as
  `{rank, total}` (1-indexed), or `nil` when the manga has no recorded
  reading time. Ranking mirrors `list_reading_stats/1`: descending by
  on-site (adjusted ?? raw) + off-site seconds.
  """
  def user_reading_rank(user_id, source, slug) do
    stats = list_reading_stats(user_id)

    case Enum.find_index(stats, &(&1.source == source and &1.slug == slug)) do
      nil -> nil
      idx -> {idx + 1, length(stats)}
    end
  end

  @doc """
  Everything this person has read, with the tier they gave it — what the profile's manga shelf
  picks from. A series counts as read once a chapter has been opened.
  """
  def list_read_history(user_uuid) do
    from(s in SavedManga,
      left_join: t in MangaTierlist,
      on: t.user_id == s.user_id and t.source == s.source and t.slug == s.slug,
      where: s.user_id == type(^user_uuid, Ecto.UUID),
      where: not is_nil(s.last_chapter),
      order_by: [desc: s.updated_at],
      select: %{
        id: s.id,
        source: s.source,
        slug: s.slug,
        title: s.title,
        cover_url: s.cover_url,
        cover_file_uuid: s.cover_file_uuid,
        updated_at: s.updated_at,
        tier: t.tier
      }
    )
    |> Repo.all()
  end

  @doc "Saved series by the reader's own ids — what a manga favourite points at."
  def list_saved_by_ids([]), do: []

  def list_saved_by_ids(ids) do
    from(s in SavedManga,
      where: s.id in ^ids,
      select: %{
        id: s.id,
        source: s.source,
        slug: s.slug,
        title: s.title,
        cover_url: s.cover_url,
        cover_file_uuid: s.cover_file_uuid
      }
    )
    |> Repo.all()
  end

  @doc """
  What this person is actually in the middle of — the reader's own "Reading" state: a chapter
  opened, not finished, and not already caught up with what the source has published. Most
  recently read first.

  Caught up is left out on purpose: there is nothing to carry on with until a new chapter
  arrives, and the thing is waiting rather than waiting on you.
  """
  def list_reading(user_uuid, limit \\ 1) do
    from(s in SavedManga,
      where: s.user_id == type(^user_uuid, Ecto.UUID),
      where: not is_nil(s.last_chapter) and s.last_chapter != "",
      where: s.completed == false,
      order_by: [desc: s.updated_at]
    )
    |> Repo.all()
    |> Enum.reject(&caught_up?/1)
    |> Enum.take(limit)
  end

  @doc """
  What this person is in the middle of, most recently read first — the reading row on their
  own shelf. A series is in the middle of it once a chapter has been opened and until it is
  marked finished.
  """
  def list_continue_reading(user_uuid, limit \\ 12) do
    from(s in SavedManga,
      where: s.user_id == type(^user_uuid, Ecto.UUID),
      where: not is_nil(s.last_chapter),
      where: s.completed == false,
      order_by: [desc: s.updated_at],
      limit: ^limit,
      select: %{
        source: s.source,
        slug: s.slug,
        title: s.title,
        cover_url: s.cover_url,
        cover_file_uuid: s.cover_file_uuid,
        last_chapter: s.last_chapter
      }
    )
    |> Repo.all()
  end

  @doc """
  One person's saved manga whose title matches, newest reading first — what this site's own
  search shows under Manga, so a title someone is already reading is found from the same box
  as a film.
  """
  def search_saved(user_uuid, query, limit \\ 12) do
    q = "%" <> query <> "%"

    from(s in SavedManga,
      where: s.user_id == type(^user_uuid, Ecto.UUID),
      where: ilike(s.title, ^q),
      order_by: [desc: s.updated_at],
      limit: ^limit,
      select: %{
        source: s.source,
        slug: s.slug,
        title: s.title,
        cover_url: s.cover_url,
        cover_file_uuid: s.cover_file_uuid
      }
    )
    |> Repo.all()
  end

  def search_saved_across_users(query, limit \\ 30) do
    q = "%" <> query <> "%"

    from(s in SavedManga,
      where: ilike(s.title, ^q),
      group_by: [s.source, s.slug],
      select: %{
        source: s.source,
        slug: s.slug,
        title: max(s.title),
        cover_url: max(s.cover_url),
        users: count(s.user_id, :distinct),
        updated_at: max(s.updated_at)
      },
      order_by: [desc: count(s.user_id, :distinct), desc: max(s.updated_at)],
      limit: ^limit
    )
    |> Repo.all()
  end

  def list_explore() do
    SavedManga
    |> group_by([s], [s.source, s.slug])
    |> select([s], %{
      source: s.source,
      slug: s.slug,
      title: max(s.title),
      cover_url: max(s.cover_url),
      reader_count: count(s.id),
      total_seconds: sum(s.reading_seconds)
    })
    |> order_by([s], desc: count(s.id), desc: sum(s.reading_seconds))
    |> Repo.all()
  end

  def list_reading_history(user_id) do
    SavedManga
    |> where(user_id: ^user_id)
    |> where([s], not is_nil(s.last_chapter))
    |> order_by(desc: :updated_at)
    |> Repo.all()
  end

  def list_reading_history_for_date(user_id, date) do
    ReadingActivity
    |> where(user_id: ^user_id, date: ^date)
    |> join(:left, [a], s in SavedManga,
      on: s.user_id == a.user_id and s.source == a.source and s.slug == a.slug
    )
    |> group_by([a, s], [a.source, a.slug, a.title, s.cover_url, s.last_chapter, s.last_page])
    |> order_by([a], desc: sum(a.reading_seconds))
    |> select([a, s], %{
      title: a.title,
      source: a.source,
      slug: a.slug,
      reading_seconds: sum(a.reading_seconds),
      chapters_read: sum(a.chapters_read),
      cover_url: s.cover_url,
      last_chapter: s.last_chapter,
      last_page: s.last_page
    })
    |> Repo.all()
  end

  def save_manga(user_id, attrs) do
    # Seed `newest_chapter_at = now` on the first save so freshly-saved
    # series have a real sort key on the home page's "Newest Chapter"
    # column from the moment they appear; subsequent updates only bump
    # the field when total_chapters actually goes up.
    attrs =
      attrs
      |> Map.put(:user_id, user_id)
      |> Map.put_new(:newest_chapter_at, DateTime.utc_now() |> DateTime.truncate(:second))

    result =
      %SavedManga{}
      |> SavedManga.changeset(attrs)
      |> Repo.insert(on_conflict: :nothing)

    # What was tried in the reader before the series was saved is kept with it.
    with {:ok, %{id: id}} when not is_nil(id) <- result,
         %{} = trial <- Roki.Manga.Trial.take(user_id, attrs.source, attrs.slug) do
      SavedManga
      |> where(id: ^id)
      |> Repo.update_all(set: Map.to_list(trial))
    end

    result
  end

  @progress_fields [
    :last_chapter,
    :last_page,
    :last_page_fraction,
    :last_chapter_total_pages,
    :max_chapter,
    :total_chapters,
    :last_chapter_number,
    :chapter_near_end,
    :prev_chapter_near_end,
    :reading_mode,
    :reading_mode_desktop,
    :reading_mode_mobile,
    :reading_direction,
    :reading_rotation,
    :tap_zone_preset,
    :tap_zone_preset_desktop,
    :tap_zone_preset_mobile,
    :smart_crop,
    :comments_visible,
    :completed,
    :newest_chapter_at,
    :chapter_seconds,
    :visiting_seconds,
    :prev_chapter_seconds,
    :visiting_chapter,
    :prev_chapter
  ]

  def migrate_manga(
        user_id,
        {old_source, old_slug},
        {new_source, new_slug, new_title, new_cover_url},
        opts
      ) do
    Repo.transaction(fn ->
      old_saved = get_saved_manga(user_id, old_source, old_slug)
      unless old_saved, do: Repo.rollback(:not_saved)

      save_manga(user_id, %{
        source: new_source,
        slug: new_slug,
        title: new_title,
        cover_url: new_cover_url,
        reading_mode: old_saved.reading_mode,
        total_chapters: old_saved.total_chapters
      })

      new_saved = get_saved_manga(user_id, new_source, new_slug)
      unless new_saved, do: Repo.rollback(:save_failed)

      if opts["migrate_progress"] do
        updates =
          @progress_fields
          |> Enum.map(fn field -> {field, Map.get(old_saved, field)} end)
          |> Enum.reject(fn {_, v} -> is_nil(v) end)

        if updates != [] do
          SavedManga
          |> where(id: ^new_saved.id)
          |> Repo.update_all(set: updates)
        end
      end

      if opts["migrate_categories"] do
        old_memberships =
          MangaCategoryMembership
          |> where(saved_manga_id: ^old_saved.id)
          |> Repo.all()

        Enum.each(old_memberships, fn m ->
          %MangaCategoryMembership{}
          |> MangaCategoryMembership.changeset(%{
            saved_manga_id: new_saved.id,
            category_id: m.category_id
          })
          |> Repo.insert(on_conflict: :nothing)
        end)

        # The single-category column on the row itself, too.
        if old_saved.category_id do
          SavedManga
          |> where(id: ^new_saved.id)
          |> Repo.update_all(set: [category_id: old_saved.category_id])
        end
      end

      if opts["migrate_time"] do
        SavedManga
        |> where(id: ^new_saved.id)
        |> Repo.update_all(
          set: [
            reading_seconds: old_saved.reading_seconds || 0,
            reading_seconds_adjusted: old_saved.reading_seconds_adjusted,
            reading_seconds_offsite: old_saved.reading_seconds_offsite,
            reading_seconds_offsite_approximate: old_saved.reading_seconds_offsite_approximate
          ]
        )

        {:ok, uid_bin} = Ecto.UUID.dump(user_id)

        # Merge conflicting reading activity rows into existing target rows
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          UPDATE reading_activity AS target
          SET reading_seconds = target.reading_seconds + old.reading_seconds,
              chapters_read = target.chapters_read + old.chapters_read
          FROM reading_activity AS old
          WHERE old.user_id = $1 AND old.source = $2 AND old.slug = $3
            AND target.user_id = old.user_id AND target.date = old.date
            AND target.hour = old.hour AND target.source = $4 AND target.slug = $5
          """,
          [uid_bin, old_source, old_slug, new_source, new_slug]
        )

        # Delete old rows that had conflicts (now merged)
        Ecto.Adapters.SQL.query!(
          Repo,
          """
          DELETE FROM reading_activity AS old
          USING reading_activity AS target
          WHERE old.user_id = $1 AND old.source = $2 AND old.slug = $3
            AND target.user_id = old.user_id AND target.date = old.date
            AND target.hour = old.hour AND target.source = $4 AND target.slug = $5
          """,
          [uid_bin, old_source, old_slug, new_source, new_slug]
        )

        # Move remaining non-conflicting rows
        ReadingActivity
        |> where(user_id: ^user_id, source: ^old_source, slug: ^old_slug)
        |> Repo.update_all(set: [source: new_source, slug: new_slug, title: new_title])

        # Sessions, chapter-read events and milestones follow the
        # title so history stays continuous.
        old_item = "manga:#{old_source}/#{old_slug}"
        new_item = "manga:#{new_source}/#{new_slug}"

        from(s in "stints", where: s.owner_id == ^user_id and s.item == ^old_item)
        |> Repo.update_all(set: [item: new_item])

        ChapterRead
        |> where(user_id: ^user_id, source: ^old_source, slug: ^old_slug)
        |> Repo.update_all(set: [source: new_source, slug: new_slug])

        LibraryEvent
        |> where(user_id: ^user_id, source: ^old_source, slug: ^old_slug)
        |> Repo.update_all(set: [source: new_source, slug: new_slug])
      end

      # ── Always-moved (user-created content tied to the title) ─────

      # Tierlist rating: keep the target's rating if it already has
      # one, otherwise the old rating follows the title.
      if Repo.exists?(
           MangaTierlist
           |> where(user_id: ^user_id, source: ^new_source, slug: ^new_slug)
         ) do
        MangaTierlist
        |> where(user_id: ^user_id, source: ^old_source, slug: ^old_slug)
        |> Repo.delete_all()
      else
        MangaTierlist
        |> where(user_id: ^user_id, source: ^old_source, slug: ^old_slug)
        |> Repo.update_all(set: [source: new_source, slug: new_slug])
      end

      # Grid slots.
      MangaGridSlot
      |> where(user_id: ^user_id, source: ^old_source, slug: ^old_slug)
      |> Repo.update_all(set: [source: new_source, slug: new_slug])

      # Marks/comments: retarget the annotation anchors AND the
      # comment metadata (mark listings filter on it).
      MangaAnnotation
      |> where(source: ^old_source, slug: ^old_slug)
      |> where([a], a.user_id == ^user_id)
      |> Repo.update_all(set: [source: new_source, slug: new_slug])

      Ecto.Adapters.SQL.query!(
        Repo,
        """
        UPDATE phoenix_kit_comments
        SET metadata = metadata || jsonb_build_object('source', $1::text, 'slug', $2::text)
        WHERE resource_type = 'manga_mark'
          AND metadata->>'source' = $3 AND metadata->>'slug' = $4
        """,
        [new_source, new_slug, old_source, old_slug]
      )

      # MAL link (per-user) follows the title.
      MangaMalLink
      |> where(user_id: ^user_id, source: ^old_source, slug: ^old_slug)
      |> Repo.update_all(set: [source: new_source, slug: new_slug])

      # Custom cover follows the title.
      if old_saved.cover_file_uuid do
        SavedManga
        |> where(id: ^new_saved.id)
        |> Repo.update_all(set: [cover_file_uuid: old_saved.cover_file_uuid])
      end

      # Delete old saved manga (cascade deletes memberships)
      SavedManga
      |> where(id: ^old_saved.id)
      |> Repo.delete_all()

      :ok
    end)
  end

  def unsave_manga(user_id, source, slug) do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.delete_all()
  end

  def saved?(user_id, source, slug) do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.exists?()
  end

  def get_saved_manga(user_id, source, slug) do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.one()
  end

  def mark_completed(user_id, source, slug, last_chapter \\ nil, user_timezone \\ nil) do
    saved =
      SavedManga
      |> where(user_id: ^user_id, source: ^source, slug: ^slug)
      |> select([s], %{completed: s.completed, last_chapter: s.last_chapter})
      |> Repo.one()

    sets = [completed: true, updated_at: DateTime.utc_now()]

    sets =
      if last_chapter do
        sets ++ [last_chapter: last_chapter, max_chapter: last_chapter]
      else
        sets
      end

    result =
      SavedManga
      |> where(user_id: ^user_id, source: ^source, slug: ^slug)
      |> Repo.update_all(set: sets)

    # Milestone log: only the actual transition, not repeat clicks on
    # an already-completed title. Completing supersedes the day's
    # caught-up (a finished series has nothing left to catch up on),
    # so that event is swept rather than shown alongside.
    if saved && saved.completed != true do
      delete_same_day_caught_up(user_id, source, slug, user_timezone)
      log_library_event(user_id, source, slug, "completed", last_chapter || saved.last_chapter)

      # Reflect completion on the user's MAL list (async, best-effort).
      Task.Supervisor.start_child(Roki.TaskSupervisor, fn ->
        try do
          push_progress_to_mal(user_id, source, slug, last_chapter || saved.last_chapter,
            status: "completed"
          )
        rescue
          e -> Logger.warning("MAL completed push crashed: #{inspect(e)}")
        end
      end)
    end

    result
  end

  def unmark_completed(user_id, source, slug) do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: [completed: false, updated_at: DateTime.utc_now()])
  end

  def update_reading_seconds_adjusted(user_id, source, slug, seconds) do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: [reading_seconds_adjusted: seconds])
  end

  def update_reading_seconds_offsite(user_id, source, slug, seconds, approximate? \\ false) do
    # Clearing the off-site bucket also clears the approximate flag
    # so a future re-entry doesn't inherit a stale checkbox state.
    approx = if is_nil(seconds), do: false, else: !!approximate?

    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(
      set: [reading_seconds_offsite: seconds, reading_seconds_offsite_approximate: approx]
    )
  end

  # Zero the on-site portion: raw tracker, manual override, and the
  # daily/hourly ReadingActivity log (which is the on-site evidence
  # that feeds the stats page). Off-site is preserved.
  def reset_onsite_reading_time(user_id, source, slug) do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: [reading_seconds: 0, reading_seconds_adjusted: nil])

    ReadingActivity
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.delete_all()
  end

  # Zero only the off-site bucket; raw tracker, on-site override, and
  # activity log untouched.
  def reset_offsite_reading_time(user_id, source, slug) do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(
      set: [reading_seconds_offsite: nil, reading_seconds_offsite_approximate: false]
    )
  end

  def reset_all_reading_time(user_id, source, slug) do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(
      set: [
        reading_seconds: 0,
        reading_seconds_adjusted: nil,
        reading_seconds_offsite: nil,
        reading_seconds_offsite_approximate: false
      ]
    )

    ReadingActivity
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.delete_all()
  end

  def update_total_chapters(user_id, source, slug, total, last_chapter_number \\ nil) do
    # Read the existing total first so we can bump `newest_chapter_at`
    # only when the count actually went up — i.e. a new chapter was
    # scraped to the site for this series, not just a page visit. Powers
    # the home page's "Newest Chapter" sort.
    existing_total =
      SavedManga
      |> where(user_id: ^user_id, source: ^source, slug: ^slug)
      |> select([s], s.total_chapters)
      |> Repo.one()

    set =
      [total_chapters: total] ++
        if is_nil(last_chapter_number), do: [], else: [last_chapter_number: last_chapter_number]

    set =
      if is_nil(existing_total) || total > existing_total do
        set ++ [newest_chapter_at: DateTime.utc_now() |> DateTime.truncate(:second)]
      else
        set
      end

    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: set)

    # Returned for `notify_new_chapters/6` so the controller can decide
    # whether to ping the bell. `Repo.update_all`'s `{count, _}` return
    # was previously unused at both call sites.
    {existing_total, total}
  end

  @doc """
  Fires a phoenix_kit bell notification when a refresh / scrape
  discovered new chapters since the last seen count. No-op when:

    * `prev_total` is nil — first time we've ever counted chapters for
      this saved row, so we'd be announcing the BASELINE, not "new".
    * `new_total <= prev_total` — count unchanged or went down (rare,
      happens when a source removes a chapter).

  Caller passes `prev_total / new_total` straight from
  `update_total_chapters/5`. We rescue any error so a downstream
  PhoenixKit hiccup never poisons the refresh flow itself.
  """
  def notify_new_chapters(_user_uuid, _source, _slug, _title, nil, _new_total), do: :ok

  def notify_new_chapters(_user_uuid, _source, _slug, _title, prev_total, new_total)
      when new_total <= prev_total,
      do: :ok

  def notify_new_chapters(user_uuid, source, slug, title, prev_total, new_total) do
    delta = new_total - prev_total
    label = if delta == 1, do: "chapter", else: "chapters"
    display_title = title || slug

    attrs = %{
      recipient_uuid: user_uuid,
      type: "manga_updates",
      action: "manga.new_chapters",
      text: "#{delta} new #{label} — #{display_title}",
      icon: "hero-book-open",
      link: "/reader/manga/#{source}/#{slug}"
    }

    try do
      PhoenixKit.Notifications.create(attrs)
    rescue
      _ -> :ok
    end

    :ok
  end

  @doc """
  When a refresh discovers the source flipped this manga's
  publication status (e.g. Ongoing → Completed), fan out a bell
  notification to *every* user who has it saved — status is global
  metadata and the event is rare enough that one-shot per affected
  user beats relying on each user to refresh themselves.

  Only meaningful transitions fire:

    * Ongoing → Completed  — series finished
    * Ongoing → Hiatus     — series paused
    * Hiatus  → Ongoing    — series resumed
    * Hiatus  → Completed  — finished from a hiatus

  `unknown` on either side is skipped to avoid spamming on
  data-quality wobbles (a new source phrasing the normalizer hasn't
  learned yet, or a temporarily-empty status field).
  """
  def notify_status_change(_source, _slug, _title, prev_status, new_status)
      when prev_status == new_status,
      do: :ok

  def notify_status_change(_source, _slug, _title, "unknown", _new_status), do: :ok
  def notify_status_change(_source, _slug, _title, _prev_status, "unknown"), do: :ok

  def notify_status_change(source, slug, title, _prev_status, new_status) do
    {text_suffix, icon} = status_change_copy(new_status)
    display_title = title || slug

    recipients =
      SavedManga
      |> where([s], s.source == ^source and s.slug == ^slug)
      |> select([s], s.user_id)
      |> Repo.all()

    Enum.each(recipients, fn user_uuid ->
      attrs = %{
        recipient_uuid: user_uuid,
        type: "manga_updates",
        action: "manga.status_changed",
        text: "#{display_title} #{text_suffix}",
        icon: icon,
        link: "/reader/manga/#{source}/#{slug}"
      }

      try do
        PhoenixKit.Notifications.create(attrs)
      rescue
        _ -> :ok
      end
    end)

    :ok
  end

  defp status_change_copy("completed"), do: {"is now Completed", "hero-check-badge"}
  defp status_change_copy("hiatus"), do: {"is now on Hiatus", "hero-pause-circle"}
  defp status_change_copy("ongoing"), do: {"resumed", "hero-play-circle"}
  defp status_change_copy(_), do: {"status changed", "hero-bell"}

  @doc """
  When a new top-level comment is left on an annotation / mark, ping
  every other user who has *already passed* that chapter — i.e.
  someone catching up to where they are and leaving comments behind
  them. Comments left on chapters the user hasn't read yet are
  intentionally skipped; they'll surface organically as the user
  reads forward.

  Recipients are aggregated per (recipient, manga): one unseen bell
  entry per manga that accumulates a count. Once the user opens the
  bell and marks it seen, the next comment starts a fresh aggregate.
  """
  def notify_past_chapter_comment(%{metadata: meta, user_uuid: commenter_uuid} = _comment)
      when is_map(meta) do
    source = meta["source"]
    slug = meta["slug"]
    chapter = meta["chapter"]
    page = meta["page"]

    cond do
      not (is_binary(source) and source != "") ->
        :ok

      not (is_binary(slug) and slug != "") ->
        :ok

      is_nil(chapter) ->
        :ok

      true ->
        recipients = list_recipients_past_position(source, slug, chapter, page, commenter_uuid)

        if recipients != [] do
          title = lookup_manga_title(source, slug)

          Enum.each(recipients, fn user_uuid ->
            aggregate_past_chapter_notification(user_uuid, source, slug, title)
          end)
        end

        :ok
    end
  end

  def notify_past_chapter_comment(_), do: :ok

  # Saved-manga rows whose position is strictly *past* the comment's
  # position — those users have already read the point where the
  # comment was left, so they'd otherwise miss it. Position is
  # `(chapter, page)`; "past" means either a later chapter OR the same
  # chapter and a later page (so a comment on ch.5 page 9 reaches a
  # reader sitting on ch.5 page 10). When either page is unknown
  # within the same chapter we conservatively skip — `last_page = nil`
  # also covers the `do_snap` case where the user jumped to a chapter
  # without reading any pages of it yet.
  defp list_recipients_past_position(source, slug, comment_chapter, comment_page, commenter_uuid) do
    SavedManga
    |> where([s], s.source == ^source and s.slug == ^slug)
    |> where([s], not is_nil(s.last_chapter))
    |> where([s], s.user_id != type(^commenter_uuid, Ecto.UUID))
    |> select([s], %{user_id: s.user_id, last_chapter: s.last_chapter, last_page: s.last_page})
    |> Repo.all()
    |> Enum.filter(&past_position?(&1, comment_chapter, comment_page))
    |> Enum.map(& &1.user_id)
  end

  defp past_position?(
         %{last_chapter: saved_chapter, last_page: saved_page},
         comment_chapter,
         comment_page
       ) do
    cond do
      chapter_gt?(saved_chapter, comment_chapter) ->
        true

      saved_chapter == comment_chapter ->
        sp = parse_int(saved_page)
        cp = parse_int(comment_page)
        is_integer(sp) and is_integer(cp) and sp > cp

      true ->
        false
    end
  end

  defp parse_int(n) when is_integer(n), do: n

  defp parse_int(s) when is_binary(s) do
    case Integer.parse(s) do
      {n, _} -> n
      :error -> nil
    end
  end

  defp parse_int(_), do: nil

  defp lookup_manga_title(source, slug) do
    Repo.one(
      from m in MangaMetadata,
        where: m.source == ^source and m.slug == ^slug,
        select: fragment("?->>'title'", m.data)
    )
  end

  # Bump-or-create the per-(recipient, manga) aggregated bell entry.
  # Bumps `inserted_at` so the new arrival surfaces at the top of the
  # dropdown, then re-broadcasts `:notification_created` so the bell
  # LV refreshes — phoenix_kit's broadcast only fires on initial
  # insert, so a raw UPDATE alone would leave the bell stale until
  # the next page load.
  #
  # Both queries go through PhoenixKit.Notifications.Notification rather
  # than the bare "phoenix_kit_notifications" source: schemaless, Ecto has
  # no type for `metadata` and dumped the map into the jsonb column as an
  # encoded *string*, which every schema-based reader (the bell's
  # `recent_for_user/2`) then refuses to load — a 500 on every page for
  # that recipient. The schema gives the field its `:map` type back.
  defp aggregate_past_chapter_notification(user_uuid, source, slug, title) do
    manga_key = "#{source}/#{slug}"
    display_title = title || slug
    link = "/reader/manga/#{source}/#{slug}/comments"

    existing =
      Repo.one(
        from n in PhoenixKit.Notifications.Notification,
          where: n.recipient_uuid == ^user_uuid,
          where: is_nil(n.seen_at),
          where: is_nil(n.dismissed_at),
          where: fragment("?->>'manga_key' = ?", n.metadata, ^manga_key),
          where: fragment("?->>'action_kind' = ?", n.metadata, ^"manga.past_chapter_comment"),
          order_by: [desc: n.inserted_at],
          limit: 1,
          select: %{uuid: n.uuid, metadata: n.metadata}
      )

    try do
      if existing do
        current_count =
          case is_map(existing.metadata) && Map.get(existing.metadata, "comment_count") do
            n when is_integer(n) -> n
            _ -> 1
          end

        new_count = current_count + 1
        label = if new_count == 1, do: "comment", else: "comments"
        text = "#{new_count} new #{label} on earlier chapters of #{display_title}"

        new_meta =
          ((is_map(existing.metadata) && existing.metadata) || %{})
          |> Map.put("notification_text", text)
          |> Map.put("comment_count", new_count)

        Repo.update_all(
          from(n in PhoenixKit.Notifications.Notification,
            where: n.uuid == ^existing.uuid
          ),
          set: [metadata: new_meta, inserted_at: DateTime.utc_now() |> DateTime.truncate(:second)]
        )

        PhoenixKit.Notifications.Events.broadcast(
          user_uuid,
          {:notification_created, %{uuid: existing.uuid}}
        )
      else
        PhoenixKit.Notifications.create(%{
          recipient_uuid: user_uuid,
          type: "manga_updates",
          action: "manga.past_chapter_comment",
          text: "1 new comment on earlier chapters of #{display_title}",
          icon: "hero-chat-bubble-left-ellipsis",
          link: link,
          metadata: %{
            "manga_key" => manga_key,
            "action_kind" => "manga.past_chapter_comment",
            "comment_count" => 1
          }
        })
      end
    rescue
      _ -> :ok
    end

    :ok
  end

  @valid_modes ["scroll", "paged", "double_page"]

  def update_reading_mode(user_id, source, slug, mode, device \\ nil)

  def update_reading_mode(user_id, source, slug, mode, "desktop") when mode in @valid_modes do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: [reading_mode_desktop: mode, updated_at: DateTime.utc_now()])
  end

  def update_reading_mode(user_id, source, slug, mode, "mobile") when mode in @valid_modes do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: [reading_mode_mobile: mode, updated_at: DateTime.utc_now()])
  end

  def update_reading_mode(user_id, source, slug, mode, "all") when mode in @valid_modes do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(
      set: [
        reading_mode: mode,
        reading_mode_desktop: mode,
        reading_mode_mobile: mode,
        updated_at: DateTime.utc_now()
      ]
    )
  end

  def update_reading_mode(user_id, source, slug, mode, _device) when mode in @valid_modes do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: [reading_mode: mode, updated_at: DateTime.utc_now()])
  end

  @valid_tap_zone_presets ["default", "left_right", "right_left"]

  def update_tap_zone_preset(user_id, source, slug, preset, device \\ nil)

  def update_tap_zone_preset(user_id, source, slug, preset, "desktop")
      when preset in @valid_tap_zone_presets do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: [tap_zone_preset_desktop: preset, updated_at: DateTime.utc_now()])
  end

  def update_tap_zone_preset(user_id, source, slug, preset, "mobile")
      when preset in @valid_tap_zone_presets do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: [tap_zone_preset_mobile: preset, updated_at: DateTime.utc_now()])
  end

  def update_tap_zone_preset(user_id, source, slug, preset, _device)
      when preset in @valid_tap_zone_presets do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: [tap_zone_preset: preset])
  end

  @valid_directions ["rtl", "ltr"]

  def update_reading_direction(user_id, source, slug, direction)
      when direction in @valid_directions do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: [reading_direction: direction, updated_at: DateTime.utc_now()])
  end

  def update_comments_visible(user_id, source, slug, visible) when is_boolean(visible) do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: [comments_visible: visible])
  end

  @valid_rotations [0, 90, 180, 270]

  def update_reading_rotation(user_id, source, slug, rotation)
      when rotation in @valid_rotations do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: [reading_rotation: rotation, updated_at: DateTime.utc_now()])
  end

  def update_smart_crop(user_id, source, slug, enabled) when is_boolean(enabled) do
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: [smart_crop: enabled])
  end

  def update_progress(
        user_id,
        source,
        slug,
        chapter,
        page,
        elapsed \\ 0,
        user_timezone \\ nil,
        total_pages \\ nil,
        page_fraction \\ 0.0
      ) do
    elapsed = elapsed |> max(0) |> min(300)
    page_fraction = page_fraction |> max(0.0) |> min(1.0)

    saved =
      SavedManga
      |> where(user_id: ^user_id, source: ^source, slug: ^slug)
      |> select([s], %{
        title: s.title,
        last_chapter: s.last_chapter,
        chapter_seconds: s.chapter_seconds,
        chapter_near_end: s.chapter_near_end,
        max_chapter: s.max_chapter,
        visiting_chapter: s.visiting_chapter,
        visiting_seconds: s.visiting_seconds,
        prev_chapter: s.prev_chapter,
        prev_chapter_seconds: s.prev_chapter_seconds,
        prev_chapter_near_end: s.prev_chapter_near_end,
        last_chapter_number: s.last_chapter_number,
        total_chapters: s.total_chapters,
        reading_seconds: s.reading_seconds
      })
      |> Repo.one()

    current_max = saved && saved.max_chapter
    effective_position = (saved && saved.visiting_chapter) || (saved && saved.last_chapter)

    is_going_backward =
      effective_position && chapter != effective_position &&
        !chapter_gt?(chapter, effective_position)

    near_end = total_pages && total_pages > 0 && page >= ceil(total_pages * 0.9)

    last_chapter = saved && saved.last_chapter

    # For chapter counting: use visiting_seconds when going backward, chapter_seconds otherwise
    # Restore from prev_chapter snapshot when returning to a previously-read chapter
    prev_seconds =
      if is_going_backward do
        visiting_ch = saved && saved.visiting_chapter

        cond do
          visiting_ch == chapter -> (saved && saved.visiting_seconds) || 0
          saved && saved.prev_chapter == chapter -> (saved && saved.prev_chapter_seconds) || 0
          true -> 0
        end
      else
        cond do
          chapter == last_chapter -> (saved && saved.chapter_seconds) || 0
          saved && saved.prev_chapter == chapter -> (saved && saved.prev_chapter_seconds) || 0
          true -> 0
        end
      end

    new_seconds = prev_seconds + elapsed

    was_near_end =
      if saved && saved.prev_chapter == chapter && chapter != last_chapter do
        (saved && saved.prev_chapter_near_end) || false
      else
        (saved && saved.chapter_near_end) || false
      end

    is_near_end = was_near_end || near_end

    # Chapter-counting time bar, scaled to chapter length. The old
    # flat 90s minimum silently dropped legitimately-finished SHORT
    # chapters during binge reading; then 3s/page turned out to still
    # be above a real reading pace for art-heavy, dialogue-sparse
    # titles (Blame at ~2.5-3s/page lost 25 of 42 chapters in one
    # day). 1.5s/page filters actual skimming without taxing fast
    # reads; clamped to [10, 60] so tiny extras need at least a beat
    # and long chapters can't demand more than a minute.
    required_seconds =
      case total_pages do
        n when is_integer(n) and n > 0 -> min(60, max(10, round(n * 1.5)))
        _ -> 60
      end

    if elapsed > 0 do
      title = (saved && saved.title) || ""

      count_chapter =
        is_near_end and new_seconds >= required_seconds and
          (prev_seconds < required_seconds or (not was_near_end and near_end))

      chapters_read = if count_chapter, do: 1, else: 0

      # Saved titles only (like stints below): checking whether a
      # source works shouldn't put entries on the history page.
      if saved do
        record_daily_activity(user_id, source, slug, title, elapsed, user_timezone, chapters_read)
      end

      # Discrete chapter-read event log (see chapter_reads_on_date/3)
      # — "which chapter, at what moment" behind the aggregate
      # counters. Never allowed to break the save.
      if saved && count_chapter do
        try do
          Repo.insert!(%ChapterRead{
            user_id: user_id,
            source: source,
            slug: slug,
            chapter: chapter,
            read_at: DateTime.utc_now(),
            seconds: new_seconds,
            total_pages: total_pages
          })
        rescue
          e -> Logger.warning("chapter read log failed: #{inspect(e)}")
        end
      end

      # Milestone log: the FIRST reading tick ever on this title —
      # "started reading" on the history calendar. reading_seconds is
      # the pre-tick value, so only the very first flush qualifies;
      # the exists-check guards against a burst of parallel first
      # flushes double-logging.
      if saved && (saved.reading_seconds || 0) == 0 &&
           not Repo.exists?(
             LibraryEvent
             |> where(user_id: ^user_id, source: ^source, slug: ^slug)
             |> where(event: "started")
           ) do
        log_library_event(user_id, source, slug, "started", chapter)
      end

      # Session-level tracking (stint package): each progress tick
      # extends the current reading session or opens a new one after a
      # 5-minute silence — second-resolution started_at/ended_at per
      # session, powering the history page's session timeline. Never
      # allowed to break the progress save itself.
      # Saved titles only: opening a random source just to check it
      # works shouldn't mint a session on the history page.
      if saved do
        try do
          Stint.track(user_id, "manga:#{source}/#{slug}", elapsed, meta: %{"chapter" => chapter})
        rescue
          e -> Logger.warning("stint tracking failed: #{inspect(e)}")
        end
      end

      # Push the counted chapter to the user's MyAnimeList list —
      # async (external HTTP), no-op unless connected + linked, never
      # blocks the save.
      if saved && count_chapter do
        Task.Supervisor.start_child(Roki.TaskSupervisor, fn ->
          try do
            push_progress_to_mal(user_id, source, slug, chapter, status: "reading")
          rescue
            e -> Logger.warning("MAL push crashed: #{inspect(e)}")
          end
        end)
      end
    end

    query = SavedManga |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    now = DateTime.utc_now()

    if is_going_backward do
      # Reading behind current position — don't update last_chapter until 5 min
      visiting_ch = saved && saved.visiting_chapter

      prev_visiting_sec =
        cond do
          visiting_ch == chapter -> (saved && saved.visiting_seconds) || 0
          saved && saved.prev_chapter == chapter -> (saved && saved.prev_chapter_seconds) || 0
          true -> 0
        end

      new_visiting_sec = prev_visiting_sec + elapsed

      if new_visiting_sec >= 300 do
        # Commit: update last_chapter, clear visiting state
        Repo.update_all(query,
          set: [
            last_chapter: chapter,
            last_page: page,
            last_page_fraction: page_fraction,
            last_chapter_total_pages: total_pages,
            chapter_seconds: new_visiting_sec,
            chapter_near_end: near_end || false,
            visiting_chapter: nil,
            visiting_seconds: 0,
            completed: false,
            updated_at: now
          ],
          inc: [reading_seconds: elapsed]
        )
      else
        # Track visiting time, don't touch last_chapter
        Repo.update_all(query,
          set: [
            visiting_chapter: chapter,
            visiting_seconds: new_visiting_sec,
            completed: false,
            updated_at: now
          ],
          inc: [reading_seconds: elapsed]
        )
      end
    else
      # Normal: going forward or at same position
      chapter_changed = saved && (saved.last_chapter != chapter || saved.last_chapter == nil)
      advancing = current_max == nil || chapter_gt?(chapter, current_max) || current_max == nil

      was_near_end = (saved && saved.chapter_near_end) || false
      is_near_end = was_near_end || near_end

      sets =
        if chapter_changed do
          returning_to_prev = saved && saved.prev_chapter == chapter

          if returning_to_prev do
            # Restore: swap current ↔ prev
            [
              last_chapter: chapter,
              last_page: page,
              last_page_fraction: page_fraction,
              last_chapter_total_pages: total_pages,
              chapter_seconds: saved.prev_chapter_seconds || 0,
              chapter_near_end: saved.prev_chapter_near_end || false || (near_end || false),
              prev_chapter: saved.last_chapter,
              prev_chapter_seconds: saved.chapter_seconds || 0,
              prev_chapter_near_end: saved.chapter_near_end || false,
              visiting_chapter: nil,
              visiting_seconds: 0,
              completed: false,
              updated_at: now
            ]
          else
            # Normal forward: snapshot current into prev
            [
              last_chapter: chapter,
              last_page: page,
              last_page_fraction: page_fraction,
              last_chapter_total_pages: total_pages,
              chapter_seconds: elapsed,
              chapter_near_end: near_end || false,
              prev_chapter: saved.last_chapter,
              prev_chapter_seconds: saved.chapter_seconds || 0,
              prev_chapter_near_end: saved.chapter_near_end || false,
              visiting_chapter: nil,
              visiting_seconds: 0,
              completed: false,
              updated_at: now
            ]
          end
        else
          [
            last_chapter: chapter,
            last_page: page,
            last_page_fraction: page_fraction,
            last_chapter_total_pages: total_pages,
            chapter_near_end: is_near_end || false,
            visiting_chapter: nil,
            visiting_seconds: 0,
            completed: false,
            updated_at: now
          ]
        end

      sets = if advancing, do: Keyword.put(sets, :max_chapter, chapter), else: sets

      incs =
        cond do
          # `chapter_changed` is nil (not false) when there's no saved
          # row — strict `and` raised BadBooleanError on every progress
          # tick for unsaved manga.
          chapter_changed && saved && saved.prev_chapter == chapter ->
            # Returning to prev: increment restored chapter_seconds
            [reading_seconds: elapsed, chapter_seconds: elapsed]

          chapter_changed ->
            [reading_seconds: elapsed]

          true ->
            [reading_seconds: elapsed, chapter_seconds: elapsed]
        end

      Repo.update_all(query, set: sets, inc: incs)
    end

    # Milestone log: the moment the reading position crosses the
    # latest known chapter — i.e. the title just moved into the home
    # page's caught-up category. Transition only: staying at the tip
    # (or re-flushing the same chapter) logs nothing.
    # `is_going_backward` is nil (not false) when there's no saved row
    # — strict `not` raised on every progress tick for unsaved manga.
    if saved && !is_going_backward do
      thresholds = %{
        last_chapter_number: saved.last_chapter_number,
        total_chapters: saved.total_chapters
      }

      was_caught_up = caught_up?(Map.put(thresholds, :last_chapter, saved.last_chapter))
      now_caught_up = caught_up?(Map.put(thresholds, :last_chapter, chapter))

      if not was_caught_up and now_caught_up do
        log_caught_up(user_id, source, slug, chapter, user_timezone)
      end
    end

    # Mirror the new on-site activity into `reading_seconds_adjusted`
    # IF the user has set a manual on-site override. Without this,
    # the override would freeze the displayed total — once a user
    # adjusts (e.g., to patch up lost tracker time), every minute
    # they read afterwards would silently disappear from the display
    # even though `reading_seconds` is still ticking up. Bumping
    # `adjusted` by the same delta when it's non-null keeps the
    # "manual override" behaving like a starting offset rather than
    # a hard ceiling.
    if elapsed > 0 do
      from(s in SavedManga,
        where:
          s.user_id == ^user_id and s.source == ^source and s.slug == ^slug and
            not is_nil(s.reading_seconds_adjusted)
      )
      |> Repo.update_all(inc: [reading_seconds_adjusted: elapsed])
    end

    # Whether this chapter is in the counted-as-read state after this
    # save (newly OR previously counted) — readers surface it as a
    # checkmark in the progress pill.
    {:ok, %{chapter_read: (is_near_end && new_seconds >= required_seconds) || false}}
  end

  def reset_max_chapter(user_id, source, slug) do
    query = SavedManga |> where(user_id: ^user_id, source: ^source, slug: ^slug)

    case Repo.one(from s in query, select: s.last_chapter) do
      nil -> :ok
      last_chapter -> Repo.update_all(query, set: [max_chapter: last_chapter])
    end
  end

  defp chapter_gt?(a, b), do: Chapter.gt?(a, b)

  @doc """
  Chapter-read events on the user's local `date`, oldest first —
  `utc_offset` in seconds, same convention as `Stint.on_date/3` so
  the two share day boundaries.
  """
  def chapter_reads_on_date(user_id, %Date{} = date, utc_offset \\ 0) do
    day_start =
      date
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.add(-utc_offset, :second)

    day_end = DateTime.add(day_start, 86_400, :second)

    ChapterRead
    |> where([c], c.user_id == ^user_id)
    |> where([c], c.read_at >= ^day_start and c.read_at < ^day_end)
    |> order_by([c], asc: c.read_at)
    |> Repo.all()
  end

  # Caught-up dedup: you can't catch up twice in a day. Reading a
  # chapter that dropped AFTER this morning's catch-up is the same
  # catch-up moved forward, so the day's earlier event for the series
  # is replaced (newer chapter, newer time) instead of accumulating.
  # Catch-ups on different local days are genuinely separate and all
  # stay — that's the "when did I catch up" statistic.
  defp log_caught_up(user_id, source, slug, chapter, user_timezone) do
    delete_same_day_caught_up(user_id, source, slug, user_timezone)
    log_library_event(user_id, source, slug, "caught_up", chapter)
  rescue
    e -> Logger.warning("caught-up event log failed: #{inspect(e)}")
  end

  # Same-local-day caught_up sweep for a series. Two callers:
  # a NEWER catch-up replaces the day's earlier one (same catch-up
  # moved forward), and COMPLETING the series supersedes it entirely
  # (nothing left to catch up on).
  defp delete_same_day_caught_up(user_id, source, slug, user_timezone) do
    offset = round(parse_timezone_offset(user_timezone) * 3600)

    day_start =
      DateTime.utc_now()
      |> DateTime.add(offset, :second)
      |> DateTime.to_date()
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.add(-offset, :second)

    day_end = DateTime.add(day_start, 86_400, :second)

    LibraryEvent
    |> where([e], e.user_id == ^user_id and e.source == ^source and e.slug == ^slug)
    |> where([e], e.event == "caught_up")
    |> where([e], e.happened_at >= ^day_start and e.happened_at < ^day_end)
    |> Repo.delete_all()
  end

  @doc "The title's `started` milestone timestamp, or nil."
  def started_event_at(user_id, source, slug) do
    LibraryEvent
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> where(event: "started")
    |> select([e], e.happened_at)
    |> limit(1)
    |> Repo.one()
  end

  @doc """
  Total seconds in the daily reading-activity log for a title (0 if
  none). Can be non-zero even when the saved row's on-site counter is
  0 — so the details page knows to still offer a reset that clears the
  leftover history entry.
  """
  def onsite_activity_seconds(user_id, source, slug) do
    from(a in ReadingActivity,
      where: a.user_id == ^user_id and a.source == ^source and a.slug == ^slug,
      select: coalesce(sum(a.reading_seconds), 0)
    )
    |> Repo.one() || 0
  end

  @doc """
  User-edited "date started": moves the `started` milestone to noon
  (local) of `date`, creating it if absent; `nil` deletes it.
  """
  def set_started_date(user_id, source, slug, nil, _user_timezone) do
    LibraryEvent
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> where(event: "started")
    |> Repo.delete_all()

    :ok
  end

  def set_started_date(user_id, source, slug, %Date{} = date, user_timezone) do
    offset = round(parse_timezone_offset(user_timezone) * 3600)

    # Anchor to real reading on that local day if any exists — the
    # earliest stint start, else the earliest activity hour — so the
    # ▶ lands where the reading actually was. Noon-local is only the
    # fallback for a day with no reading recorded for this title.
    happened_at =
      started_anchor(user_id, source, slug, date, offset) ||
        date
        |> DateTime.new!(~T[12:00:00.000000], "Etc/UTC")
        |> DateTime.add(-offset, :second)

    query =
      LibraryEvent
      |> where(user_id: ^user_id, source: ^source, slug: ^slug)
      |> where(event: "started")

    unless Repo.exists?(query) do
      log_library_event(user_id, source, slug, "started", nil)
    end

    Repo.update_all(query, set: [happened_at: happened_at])
    :ok
  end

  # Earliest reading moment for {source, slug} on the given local
  # `date` (offset in seconds), or nil if the title wasn't read then.
  # Prefers a stint's exact start; falls back to the earliest
  # activity hour (hour-resolution).
  defp started_anchor(user_id, source, slug, date, offset) do
    day_start =
      date
      |> DateTime.new!(~T[00:00:00.000000], "Etc/UTC")
      |> DateTime.add(-offset, :second)

    day_end = DateTime.add(day_start, 86_400, :second)
    item = "manga:#{source}/#{slug}"

    stint_start =
      from(s in "stints",
        where: s.owner_id == ^user_id and s.item == ^item,
        where: s.started_at >= ^day_start and s.started_at < ^day_end,
        select: min(s.started_at)
      )
      |> Repo.one()

    cond do
      not is_nil(stint_start) ->
        stint_start

      hour = earliest_activity_hour(user_id, source, slug, date) ->
        date
        |> DateTime.new!(Time.new!(hour, 0, 0, {0, 6}), "Etc/UTC")
        |> DateTime.add(-offset, :second)

      true ->
        nil
    end
  end

  defp earliest_activity_hour(user_id, source, slug, date) do
    from(a in ReadingActivity,
      where:
        a.user_id == ^user_id and a.source == ^source and a.slug == ^slug and a.date == ^date,
      select: min(a.hour)
    )
    |> Repo.one()
  end

  # Milestone event log (see `LibraryEvent`) — best-effort, never
  # allowed to break the write that triggered it.
  defp log_library_event(user_id, source, slug, event, chapter) do
    Repo.insert!(%LibraryEvent{
      user_id: user_id,
      source: source,
      slug: slug,
      event: event,
      chapter: chapter,
      happened_at: DateTime.utc_now()
    })
  rescue
    e -> Logger.warning("library event log failed: #{inspect(e)}")
  end

  @doc """
  All milestone events whose local day falls in `first..last`
  (inclusive), oldest first — for calendar-range displays.
  """
  def library_events_between(user_id, %Date{} = first, %Date{} = last, utc_offset \\ 0) do
    start_dt =
      first
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.add(-utc_offset, :second)

    end_dt =
      last
      |> Date.add(1)
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.add(-utc_offset, :second)

    LibraryEvent
    |> where([e], e.user_id == ^user_id)
    |> where([e], e.happened_at >= ^start_dt and e.happened_at < ^end_dt)
    |> order_by([e], asc: e.happened_at)
    |> Repo.all()
  end

  def library_events_on_date(user_id, %Date{} = date, utc_offset \\ 0) do
    day_start =
      date
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.add(-utc_offset, :second)

    day_end = DateTime.add(day_start, 86_400, :second)

    from(e in LibraryEvent,
      where: e.user_id == ^user_id,
      where: e.happened_at >= ^day_start and e.happened_at < ^day_end,
      left_join: s in SavedManga,
      on: s.user_id == e.user_id and s.source == e.source and s.slug == e.slug,
      order_by: [asc: e.happened_at],
      select: %{
        id: e.id,
        event: e.event,
        source: e.source,
        slug: e.slug,
        chapter: e.chapter,
        happened_at: e.happened_at,
        title: s.title
      }
    )
    |> Repo.all()
  end

  @doc """
  Remove a user's reading activity for one series on one local day —
  both the per-hour `reading_activity` rows (feed + heatmap) and the
  `chapter_reads` completions that fall inside that local day. Library
  milestone events are left alone; delete those separately with
  `delete_library_event/2`.
  """
  def delete_day_activity(user_id, %Date{} = date, source, slug, utc_offset \\ 0) do
    day_start =
      date
      |> DateTime.new!(~T[00:00:00], "Etc/UTC")
      |> DateTime.add(-utc_offset, :second)

    day_end = DateTime.add(day_start, 86_400, :second)

    Repo.transaction(fn ->
      from(a in ReadingActivity,
        where:
          a.user_id == ^user_id and a.date == ^date and a.source == ^source and a.slug == ^slug
      )
      |> Repo.delete_all()

      from(c in ChapterRead,
        where:
          c.user_id == ^user_id and c.source == ^source and c.slug == ^slug and
            c.read_at >= ^day_start and c.read_at < ^day_end
      )
      |> Repo.delete_all()
    end)

    :ok
  end

  @doc """
  Every chapter id this user has a counted completion for on a title
  (distinct, unordered). Drives the details page's spoiler unlock: an
  arc's description unblurs once its last chapter is in here.
  """
  def finished_chapters(user_id, source, slug) do
    from(c in ChapterRead,
      where: c.user_id == ^user_id and c.source == ^source and c.slug == ^slug,
      distinct: true,
      select: c.chapter
    )
    |> Repo.all()
  end

  @doc "Remove a single library milestone event by id, scoped to the user."
  def delete_library_event(user_id, id) do
    from(e in LibraryEvent, where: e.id == ^id and e.user_id == ^user_id)
    |> Repo.delete_all()

    :ok
  end

  def record_daily_activity(
        user_id,
        source,
        slug,
        title,
        elapsed,
        user_timezone \\ nil,
        chapters_read \\ 0
      ) do
    offset_hours = parse_timezone_offset(user_timezone)
    utc_now = DateTime.utc_now()
    shifted = DateTime.add(utc_now, round(offset_hours * 3600), :second)
    today = DateTime.to_date(shifted)
    hour = shifted.hour
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    Repo.insert(
      %ReadingActivity{
        user_id: user_id,
        date: today,
        hour: hour,
        source: source,
        slug: slug,
        title: title,
        reading_seconds: elapsed,
        chapters_read: chapters_read,
        inserted_at: now,
        updated_at: now
      },
      on_conflict: [
        inc: [reading_seconds: elapsed, chapters_read: chapters_read],
        set: [updated_at: now]
      ],
      conflict_target: [:user_id, :date, :hour, :source, :slug]
    )
  end

  def timezone_offset_seconds(tz) do
    round(parse_timezone_offset(tz) * 3600)
  end

  defp parse_timezone_offset(nil), do: 0
  defp parse_timezone_offset(val) when is_integer(val), do: max(-12, min(14, val))
  defp parse_timezone_offset(val) when is_float(val), do: max(-12.0, min(14.0, val))

  defp parse_timezone_offset(val) when is_binary(val) do
    case Float.parse(val) do
      {n, _} -> max(-12.0, min(14.0, n))
      :error -> 0
    end
  end

  defp parse_timezone_offset(_), do: 0

  # Only include rows created after the hour column was deployed;
  # older rows all have hour=0 which is misleading.
  @hour_feature_cutoff ~N[2026-03-10 15:49:25]

  def list_hourly_activity_for_date(user_id, date) do
    rows =
      ReadingActivity
      |> where(user_id: ^user_id, date: ^date)
      |> where([a], a.reading_seconds > 0)
      |> where([a], a.updated_at >= ^@hour_feature_cutoff)
      |> select([a], %{
        hour: a.hour,
        seconds: a.reading_seconds,
        title: a.title,
        chapters_read: a.chapters_read
      })
      |> order_by([a], asc: a.hour, desc: a.reading_seconds)
      |> Repo.all()

    rows
    |> Enum.group_by(& &1.hour)
    |> then(fn grouped ->
      Enum.map(0..23, fn h ->
        entries = Map.get(grouped, h, [])

        %{
          hour: h,
          seconds: Enum.reduce(entries, 0, fn e, acc -> acc + e.seconds end),
          entries:
            Enum.map(
              entries,
              &%{title: &1.title, seconds: &1.seconds, chapters_read: &1.chapters_read}
            )
        }
      end)
    end)
  end

  def list_hourly_averages(user_id) do
    rows =
      ReadingActivity
      |> where(user_id: ^user_id)
      |> where([a], a.reading_seconds > 0)
      |> where([a], a.updated_at >= ^@hour_feature_cutoff)
      |> select([a], %{date: a.date, hour: a.hour, seconds: a.reading_seconds})
      |> Repo.all()

    rows
    |> Enum.group_by(& &1.hour)
    |> then(fn grouped ->
      active_days = rows |> Enum.map(& &1.date) |> Enum.uniq() |> length() |> max(1)

      Enum.map(0..23, fn h ->
        entries = Map.get(grouped, h, [])
        total = Enum.reduce(entries, 0, fn e, acc -> acc + e.seconds end)
        %{hour: h, avg_seconds: div(total, active_days), total_seconds: total}
      end)
    end)
  end

  def list_reading_activity(user_id) do
    cutoff = Date.utc_today() |> Date.add(-371)

    ReadingActivity
    |> where(user_id: ^user_id)
    |> where([a], a.date >= ^cutoff)
    |> order_by([a], asc: a.date, desc: a.reading_seconds)
    |> Repo.all()
    |> Enum.group_by(& &1.date, fn a ->
      %{
        title: a.title,
        source: a.source,
        slug: a.slug,
        seconds: a.reading_seconds,
        chapters_read: a.chapters_read
      }
    end)
  end

  def deterministic_uuid(input) do
    <<a::binary-size(4), b::binary-size(2), _::binary-size(2), c::binary-size(2),
      d::binary-size(6), _::binary>> =
      :crypto.hash(:sha, input)

    # Set version 5 (name-based SHA-1) and variant bits
    <<a1::48, _::4, b1::12, _::2, c1::62>> = <<a::binary, b::binary, 0::16, c::binary, d::binary>>
    <<uuid::binary>> = <<a1::48, 5::4, b1::12, 2::2, c1::62>>

    uuid
    |> Base.encode16(case: :lower)
    |> String.replace(~r/(.{8})(.{4})(.{4})(.{4})(.{12})/, "\\1-\\2-\\3-\\4-\\5")
  end

  # --- Manga Metadata ---

  @data_keys ~w(title cover_url alt_titles status reading_direction reading_mode
                written_by illustrated_by year genres synopsis chapters chapter_dates)a

  @doc """
  Link a title to a MyAnimeList entry FOR THIS USER: fetch MAL's
  public metadata and cache it on the user's own `manga_mal_links`
  row. Per-user — never affects another user's view. Returns
  `{:ok, mal_map}` or `{:error, reason}`.
  """
  def link_mal_manga(user_id, source, slug, mal_id, client_id) do
    case Roki.Manga.Trackers.MAL.get_manga(mal_id, client_id) do
      {:ok, mal} ->
        # First link vs. a refresh re-link — only auto-switch the reader
        # mode on the first link, so a later manual choice isn't undone.
        first_link? =
          not Repo.exists?(
            from l in MangaMalLink,
              where: l.user_id == ^user_id and l.source == ^source and l.slug == ^slug
          )

        mal_map = %{
          "id" => mal.id,
          "url" => mal.url,
          "title" => mal.title,
          "cover_url" => mal.cover_url,
          "synopsis" => mal.synopsis,
          "genres" => mal.genres,
          "score" => mal.score,
          "rank" => mal.rank,
          "popularity" => mal.popularity,
          "num_users" => mal.num_users,
          "authors" => mal.authors,
          "year" => mal.year,
          "num_chapters" => mal.num_chapters,
          "media_type" => mal.media_type,
          "status" => mal.status,
          "start_date" => mal.start_date,
          "end_date" => mal.end_date,
          "year_start" => mal.year_start,
          "year_end" => mal.year_end,
          "linked_at" => DateTime.utc_now() |> DateTime.to_iso8601(),
          # Seed the push high-water mark from the user's EXISTING MAL
          # progress so linking never regresses their list.
          "last_pushed" => seed_last_pushed(user_id, mal.id)
        }

        result =
          %MangaMalLink{}
          |> MangaMalLink.changeset(%{
            user_id: user_id,
            source: source,
            slug: slug,
            mal_id: mal.id,
            data: mal_map
          })
          |> Repo.insert(
            on_conflict: {:replace, [:mal_id, :data, :updated_at]},
            conflict_target: [:user_id, :source, :slug],
            returning: true
          )

        case result do
          {:ok, _} ->
            if first_link?,
              do: apply_media_type_reading_mode(user_id, source, slug, mal.media_type)

            {:ok, mal_map}

          {:error, cs} ->
            {:error, cs}
        end

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Switch a saved title's reader to match MAL's media type on first
  # link (manhwa/manhua → scroll, manga → paged). No-op for other types
  # or unsaved titles. Deliberately does NOT bump updated_at ("last
  # read") — this is a categorization change, not reading activity.
  defp apply_media_type_reading_mode(user_id, source, slug, media_type) do
    case Roki.Manga.Trackers.MAL.reading_kind(media_type) do
      mode when mode in ["scroll", "paged"] ->
        SavedManga
        |> where(user_id: ^user_id, source: ^source, slug: ^slug)
        |> Repo.update_all(
          set: [reading_mode: mode, reading_mode_desktop: mode, reading_mode_mobile: mode]
        )

      _ ->
        :noop
    end
  end

  # MAL's current chapters-read for this user+manga (0 if not
  # connected or not on their list) — the link's starting high-water.
  defp seed_last_pushed(user_id, mal_id) do
    case get_tracker_token(user_id, "mal") do
      %MangaTrackerToken{} = token ->
        case ensure_fresh_mal_token(token) do
          {:ok, access} -> Roki.Manga.Trackers.MAL.my_chapters_read(access, mal_id)
          _ -> 0
        end

      _ ->
        0
    end
  end

  @doc "Remove THIS user's MAL link for a title."
  def unlink_mal_manga(user_id, source, slug) do
    MangaMalLink
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.delete_all()

    :ok
  end

  # ── Tracker OAuth tokens (per-user) ───────────────────────────────

  @doc "Store/refresh a user's tracker tokens (upsert per provider)."
  def put_tracker_token(user_id, provider, attrs) do
    %MangaTrackerToken{}
    |> MangaTrackerToken.changeset(Map.merge(attrs, %{user_id: user_id, provider: provider}))
    |> Repo.insert(
      on_conflict:
        {:replace, [:access_token, :refresh_token, :expires_at, :remote_username, :updated_at]},
      conflict_target: [:user_id, :provider],
      returning: true
    )
  end

  @doc "A user's tracker token row for a provider, or nil."
  def get_tracker_token(user_id, provider) do
    MangaTrackerToken
    |> where(user_id: ^user_id, provider: ^provider)
    |> Repo.one()
  end

  @doc "Disconnect a user's tracker."
  def delete_tracker_token(user_id, provider) do
    MangaTrackerToken
    |> where(user_id: ^user_id, provider: ^provider)
    |> Repo.delete_all()

    :ok
  end

  @doc "This user's cached MAL map for a title, or nil."
  def mal_data(user_id, source, slug) do
    MangaMalLink
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> select([l], l.data)
    |> Repo.one()
  end

  defp mal_link_row(user_id, source, slug) do
    MangaMalLink
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.one()
  end

  # ── Progress push to MyAnimeList ──────────────────────────────────

  @doc """
  Push the user's chapter progress (and optional status) to their
  linked MAL entry — no-op unless they're connected AND the title is
  linked. High-water-mark deduped on the linked chapter number, so a
  re-read or lower chapter never pushes. Best-effort, async-safe;
  returns `:ok`/`:noop`/`:error`.
  """
  def push_progress_to_mal(user_id, source, slug, chapter, opts \\ []) do
    with token when not is_nil(token) <- get_tracker_token(user_id, "mal"),
         %MangaMalLink{} = link <- mal_link_row(user_id, source, slug) do
      num = floor_chapter(chapter)
      last = link.data["last_pushed"] || 0
      last_status = link.data["last_status"]
      last_score = link.data["last_score"]

      # Never downgrade an already-completed entry back to "reading"
      # on a re-read — completed stays completed on MAL.
      status =
        case Keyword.get(opts, :status) do
          "reading" when last_status == "completed" -> nil
          s -> s
        end

      # The reader's tierlist doubles as the user's rating: sync the
      # current tier's mapped score to MAL alongside progress.
      tier_score = Roki.Manga.Trackers.MAL.tier_score(user_tier_for(user_id, source, slug))

      chapters_changed = is_integer(num) and num > 0 and num > last
      status_changed = status != nil and status != last_status
      score_changed = tier_score != nil and tier_score != last_score

      if not (chapters_changed or status_changed or score_changed) do
        :noop
      else
        case ensure_fresh_mal_token(token) do
          {:ok, access} ->
            new_chapters = if is_integer(num) and num > 0, do: max(num, last), else: last

            fields =
              %{}
              |> then(fn f ->
                if new_chapters > 0, do: Map.put(f, :num_chapters_read, new_chapters), else: f
              end)
              |> then(fn f -> if status, do: Map.put(f, :status, status), else: f end)
              |> then(fn f -> if score_changed, do: Map.put(f, :score, tier_score), else: f end)

            case Roki.Manga.Trackers.MAL.update_list_status(access, link.mal_id, fields) do
              {:ok, _} ->
                new_data =
                  link.data
                  |> Map.put("last_pushed", new_chapters)
                  |> then(fn d -> if status, do: Map.put(d, "last_status", status), else: d end)
                  |> then(fn d ->
                    if score_changed, do: Map.put(d, "last_score", tier_score), else: d
                  end)

                link |> Ecto.Changeset.change(data: new_data) |> Repo.update()
                :ok

              {:error, reason} ->
                Logger.warning("MAL push failed for #{source}/#{slug}: #{inspect(reason)}")
                :error
            end

          _ ->
            :noop
        end
      end
    else
      _ -> :noop
    end
  end

  @doc """
  Sync just the tierlist score for a linked title to MAL (no chapter
  or status change). Best-effort: no-op unless connected + linked and
  the mapped score actually changed. Fired when a tier is (re)assigned.
  """
  def sync_tier_score(user_id, source, slug) do
    push_progress_to_mal(user_id, source, slug, nil, [])
  end

  @doc """
  Reconcile MAL list *status* for every linked title against the
  reader's own state — a one-shot backfill (e.g. titles finished
  before completion-sync existed, or rated-but-never-marked-done).

  For each linked + saved title:
    * completed on the reader → pushes `status: "completed"` to MAL
    * otherwise, has read progress → pushes `status: "reading"`
      (the re-read guard means this never downgrades a title already
      completed on MAL)

  Returns `{:ok, results}` where each result is
  `%{source, slug, desired, outcome}`, or `{:error, :not_connected}`.
  """
  def reconcile_mal_statuses(user_id) do
    case get_tracker_token(user_id, "mal") do
      nil ->
        {:error, :not_connected}

      _ ->
        results =
          user_id
          |> list_mal_links()
          |> Enum.map(fn {{source, slug}, _mal_id} ->
            saved = get_saved_manga(user_id, source, slug)

            {desired, chapter} =
              cond do
                is_nil(saved) -> {nil, nil}
                saved.completed -> {"completed", saved.last_chapter || saved.max_chapter}
                not is_nil(saved.last_chapter) -> {"reading", saved.last_chapter}
                true -> {nil, nil}
              end

            outcome =
              if desired,
                do: push_progress_to_mal(user_id, source, slug, chapter, status: desired),
                else: :skip

            %{source: source, slug: slug, desired: desired, outcome: outcome}
          end)

        {:ok, results}
    end
  end

  # Return a valid access token, refreshing (and persisting) if it's
  # expired or about to be. nil expiry = treat as valid.
  defp ensure_fresh_mal_token(token) do
    stale? =
      case token.expires_at do
        %DateTime{} = exp ->
          DateTime.compare(DateTime.utc_now(), DateTime.add(exp, -60, :second)) != :lt

        _ ->
          false
      end

    cond do
      not stale? ->
        {:ok, token.access_token}

      is_nil(token.refresh_token) ->
        {:error, :no_refresh_token}

      true ->
        case Roki.Manga.Trackers.MAL.refresh_token(token.refresh_token) do
          {:ok, t} ->
            expires_at =
              case t.expires_in do
                s when is_integer(s) -> DateTime.utc_now() |> DateTime.add(s, :second)
                _ -> nil
              end

            put_tracker_token(token.user_id, "mal", %{
              access_token: t.access_token,
              refresh_token: t.refresh_token || token.refresh_token,
              expires_at: expires_at
            })

            {:ok, t.access_token}

          error ->
            error
        end
    end
  end

  defp floor_chapter(nil), do: nil

  defp floor_chapter(chapter) do
    case Chapter.number(chapter) do
      n when is_integer(n) -> n
      n when is_float(n) -> trunc(n)
      _ -> nil
    end
  end

  @doc """
  Overlay this user's MAL metadata onto a manga map when they've
  linked the title: MAL's synopsis and genres win when present
  (cleaner than scraper data), and a `:mal` key carries
  score/rank/link/cover for display. Reading data is untouched.
  """
  def apply_mal_enrichment(manga, mal) when is_map(mal) and map_size(mal) > 0 do
    # MAL's status + publishing years are more reliable than the
    # scraper's; use them when present.
    mal_status = Roki.Manga.Trackers.MAL.status_label(mal["status"])
    mal_years = Roki.Manga.Trackers.MAL.year_range(mal["year_start"], mal["year_end"])

    manga
    |> Map.put(:synopsis, blank_to(mal["synopsis"], manga[:synopsis]))
    |> Map.put(:genres, if(mal["genres"] in [nil, []], do: manga[:genres], else: mal["genres"]))
    |> Map.put(:status, mal_status || manga[:status])
    |> Map.put(:year, mal_years || manga[:year])
    |> Map.put(:mal, mal)
  end

  def apply_mal_enrichment(manga, _), do: Map.put(manga, :mal, nil)

  defp blank_to(val, _fallback) when is_binary(val) and val != "", do: val
  defp blank_to(_, fallback), do: fallback

  def get_manga_metadata(source, slug) do
    MangaMetadata
    |> where(source: ^source, slug: ^slug)
    |> Repo.one()
  end

  def upsert_manga_metadata(attrs) do
    {data_attrs, top_attrs} = Map.split(attrs, @data_keys)
    attrs = Map.put(top_attrs, :data, stringify_keys(data_attrs))

    %MangaMetadata{}
    |> MangaMetadata.changeset(attrs)
    |> Repo.insert(
      on_conflict: {:replace_all_except, [:id, :source, :slug, :inserted_at]},
      conflict_target: [:source, :slug],
      returning: true
    )
  end

  defp stringify_keys(map) do
    Map.new(map, fn {k, v} -> {to_string(k), v} end)
  end

  def metadata_to_manga_map(%MangaMetadata{data: d}) do
    %{
      title: d["title"],
      cover_url: d["cover_url"],
      alt_titles: d["alt_titles"],
      status: d["status"],
      reading_direction: d["reading_direction"],
      reading_mode: d["reading_mode"] || "scroll",
      written_by: d["written_by"],
      illustrated_by: d["illustrated_by"],
      year: d["year"],
      genres: d["genres"] || [],
      synopsis: d["synopsis"] || "",
      chapters: d["chapters"] || [],
      chapter_dates: d["chapter_dates"] || %{}
    }
  end

  def update_cover_file_uuid(user_id, source, slug, file_uuid) do
    # NB: deliberately does NOT bump updated_at — that field doubles as
    # "last read", and changing a cover isn't reading activity.
    SavedManga
    |> where(user_id: ^user_id, source: ^source, slug: ^slug)
    |> Repo.update_all(set: [cover_file_uuid: file_uuid])
  end

  @doc """
  Set the per-user display title for a saved manga (shown in the
  library and on the details page). Returns `:ok`, or `:error` for a
  blank title. Like the cover, this is not reading activity, so it
  doesn't bump updated_at / "last read".
  """
  def update_saved_title(user_id, source, slug, title) do
    trimmed = title |> to_string() |> String.trim() |> String.slice(0, 500)

    if trimmed == "" do
      :error
    else
      SavedManga
      |> where(user_id: ^user_id, source: ^source, slug: ^slug)
      |> Repo.update_all(set: [title: trimmed])

      :ok
    end
  end

  def list_cover_file_uuids([]), do: %{}

  def list_cover_file_uuids(source_slug_pairs) do
    conditions =
      Enum.reduce(source_slug_pairs, dynamic(false), fn {source, slug}, acc ->
        dynamic([m], ^acc or (m.source == ^source and m.slug == ^slug))
      end)

    from(m in MangaMetadata,
      where: not is_nil(m.cover_file_uuid),
      where: ^conditions,
      select: {{m.source, m.slug}, m.cover_file_uuid}
    )
    |> Repo.all()
    |> Map.new()
  end

  def list_publication_statuses([]), do: %{}

  def list_publication_statuses(source_slug_pairs) do
    conditions =
      Enum.reduce(source_slug_pairs, dynamic(false), fn {source, slug}, acc ->
        dynamic([m], ^acc or (m.source == ^source and m.slug == ^slug))
      end)

    from(m in MangaMetadata,
      where: ^conditions,
      select: {{m.source, m.slug}, fragment("?->>'status'", m.data)}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  Lists comments attached to etcher shapes (the fresco-reader path) for a
  manga. Returns the same shape as `list_manga_annotations/3`. Visibility
  is stored per-item on the MangaMark row, so we filter in Elixir after
  loading the candidate comments.

  Etcher comments never carry a `page` integer — fresco strip readers scroll
  by image, not by page — so the returned `page` is `nil`. Templates should
  display "Chapter X" only when `page` is nil.
  """
  def list_mark_comments_for_manga(source, slug, user_uuid) do
    reply_count_subquery =
      from(r in "phoenix_kit_comments",
        where: r.status == "published",
        group_by: r.parent_uuid,
        select: %{parent_uuid: r.parent_uuid, count: count(r.uuid)}
      )

    candidates =
      from(c in "phoenix_kit_comments",
        join: u in "phoenix_kit_users",
        on: u.uuid == c.user_uuid,
        left_join: rc in subquery(reply_count_subquery),
        on: rc.parent_uuid == c.uuid,
        where: c.resource_type == "manga_mark",
        where: c.status == "published",
        where: fragment("?->>'source' = ?", c.metadata, ^source),
        where: fragment("?->>'slug' = ?", c.metadata, ^slug),
        order_by: [desc: c.inserted_at],
        select: %{
          # `type/2` so Ecto loads the raw 16-byte UUID column as a
          # dashed string. Without it `to_string(c.uuid)` returns the
          # binary back unchanged (it IS a binary in Erlang terms),
          # and the items[].comment_uuid string comparison never
          # matches — hiding both the visibility filter AND the
          # page-from-shape lookup below.
          comment_uuid: type(c.uuid, Ecto.UUID),
          content: c.content,
          metadata: c.metadata,
          like_count: c.like_count,
          reply_count: coalesce(rc.count, 0),
          user_id: type(c.user_uuid, Ecto.UUID),
          username: u.username,
          inserted_at: c.inserted_at
        }
      )
      |> Repo.all()

    resolve_mark_comment_visibility(candidates, source, slug, user_uuid)
  end

  # Raw `from(c in "phoenix_kit_comments", ...)` queries load `uuid`
  # columns as 16-byte binaries, and `to_string/1` on those returns
  # the raw bytes rather than the dashed "019e8751-…" form. The mark
  # row's `items[].comment_uuid` is the formatted string, so the
  # bytewise comparison never matched and every mark comment looked
  # orphaned. Coerce both sides through `Ecto.UUID.cast/1` first.
  defp uuid_to_string(nil), do: nil

  defp uuid_to_string(<<_::128>> = bin) do
    case Ecto.UUID.cast(bin) do
      {:ok, s} -> s
      :error -> nil
    end
  end

  defp uuid_to_string(s) when is_binary(s), do: s

  defp resolve_mark_comment_visibility(comments, source, slug, user_uuid) do
    keys =
      comments
      |> Enum.map(fn c -> {c.user_id, Map.get(c.metadata || %{}, "chapter")} end)
      |> Enum.uniq()

    marks_by_key =
      Enum.reduce(keys, %{}, fn
        {uid, ch}, acc when is_binary(ch) ->
          case Roki.Manga.Library.Marks.get_user_row(uid, source, slug, ch) do
            nil -> acc
            %{items: items} -> Map.put(acc, {uid, ch}, items)
          end

        _, acc ->
          acc
      end)

    user_uuid_str = uuid_to_string(user_uuid)

    Enum.flat_map(comments, fn c ->
      meta = c.metadata || %{}
      chapter = Map.get(meta, "chapter")
      items = Map.get(marks_by_key, {c.user_id, chapter}, [])
      comment_uuid_str = uuid_to_string(c.comment_uuid)

      item =
        Enum.find(items, fn it -> it["comment_uuid"] == comment_uuid_str end)

      visibility = (item && item["visibility"]) || "public"
      owner? = uuid_to_string(c.user_id) == user_uuid_str

      # Page on `metadata.page` for comments stamped after the fix;
      # for older comments that lack it, parse from the linked shape's
      # `image_id` (`"page-N"`) when the shape still exists. Without
      # either source the `/slug/comments` link can't preload the
      # right page, so the user lands on page 1.
      page_from_meta = Map.get(meta, "page")

      page_from_shape =
        case item && get_in(item, ["etcher", "image_id"]) do
          "page-" <> n ->
            case Integer.parse(n) do
              {p, ""} -> p
              _ -> nil
            end

          _ ->
            nil
        end

      page = page_from_meta || page_from_shape

      # Orphan comments — the etcher shape that anchored the comment
      # has been removed from `manga_marks` (likely deleted via Etcher
      # while the comment row hung on). Clicking such a comment lands
      # on the chapter but the shape is gone, so there's nothing to
      # reveal. Drop orphans from the listing so every visible row
      # corresponds to a clickable, working shape.
      orphan? = is_nil(item)

      if not orphan? and (visibility == "public" or owner?) do
        [
          %{
            kind: :mark,
            # `id` is what the template feeds into `comment_reader_url/1` →
            # `?ann=` — use the etcher shape uuid so the reader can map
            # back to the original DOM rect. Falls back to the comment uuid.
            id: Map.get(meta, "etcher_shape_uuid") || comment_uuid_str,
            comment_uuid: comment_uuid_str,
            title: Map.get(meta, "title"),
            source: source,
            slug: slug,
            chapter: chapter,
            page: page,
            content: c.content,
            metadata: meta,
            color:
              (item && (get_in(item, ["etcher", "style", "color"]) || item["color"])) || "blue",
            visibility: visibility,
            user_id: c.user_id,
            username: c.username,
            like_count: c.like_count,
            reply_count: c.reply_count,
            inserted_at: c.inserted_at
          }
        ]
      else
        []
      end
    end)
  end

  def list_manga_annotations(source, slug, user_uuid) do
    reply_count_subquery =
      from(r in "phoenix_kit_comments",
        where: r.status == "published",
        group_by: r.parent_uuid,
        select: %{parent_uuid: r.parent_uuid, count: count(r.uuid)}
      )

    from(a in MangaAnnotation,
      join: c in "phoenix_kit_comments",
      on: c.uuid == a.comment_uuid,
      join: u in "phoenix_kit_users",
      on: u.uuid == a.user_id,
      left_join: rc in subquery(reply_count_subquery),
      on: rc.parent_uuid == c.uuid,
      where: a.source == ^source and a.slug == ^slug,
      where: c.status == "published",
      where: a.visibility == "public" or a.user_id == type(^user_uuid, Ecto.UUID),
      order_by: [desc: a.inserted_at],
      select: %{
        kind: :legacy,
        id: a.id,
        title: a.title,
        source: a.source,
        slug: a.slug,
        chapter: a.chapter,
        page: a.page,
        content: c.content,
        metadata: c.metadata,
        color: a.color,
        visibility: a.visibility,
        user_id: a.user_id,
        username: u.username,
        like_count: c.like_count,
        reply_count: coalesce(rc.count, 0),
        inserted_at: a.inserted_at
      }
    )
    |> Repo.all()
  end

  def count_annotations_grouped(user_uuid) do
    legacy =
      from(a in MangaAnnotation,
        join: c in "phoenix_kit_comments",
        on: c.uuid == a.comment_uuid,
        where: c.status == "published",
        where: a.visibility == "public" or a.user_id == type(^user_uuid, Ecto.UUID),
        group_by: [a.source, a.slug],
        select: {{a.source, a.slug}, count(a.id)}
      )
      |> Repo.all()
      |> Map.new()

    marks = count_mark_comments_grouped(user_uuid)

    Map.merge(legacy, marks, fn _k, v1, v2 -> v1 + v2 end)
  end

  defp count_mark_comments_grouped(user_uuid) do
    candidates =
      from(c in "phoenix_kit_comments",
        join: u in "phoenix_kit_users",
        on: u.uuid == c.user_uuid,
        where: c.resource_type == "manga_mark",
        where: c.status == "published",
        select: %{
          comment_uuid: c.uuid,
          content: c.content,
          metadata: c.metadata,
          like_count: c.like_count,
          reply_count: 0,
          user_id: c.user_uuid,
          username: u.username,
          inserted_at: c.inserted_at
        }
      )
      |> Repo.all()

    candidates
    |> Enum.group_by(fn c ->
      meta = c.metadata || %{}
      {Map.get(meta, "source"), Map.get(meta, "slug")}
    end)
    |> Enum.reduce(%{}, fn
      {{src, slg}, group}, acc when is_binary(src) and is_binary(slg) ->
        case resolve_mark_comment_visibility(group, src, slg, user_uuid) do
          [] -> acc
          visible -> Map.put(acc, {src, slg}, length(visible))
        end

      _, acc ->
        acc
    end)
  end

  def count_annotations_by_chapter(source, slug, user_uuid) do
    legacy =
      from(a in MangaAnnotation,
        join: c in "phoenix_kit_comments",
        on: c.uuid == a.comment_uuid,
        where: a.source == ^source and a.slug == ^slug,
        where: c.status == "published",
        where: a.visibility == "public" or a.user_id == type(^user_uuid, Ecto.UUID),
        group_by: a.chapter,
        select: {a.chapter, count(a.id)}
      )
      |> Repo.all()
      |> Map.new()

    marks_by_chapter =
      list_mark_comments_for_manga(source, slug, user_uuid)
      |> Enum.frequencies_by(& &1.chapter)
      |> Map.delete(nil)

    Map.merge(legacy, marks_by_chapter, fn _k, v1, v2 -> v1 + v2 end)
  end

  # --- Annotations ---

  def list_annotations(source, slug, chapter, user_uuid) do
    from(a in MangaAnnotation,
      join: c in "phoenix_kit_comments",
      on: c.uuid == a.comment_uuid,
      where: a.source == ^source and a.slug == ^slug and a.chapter == ^chapter,
      where: c.status == "published",
      where: a.visibility == "public" or a.user_id == type(^user_uuid, Ecto.UUID),
      select: %{
        id: a.id,
        comment_uuid: a.comment_uuid,
        resource_uuid: type(c.resource_uuid, Ecto.UUID),
        page: a.page,
        x_pct: a.x_pct,
        y_pct: a.y_pct,
        w_pct: a.w_pct,
        h_pct: a.h_pct,
        color: a.color,
        visibility: a.visibility,
        user_id: a.user_id
      }
    )
    |> Repo.all()
  end

  def get_annotation_detail(comment_uuid, user_uuid) do
    from(c in "phoenix_kit_comments",
      join: a in MangaAnnotation,
      on: a.comment_uuid == c.uuid,
      join: u in "phoenix_kit_users",
      on: u.uuid == c.user_uuid,
      left_join: l in "phoenix_kit_comments_likes",
      on: l.comment_uuid == c.uuid and l.user_uuid == type(^user_uuid, Ecto.UUID),
      where: c.uuid == type(^comment_uuid, Ecto.UUID) and c.status == "published",
      where: a.visibility == "public" or a.user_id == type(^user_uuid, Ecto.UUID),
      select: %{
        comment_uuid: type(c.uuid, Ecto.UUID),
        content: c.content,
        metadata: c.metadata,
        like_count: c.like_count,
        user_uuid: type(c.user_uuid, Ecto.UUID),
        username: u.username,
        avatar_file_uuid: fragment("?->>?", u.custom_fields, "avatar_file_uuid"),
        inserted_at: c.inserted_at,
        is_own: c.user_uuid == type(^user_uuid, Ecto.UUID),
        liked: not is_nil(l.uuid),
        visibility: a.visibility
      }
    )
    |> Repo.one()
  end

  def create_annotation(user, source, slug, chapter, attrs) do
    page = attrs["page"] || attrs[:page]
    resource_id = Ecto.UUID.generate()

    manga_title =
      case get_manga_metadata(source, slug) do
        %{data: %{"title" => title}} -> title
        _ -> nil
      end

    gif_url = attrs["gif_url"] || attrs[:gif_url]

    giphy_object =
      if gif_url,
        do: %{"url" => gif_url, "preview_url" => gif_url},
        else: nil

    base_metadata = %{
      "source" => source,
      "slug" => slug,
      "chapter" => chapter,
      "page" => page,
      "manga_title" => manga_title
    }

    metadata =
      if giphy_object,
        do: Map.put(base_metadata, "giphy", giphy_object),
        else: base_metadata

    Repo.transaction(fn ->
      case PhoenixKitComments.create_comment(
             "manga_annotation",
             resource_id,
             user.uuid,
             %{
               content: gif_content_fallback(attrs["content"] || attrs[:content], gif_url),
               metadata: metadata
             }
           ) do
        {:ok, comment} ->
          case %MangaAnnotation{}
               |> MangaAnnotation.changeset(%{
                 comment_uuid: comment.uuid,
                 user_id: user.uuid,
                 source: source,
                 slug: slug,
                 chapter: chapter,
                 page: page,
                 title: attrs["title"] || attrs[:title],
                 x_pct: attrs["x_pct"] || attrs[:x_pct],
                 y_pct: attrs["y_pct"] || attrs[:y_pct],
                 w_pct: attrs["w_pct"] || attrs[:w_pct],
                 h_pct: attrs["h_pct"] || attrs[:h_pct],
                 color: attrs["color"] || attrs[:color],
                 visibility: attrs["visibility"] || attrs[:visibility] || "public"
               })
               |> Repo.insert() do
            {:ok, annotation} ->
              PhoenixKitComments.update_comment(comment, %{
                metadata: Map.put(comment.metadata || %{}, "annotation_id", annotation.id)
              })

              annotation

            {:error, changeset} ->
              Repo.rollback(changeset)
          end

        {:error, reason} ->
          Repo.rollback(reason)
      end
    end)
  end

  # Pre-fetched distinct (title, source) pairs and usernames that
  # appear in the user's visible comment history (own + public). The
  # controller passes these to the comments page so the title / user
  # filter dropdowns are complete from the first render — the initial
  # 50-item page would otherwise miss titles/users that only appear
  # deeper in the list (especially legacy ones, which tend to predate
  # the newer mark comments).
  def list_user_annotation_filters(user_uuid) do
    legacy =
      from(a in MangaAnnotation,
        join: c in "phoenix_kit_comments",
        on: c.uuid == a.comment_uuid,
        join: u in "phoenix_kit_users",
        on: u.uuid == a.user_id,
        where: c.status == "published",
        where: a.visibility == "public" or a.user_id == type(^user_uuid, Ecto.UUID),
        distinct: true,
        select: %{title: a.title, source: a.source, username: u.username}
      )
      |> Repo.all()

    # Marks: distinct (source, slug, title, username) from comment
    # metadata + author. Mark visibility is per-item so we'd have to
    # resolve every shape to be precise; over-including is harmless
    # (private-only authors would show up but clicking them filters
    # to nothing — same edge case as the colors filter).
    marks_raw =
      from(c in "phoenix_kit_comments",
        join: u in "phoenix_kit_users",
        on: u.uuid == c.user_uuid,
        where: c.resource_type == "manga_mark" and c.status == "published",
        distinct: true,
        select: %{
          source: fragment("?->>'source'", c.metadata),
          slug: fragment("?->>'slug'", c.metadata),
          title: fragment("?->>'title'", c.metadata),
          username: u.username
        }
      )
      |> Repo.all()
      |> Enum.reject(fn r -> is_nil(r.source) or is_nil(r.slug) end)

    marks = backfill_filter_titles(marks_raw)

    titles =
      (Enum.map(legacy, &{&1.title, &1.source}) ++
         Enum.map(marks, &{&1.title, &1.source}))
      |> Enum.reject(fn {t, _} -> is_nil(t) or t == "" end)
      |> Enum.uniq()
      |> Enum.sort_by(fn {t, _} -> t end)

    usernames =
      (Enum.map(legacy, & &1.username) ++ Enum.map(marks, & &1.username))
      |> Enum.reject(&is_nil/1)
      |> Enum.uniq()
      |> Enum.sort()

    %{titles: titles, usernames: usernames}
  end

  defp backfill_filter_titles(entries) do
    pairs =
      entries
      |> Enum.filter(fn e -> is_nil(e.title) or e.title == "" end)
      |> Enum.map(fn e -> {e.source, e.slug} end)
      |> Enum.uniq()

    case pairs do
      [] ->
        entries

      _ ->
        sources = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        slugs = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

        titles =
          from(s in SavedManga,
            where: s.source in ^sources and s.slug in ^slugs,
            group_by: [s.source, s.slug],
            select: {s.source, s.slug, max(s.title)}
          )
          |> Repo.all()
          |> Map.new(fn {src, slg, t} -> {{src, slg}, t} end)

        Enum.map(entries, fn e ->
          case e.title do
            t when is_nil(t) or t == "" ->
              %{e | title: Map.get(titles, {e.source, e.slug})}

            _ ->
              e
          end
        end)
    end
  end

  # Distinct annotation colors used by the user across both legacy
  # `manga_annotations` rows and `manga_marks.items[]` entries. Drives
  # the color filter row on /reader/comments — pre-fetched so it shows
  # the full palette in use even if the initial 50 comments don't.
  def list_user_annotation_colors(user_uuid) do
    legacy =
      from(a in MangaAnnotation,
        where: a.user_id == ^user_uuid and not is_nil(a.color),
        distinct: true,
        select: a.color
      )
      |> Repo.all()

    marks =
      from(m in Roki.Manga.Library.MangaMark,
        where: m.user_id == ^user_uuid,
        distinct: true,
        select:
          fragment(
            "jsonb_array_elements(?)#>>'{etcher,style,color}'",
            m.items
          )
      )
      |> Repo.all()
      |> Enum.reject(&is_nil/1)

    all = (legacy ++ marks) |> Enum.uniq()

    # Surface known named-palette colors in canonical order first, then
    # any hex / one-off values after — keeps the filter row stable across
    # renders while leaving room for etcher's extended palette.
    palette = ~w(blue pink green purple)
    in_palette = Enum.filter(palette, &(&1 in all))
    rest = (all -- palette) |> Enum.sort()
    in_palette ++ rest
  end

  def list_recent_annotations(limit \\ 50, user_uuid, opts \\ []) do
    before = Keyword.get(opts, :before)

    reply_count_subquery =
      from(r in "phoenix_kit_comments",
        where: r.status == "published",
        group_by: r.parent_uuid,
        select: %{parent_uuid: r.parent_uuid, count: count(r.uuid)}
      )

    legacy_q =
      from(a in MangaAnnotation,
        join: c in "phoenix_kit_comments",
        on: c.uuid == a.comment_uuid,
        join: u in "phoenix_kit_users",
        on: u.uuid == a.user_id,
        left_join: rc in subquery(reply_count_subquery),
        on: rc.parent_uuid == c.uuid,
        where: c.status == "published",
        where: a.visibility == "public" or a.user_id == type(^user_uuid, Ecto.UUID),
        order_by: [desc: a.inserted_at],
        limit: ^limit,
        select: %{
          kind: :legacy,
          id: a.id,
          title: a.title,
          source: a.source,
          slug: a.slug,
          chapter: a.chapter,
          page: a.page,
          content: c.content,
          metadata: c.metadata,
          color: a.color,
          visibility: a.visibility,
          user_id: a.user_id,
          username: u.username,
          like_count: c.like_count,
          reply_count: coalesce(rc.count, 0),
          inserted_at: a.inserted_at
        }
      )

    legacy_q = if before, do: where(legacy_q, [a], a.inserted_at < ^before), else: legacy_q
    legacy = Repo.all(legacy_q)

    marks = list_recent_mark_comments(limit, user_uuid, before)

    (legacy ++ marks)
    |> Enum.sort_by(& &1.inserted_at, {:desc, NaiveDateTime})
    |> Enum.take(limit)
  end

  defp list_recent_mark_comments(limit, user_uuid, before) do
    reply_count_subquery =
      from(r in "phoenix_kit_comments",
        where: r.status == "published",
        group_by: r.parent_uuid,
        select: %{parent_uuid: r.parent_uuid, count: count(r.uuid)}
      )

    candidates_q =
      from(c in "phoenix_kit_comments",
        join: u in "phoenix_kit_users",
        on: u.uuid == c.user_uuid,
        left_join: rc in subquery(reply_count_subquery),
        on: rc.parent_uuid == c.uuid,
        where: c.resource_type == "manga_mark",
        where: c.status == "published",
        order_by: [desc: c.inserted_at],
        limit: ^limit,
        select: %{
          comment_uuid: c.uuid,
          content: c.content,
          metadata: c.metadata,
          like_count: c.like_count,
          reply_count: coalesce(rc.count, 0),
          user_id: c.user_uuid,
          username: u.username,
          inserted_at: c.inserted_at
        }
      )

    candidates_q =
      if before, do: where(candidates_q, [c], c.inserted_at < ^before), else: candidates_q

    candidates = Repo.all(candidates_q)

    # Visibility resolution per (source, slug) — group candidates so we
    # do one batched MangaMark fetch per manga.
    resolved =
      candidates
      |> Enum.group_by(fn c ->
        meta = c.metadata || %{}
        {Map.get(meta, "source"), Map.get(meta, "slug")}
      end)
      |> Enum.flat_map(fn
        {{src, slg}, group} when is_binary(src) and is_binary(slg) ->
          resolve_mark_comment_visibility(group, src, slg, user_uuid)

        _ ->
          []
      end)

    # Comments stamped before the title was added to metadata (or with
    # an empty title field) need a name to render — backfill from any
    # SavedManga row matching the (source, slug) pair.
    backfill_mark_titles(resolved)
  end

  defp backfill_mark_titles([]), do: []

  defp backfill_mark_titles(marks) do
    pairs =
      marks
      |> Enum.flat_map(fn m ->
        case {m.source, m.slug, m.title} do
          {src, slg, t} when is_binary(src) and is_binary(slg) and (is_nil(t) or t == "") ->
            [{src, slg}]

          _ ->
            []
        end
      end)
      |> Enum.uniq()

    case pairs do
      [] ->
        marks

      _ ->
        sources = pairs |> Enum.map(&elem(&1, 0)) |> Enum.uniq()
        slugs = pairs |> Enum.map(&elem(&1, 1)) |> Enum.uniq()

        titles =
          from(s in SavedManga,
            where: s.source in ^sources and s.slug in ^slugs,
            group_by: [s.source, s.slug],
            select: {s.source, s.slug, max(s.title)}
          )
          |> Repo.all()
          |> Map.new(fn {src, slg, t} -> {{src, slg}, t} end)

        Enum.map(marks, fn m ->
          case m.title do
            t when is_nil(t) or t == "" ->
              %{m | title: Map.get(titles, {m.source, m.slug})}

            _ ->
              m
          end
        end)
    end
  end

  def update_annotation(annotation_id, user_uuid, attrs) do
    case Repo.get(MangaAnnotation, annotation_id) do
      nil ->
        {:error, :not_found}

      %MangaAnnotation{user_id: ^user_uuid} = annotation ->
        Repo.transaction(fn ->
          # Update comment content
          comment = PhoenixKitComments.get_comment(annotation.comment_uuid)

          if comment && attrs["content"] do
            case PhoenixKitComments.update_comment(comment, %{content: attrs["content"]}) do
              {:ok, _} -> :ok
              {:error, reason} -> Repo.rollback(reason)
            end
          end

          # Update annotation fields
          case annotation
               |> MangaAnnotation.changeset(%{
                 color: attrs["color"] || annotation.color,
                 x_pct: attrs["x_pct"] || annotation.x_pct,
                 y_pct: attrs["y_pct"] || annotation.y_pct,
                 w_pct: attrs["w_pct"] || annotation.w_pct,
                 h_pct: attrs["h_pct"] || annotation.h_pct,
                 visibility: attrs["visibility"] || annotation.visibility
               })
               |> Repo.update() do
            {:ok, updated} -> updated
            {:error, changeset} -> Repo.rollback(changeset)
          end
        end)

      _other ->
        {:error, :forbidden}
    end
  end

  def delete_annotation(annotation_id, user_uuid) do
    case Repo.get(MangaAnnotation, annotation_id) do
      nil ->
        {:error, :not_found}

      %MangaAnnotation{user_id: ^user_uuid} = annotation ->
        comment = PhoenixKitComments.get_comment(annotation.comment_uuid)
        if comment, do: PhoenixKitComments.delete_comment(comment)
        Repo.delete(annotation)

      _other ->
        {:error, :forbidden}
    end
  end

  def toggle_like_annotation(comment_uuid, user_uuid) do
    if PhoenixKitComments.comment_liked_by?(comment_uuid, user_uuid) do
      PhoenixKitComments.unlike_comment(comment_uuid, user_uuid)
      comment = PhoenixKitComments.get_comment(comment_uuid)
      {:ok, false, comment.like_count}
    else
      PhoenixKitComments.like_comment(comment_uuid, user_uuid)
      comment = PhoenixKitComments.get_comment(comment_uuid)
      {:ok, true, comment.like_count}
    end
  end

  # Sends a phoenix_kit notification to the author of `comment` for a
  # like / reply event. Public so the resource-handler module
  # (`Roki.Manga.CommentNotifier`) can call it on every like/reply,
  # regardless of which surface (legacy controller, fresco/etcher LV)
  # triggered the event. Silently skipped when the actor is the author
  # themselves (no self-pings), when the comment is missing, or when
  # the notifications module rejects the insert — none of those should
  # surface as a 500 on the originating comment action.
  def notify_comment_action(nil, _actor_uuid, _action), do: :ok
  def notify_comment_action(%{user_uuid: same}, same, _action), do: :ok

  def notify_comment_action(comment, actor_uuid, action) do
    {text_prefix, icon, action_key} =
      case action do
        :liked ->
          {"liked your comment", "hero-heart", "comment.liked"}

        :replied ->
          {"replied to your comment", "hero-chat-bubble-left-ellipsis", "comment.replied"}
      end

    actor_name = lookup_username(actor_uuid) || "Someone"

    attrs = %{
      recipient_uuid: comment.user_uuid,
      type: "comments",
      action: action_key,
      text: "#{actor_name} #{text_prefix}.",
      icon: icon,
      link: comment_deep_link(comment)
    }

    try do
      PhoenixKit.Notifications.create(attrs)
    rescue
      _ -> :ok
    end

    :ok
  end

  defp lookup_username(user_uuid) do
    from(u in "phoenix_kit_users",
      where: u.uuid == type(^user_uuid, Ecto.UUID),
      select: u.username
    )
    |> Repo.one()
  end

  # Builds a reader URL that lands on the parent comment via `?ann=`.
  # `source` / `slug` / `chapter` live on `comment.metadata` (set when
  # the annotation was created in `create_annotation/5` and copied
  # forward to replies in `create_annotation_reply/4`). The `?ann=`
  # value must match the *reader's* expectations:
  #
  #   * `manga_mark` (fresco / etcher) — the reader polls for an etcher
  #     shape UUID, so we feed `metadata["etcher_shape_uuid"]`. Without
  #     it the reader's poll never finds a shape, so no flash + no
  #     auto-opened modal — even though the URL otherwise drops the
  #     user on the correct chapter and page. Mirrors
  #     `list_mark_comments_for_manga/3`'s `id:` field that the
  #     `/slug/comments` index uses.
  #
  #   * `manga_annotation` (legacy reader) — `?ann=` is the numeric
  #     MangaAnnotation.id, and the reader lives at
  #     `/reader/legacy/manga/...`. We resolve the id by joining on
  #     the top-level comment's uuid (replies inherit it via
  #     `parent_uuid`).
  #
  # When metadata is missing the bits we need, return nil — the bell
  # entry stays non-clickable rather than 404'ing.
  defp comment_deep_link(%{resource_type: "manga_mark", metadata: meta}) when is_map(meta) do
    with source when is_binary(source) and source != "" <- meta["source"],
         slug when is_binary(slug) and slug != "" <- meta["slug"],
         chapter when not is_nil(chapter) <- meta["chapter"],
         ann when is_binary(ann) and ann != "" <- meta["etcher_shape_uuid"] do
      page_q = if meta["page"], do: "page=#{meta["page"]}&", else: ""
      "/reader/manga/#{source}/#{slug}/#{chapter}?#{page_q}ann=#{ann}"
    else
      _ -> nil
    end
  end

  defp comment_deep_link(%{resource_type: "manga_annotation", metadata: meta} = comment)
       when is_map(meta) do
    with source when is_binary(source) and source != "" <- meta["source"],
         slug when is_binary(slug) and slug != "" <- meta["slug"],
         chapter when not is_nil(chapter) <- meta["chapter"],
         ann_id when not is_nil(ann_id) <- lookup_legacy_annotation_id(comment) do
      page_q = if meta["page"], do: "page=#{meta["page"]}&", else: ""
      "/reader/legacy/manga/#{source}/#{slug}/#{chapter}?#{page_q}ann=#{ann_id}"
    else
      _ -> nil
    end
  end

  defp comment_deep_link(_), do: nil

  # Look up the legacy MangaAnnotation.id from either the comment
  # itself (top-level) or its parent (one-level reply). Walking the
  # full chain is overkill — replies-of-replies aren't reachable from
  # the UI today, so two hops cover every real-world case.
  defp lookup_legacy_annotation_id(%{uuid: uuid, parent_uuid: parent_uuid}) do
    uuids = [uuid, parent_uuid] |> Enum.reject(&is_nil/1)

    from(a in Roki.Manga.Library.MangaAnnotation,
      where: a.comment_uuid in ^uuids,
      select: a.id,
      limit: 1
    )
    |> Repo.one()
  end

  defp lookup_legacy_annotation_id(%{uuid: uuid}) do
    from(a in Roki.Manga.Library.MangaAnnotation,
      where: a.comment_uuid == ^uuid,
      select: a.id,
      limit: 1
    )
    |> Repo.one()
  end

  def list_annotation_replies(comment_uuid, user_uuid) do
    from(c in "phoenix_kit_comments",
      join: u in "phoenix_kit_users",
      on: u.uuid == c.user_uuid,
      left_join: l in "phoenix_kit_comments_likes",
      on: l.comment_uuid == c.uuid and l.user_uuid == type(^user_uuid, Ecto.UUID),
      where: c.parent_uuid == type(^comment_uuid, Ecto.UUID) and c.status == "published",
      order_by: [asc: c.inserted_at],
      select: %{
        uuid: type(c.uuid, Ecto.UUID),
        content: c.content,
        metadata: c.metadata,
        like_count: c.like_count,
        user_uuid: type(c.user_uuid, Ecto.UUID),
        username: u.username,
        avatar_file_uuid: fragment("?->>?", u.custom_fields, "avatar_file_uuid"),
        inserted_at: c.inserted_at,
        is_own: c.user_uuid == type(^user_uuid, Ecto.UUID),
        liked: not is_nil(l.uuid)
      }
    )
    |> Repo.all()
  end

  def delete_reply(reply_uuid, user_uuid) do
    comment = PhoenixKitComments.get_comment(reply_uuid)

    cond do
      is_nil(comment) -> {:error, :not_found}
      comment.user_uuid != user_uuid -> {:error, :forbidden}
      true -> PhoenixKitComments.delete_comment(comment)
    end
  end

  def create_annotation_reply(comment_uuid, user_uuid, content, opts \\ %{}) do
    parent = PhoenixKitComments.get_comment(comment_uuid)
    gif_url = opts["gif_url"] || opts[:gif_url]

    if parent do
      base_metadata = Map.drop(parent.metadata || %{}, ["giphy", "gif_url"])

      metadata =
        if gif_url,
          do: Map.put(base_metadata, "giphy", %{"url" => gif_url, "preview_url" => gif_url}),
          else: base_metadata

      PhoenixKitComments.create_comment(
        parent.resource_type,
        parent.resource_uuid,
        user_uuid,
        %{
          content: gif_content_fallback(content, gif_url),
          parent_uuid: comment_uuid,
          metadata: metadata
        }
      )
    else
      {:error, :not_found}
    end
  end

  @gif_placeholder "\u200B"

  defp gif_content_fallback(content, gif_url) do
    content = content || ""
    if String.trim(content) == "" and gif_url, do: @gif_placeholder, else: content
  end

  def strip_gif_placeholder(content) do
    if content == @gif_placeholder, do: "", else: content || ""
  end

  def list_tierlist(user_uuid) do
    from(t in MangaTierlist,
      where: t.user_id == type(^user_uuid, Ecto.UUID),
      select: {{t.source, t.slug}, {t.tier, t.position}}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc """
  The tier this user assigned to a specific manga in their tierlist
  ("sp" / "s" / "a" / "b" / "c" / "d" / "e" / "unknown" / "want" /
  "pool"), or `nil` if they haven't placed it anywhere. Powers the
  "Your Tier" badge on the manga details page so the user can see
  where they ranked it without bouncing through `/reader/tierlist`.
  """
  def user_tier_for(user_uuid, source, slug) do
    from(t in MangaTierlist,
      where: t.user_id == type(^user_uuid, Ecto.UUID) and t.source == ^source and t.slug == ^slug,
      select: t.tier
    )
    |> Repo.one()
  end

  @doc "All of a user's MAL links as `%{{source, slug} => mal_id}`."
  def list_mal_links(user_uuid) do
    from(l in MangaMalLink,
      where: l.user_id == ^user_uuid,
      select: {{l.source, l.slug}, l.mal_id}
    )
    |> Repo.all()
    |> Map.new()
  end

  @doc "A fresh MAL access token for a user, refreshing if needed."
  def mal_access_token(user_id) do
    case get_tracker_token(user_id, "mal") do
      nil -> :error
      token -> ensure_fresh_mal_token(token)
    end
  end

  @doc """
  Per-title MAL rating-sync status for the tierlist, keyed by
  `{source, slug}`. Each value is `%{status, mal_score, expected}`:

    * `:synced`      — linked, connected, MAL's score == the tier's
                       mapped score
    * `:out_of_sync` — linked, connected, MAL's score differs (or the
                       title isn't rated on MAL yet)
    * `:linked`      — linked but either not connected (can't verify)
                       or in a non-scoring tier (Want/Unknown/Unranked)

  Only linked titles appear. Pulls the user's live MAL scores once
  (best-effort — degrades to `:linked` if the fetch fails).
  """
  def tierlist_mal_sync(user_uuid, tier_index) do
    # {source,slug} => {mal_id, community_mean_string}. The mean is
    # MAL's public rating, cached in the link data at enrichment time
    # (no API call needed to show it).
    links =
      from(l in MangaMalLink,
        where: l.user_id == ^user_uuid,
        select: {{l.source, l.slug}, {l.mal_id, fragment("?->>'score'", l.data)}}
      )
      |> Repo.all()
      |> Map.new()

    if map_size(links) == 0 do
      %{}
    else
      connected? = get_tracker_token(user_uuid, "mal") != nil

      scores =
        with true <- connected?,
             {:ok, access} <- mal_access_token(user_uuid),
             {:ok, map} <- Roki.Manga.Trackers.MAL.list_scores(access) do
          map
        else
          _ -> %{}
        end

      Map.new(links, fn {{_source, _slug} = key, {mal_id, mean_raw}} ->
        tier =
          case tier_index[key] do
            {t, _} -> t
            _ -> nil
          end

        expected = Roki.Manga.Trackers.MAL.tier_score(tier)
        actual = Map.get(scores, mal_id)

        status =
          cond do
            not connected? -> :linked
            expected == nil -> :linked
            actual == expected -> :synced
            true -> :out_of_sync
          end

        {key,
         %{status: status, mal_score: actual, expected: expected, mal_mean: parse_mean(mean_raw)}}
      end)
    end
  end

  # MAL's community mean comes back as a JSON string; keep one decimal.
  defp parse_mean(raw) when is_binary(raw) do
    case Float.parse(raw) do
      {f, _} when f > 0 -> Float.round(f, 1)
      _ -> nil
    end
  end

  defp parse_mean(_), do: nil

  @doc """
  Rough "how much reading is left" estimate for a saved manga.

  Math is per-chapter average from the user's own logged time on this
  specific title:

      seconds_per_chapter = total_reading_time / chapters_read_so_far
      seconds_remaining   = chapters_remaining * seconds_per_chapter

  Both on-site (adjusted when set, else raw) and off-site time count
  toward the pace, since both represent the user actually reading
  this title. Returns `nil` (caller hides the row) when any of these
  hold — they each make the estimate dishonest:

    * Fewer than 3 chapters read — too noisy to extrapolate.
    * Less than 10 min total invested — same reason.
    * No usable chapter target (`last_chapter_number || total_chapters`).
    * Already caught up (chapters_remaining ≤ 0).
    * User has marked the title completed manually.
    * `last_chapter` doesn't parse as a number (volume-prefixed
      formats like `"v1-c3"` — could be added later if it matters).

  Calendar-day ETA is intentionally deferred — the time-investment
  number is honest from a few chapters in, the days-until-finished
  number isn't until we have a reading-cadence window built up.
  """
  def completion_estimate(%{} = saved) do
    chapters_read = parse_chapter_floor(saved.last_chapter)
    total_chapters = saved.last_chapter_number || saved.total_chapters

    on_site = saved.reading_seconds_adjusted || saved.reading_seconds || 0
    off_site = saved.reading_seconds_offsite || 0
    total_seconds = on_site + off_site

    chapters_remaining =
      if is_integer(chapters_read) and is_integer(total_chapters) do
        max(0, total_chapters - chapters_read)
      end

    cond do
      saved.completed ->
        nil

      not is_integer(chapters_read) ->
        nil

      chapters_read < 3 ->
        nil

      total_seconds < 600 ->
        nil

      is_nil(chapters_remaining) ->
        nil

      chapters_remaining <= 0 ->
        nil

      true ->
        seconds_per_chapter = div(total_seconds, chapters_read)
        seconds_remaining = seconds_per_chapter * chapters_remaining
        percent_read = round(chapters_read * 100 / total_chapters)

        %{
          chapters_read: chapters_read,
          chapters_total: total_chapters,
          chapters_remaining: chapters_remaining,
          seconds_per_chapter: seconds_per_chapter,
          seconds_remaining: seconds_remaining,
          percent_read: percent_read
        }
    end
  end

  def completion_estimate(_), do: nil

  @doc """
  Looser percent-read calculation used by the Continue button's
  in-button progress fill. Same `chapters_read / chapters_total`
  math as `completion_estimate/1`'s `:percent_read` field, but
  without the time / chapter-count thresholds — a freshly-saved
  manga with one chapter read still gets a visible bar, even
  though the time estimate isn't honest yet. Returns `nil` only
  when the data can't form a percent at all (no parseable
  chapter, no chapter target).
  """
  def chapter_progress_percent(%{} = saved) do
    chapters_read = parse_chapter_floor(saved.last_chapter)
    chapters_total = saved.last_chapter_number || saved.total_chapters

    cond do
      not is_integer(chapters_total) or chapters_total <= 0 -> nil
      not is_integer(chapters_read) -> nil
      true -> min(100, round(chapters_read * 100 / chapters_total))
    end
  end

  def chapter_progress_percent(_), do: nil

  def replace_tierlist(user_uuid, tiers_map) when is_map(tiers_map) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    # Snapshot the old tiers so we can push only the titles whose
    # mapped MAL score actually changed (avoids re-PATCHing the whole
    # board to MAL on every drag).
    old_tiers =
      from(t in MangaTierlist,
        where: t.user_id == type(^user_uuid, Ecto.UUID),
        select: {{t.source, t.slug}, t.tier}
      )
      |> Repo.all()
      |> Map.new()

    rows =
      tiers_map
      |> Enum.filter(fn {tier, _} -> tier in @tierlist_tiers end)
      |> Enum.flat_map(fn {tier, pairs} ->
        pairs
        |> Enum.with_index()
        |> Enum.map(fn {{source, slug}, idx} ->
          %{
            user_id: user_uuid,
            source: source,
            slug: slug,
            tier: tier,
            position: idx,
            inserted_at: now,
            updated_at: now
          }
        end)
      end)

    result =
      Repo.transaction(fn ->
        Repo.delete_all(from t in MangaTierlist, where: t.user_id == type(^user_uuid, Ecto.UUID))
        if rows != [], do: Repo.insert_all(MangaTierlist, rows)
        :ok
      end)

    sync_changed_tier_scores(user_uuid, old_tiers, rows)
    result
  end

  # Fire an async MAL score sync for each title whose tier→score
  # mapping changed. Best-effort and per-title guarded downstream, so
  # unlinked / disconnected titles simply no-op.
  defp sync_changed_tier_scores(user_uuid, old_tiers, rows) do
    alias Roki.Manga.Trackers.MAL

    rows
    |> Enum.filter(fn %{source: source, slug: slug, tier: tier} ->
      MAL.tier_score(tier) != MAL.tier_score(old_tiers[{source, slug}])
    end)
    |> Enum.each(fn %{source: source, slug: slug} ->
      Task.Supervisor.start_child(Roki.TaskSupervisor, fn ->
        try do
          sync_tier_score(user_uuid, source, slug)
        rescue
          e -> Logger.warning("MAL tier-score sync crashed: #{inspect(e)}")
        end
      end)
    end)
  end

  def list_grid_slots(user_uuid, mode \\ "overall") when mode in @grid_modes do
    rows =
      from(g in MangaGridSlot,
        where: g.user_id == type(^user_uuid, Ecto.UUID) and g.mode == ^mode,
        order_by: [asc: g.slot]
      )
      |> Repo.all()

    if length(rows) == 15 do
      rows
    else
      seed_grid_slots(user_uuid, mode, rows)
      list_grid_slots(user_uuid, mode)
    end
  end

  @doc """
  What someone put on their grid, in the order they put it there — the manga shelf on a
  profile. Each entry carries the title and cover of the saved series it points at.

  The grid has three boards: Overall, Manga and Manhwa. The Overall board is this shelf when it
  has anything on it. When it is empty, which is usual — people tend to keep the two kinds apart
  rather than rank them against each other — the other two boards stand in, taken rank by rank,
  manga then manhwa, so both are represented from the top rather than one board filling the
  shelf before the other begins.

  Reads only. `list_grid_slots/2` fills in the empty places as a side effect of looking, which
  is right on the grid page itself and wrong here: a visitor opening someone's profile should
  not write rows into that account.
  """
  def list_grid_picks(user_uuid, limit \\ 10) do
    rows =
      from(g in MangaGridSlot,
        where: g.user_id == type(^user_uuid, Ecto.UUID),
        where: not is_nil(g.source) and not is_nil(g.slug),
        select: %{slot: g.slot, mode: g.mode, source: g.source, slug: g.slug}
      )
      |> Repo.all()

    {overall, rest} = Enum.split_with(rows, &(&1.mode == "overall"))

    picks =
      if overall != [] do
        Enum.sort_by(overall, & &1.slot)
      else
        rest
        |> Enum.sort_by(&{&1.slot, &1.mode == "manhwa"})
        |> Enum.uniq_by(&{&1.source, &1.slug})
      end

    saved = Map.new(list_saved_manga(user_uuid), fn m -> {{m.source, m.slug}, m} end)
    covers = list_cover_file_uuids(Enum.map(picks, &{&1.source, &1.slug}))

    # The cap is applied last, after the places pointing at a series that is no longer saved
    # have dropped out, so one of those costs the shelf nothing.
    for pick <- picks, m = saved[{pick.source, pick.slug}] do
      Map.merge(pick, %{
        title: m.title,
        cover_url: m.cover_url,
        cover_file_uuid: m.cover_file_uuid || covers[{pick.source, pick.slug}]
      })
    end
    |> Enum.take(limit)
  end

  defp seed_grid_slots(user_uuid, mode, existing) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    taken = MapSet.new(existing, & &1.slot)

    missing =
      1..15
      |> Enum.reject(&MapSet.member?(taken, &1))
      |> Enum.map(fn n ->
        %{
          user_id: user_uuid,
          slot: n,
          mode: mode,
          label: Enum.at(@grid_default_labels, n - 1),
          source: nil,
          slug: nil,
          inserted_at: now,
          updated_at: now
        }
      end)

    if missing != [], do: Repo.insert_all(MangaGridSlot, missing)
  end

  def set_grid_slot(user_uuid, mode, slot, source, slug)
      when slot in 1..15 and mode in @grid_modes do
    from(g in MangaGridSlot,
      where: g.user_id == type(^user_uuid, Ecto.UUID) and g.mode == ^mode and g.slot == ^slot
    )
    |> Repo.update_all(
      set: [
        source: source,
        slug: slug,
        updated_at: NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
      ]
    )
  end

  def bucketize_tierlist(saved_manga, tier_index) do
    {placed, unplaced} =
      Enum.split_with(saved_manga, fn m ->
        Map.has_key?(tier_index, {m.source, m.slug})
      end)

    placed_buckets =
      placed
      |> Enum.group_by(fn m -> elem(Map.fetch!(tier_index, {m.source, m.slug}), 0) end)
      |> Enum.into(%{}, fn {tier, manga_list} ->
        sorted =
          Enum.sort_by(manga_list, fn m ->
            {_, pos} = Map.fetch!(tier_index, {m.source, m.slug})
            pos
          end)

        {tier, sorted}
      end)

    Map.update(placed_buckets, "pool", unplaced, &(&1 ++ unplaced))
  end

  # ──────────────────────────────────────────────────────────────────
  # Chapter page overrides — manual fixes for double-page spread
  # alignment (insert-blank / mark-solo).
  # ──────────────────────────────────────────────────────────────────

  @doc """
  Return the user's page overrides for a chapter, ordered by
  `page_index` so the controller can apply them left-to-right against
  the natural image list.
  """
  def list_page_overrides(user_id, source, slug, chapter) do
    from(o in PageOverride,
      where:
        o.user_id == ^user_id and o.source == ^source and
          o.slug == ^slug and o.chapter == ^chapter,
      order_by: [asc: o.page_index, asc: o.kind]
    )
    |> Repo.all()
  end

  @doc """
  Toggle a page override on/off. Returns `{:ok, :inserted}` or
  `{:ok, :removed}` so the caller can drive UI state, or
  `{:error, changeset}` if validation fails.
  """
  def toggle_page_override(user_id, source, slug, chapter, page_index, kind) do
    case Repo.get_by(PageOverride,
           user_id: user_id,
           source: source,
           slug: slug,
           chapter: chapter,
           page_index: page_index,
           kind: kind
         ) do
      nil ->
        attrs = %{
          user_id: user_id,
          source: source,
          slug: slug,
          chapter: chapter,
          page_index: page_index,
          kind: kind
        }

        case %PageOverride{} |> PageOverride.changeset(attrs) |> Repo.insert() do
          {:ok, _} -> {:ok, :inserted}
          {:error, _} = err -> err
        end

      %PageOverride{} = existing ->
        Repo.delete!(existing)
        {:ok, :removed}
    end
  end
end
