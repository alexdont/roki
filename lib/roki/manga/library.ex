defmodule Roki.Manga.Library do
  @moduledoc """
  One person's manga: what they have saved, where they are in it, and how long they have spent.

  The counting rules are the old reader's, carried over deliberately rather than redesigned — a
  chapter counts as read when the reader reached its last tenth *and* spent long enough in it,
  where "long enough" scales with the chapter's length; reading behind your furthest point is
  treated as a visit and does not move your place until you have stayed five minutes. Those rules
  were arrived at by someone watching their own history come out wrong, and the comments that
  explain them are kept with them.

  A series is `(source, slug)` to a reader and an integer id here, so everything below starts by
  turning the first into the second (`series_id/2`).
  """
  alias Roki.Repo
  require Logger

  # A progress tick carries at most five minutes, however long the tab really sat open.
  @max_tick 300
  # Reading behind your place commits after this long, and not before.
  @commit_after 300

  # ── the series ───────────────────────────────────────────────────────

  @doc "The id of a series, inserting it the first time it is seen."
  def series_id(source, slug) do
    %{rows: [[id]]} =
      Repo.query!(
        """
        insert into roki_manga_titles (source, slug, inserted_at, updated_at)
        values ($1, $2, now(), now())
        on conflict (source, slug) do update set updated_at = roki_manga_titles.updated_at
        returning id
        """,
        [source, slug]
      )

    id
  end

  @doc "What the series is called and what it looks like, as last seen."
  def series(id) do
    case Repo.query!(
           "select source, slug, title, cover_url, data from roki_manga_titles where id = $1",
           [id]
         ) do
      %{rows: [[source, slug, title, cover, data]]} ->
        %{id: id, source: source, slug: slug, title: title, cover_url: cover, data: data || %{}}

      _ ->
        nil
    end
  end

  @doc "Remember what a source said about a series, so a shelf can be drawn without fetching."
  def remember(id, attrs) do
    Repo.query!(
      """
      update roki_manga_titles
         set title = coalesce($2, title), cover_url = coalesce($3, cover_url),
             data = case when $4::jsonb is null then data else $4::jsonb end, updated_at = now()
       where id = $1
      """,
      [id, attrs[:title], attrs[:cover_url], attrs[:data] && Jason.encode!(attrs[:data])]
    )

    :ok
  end

  # ── where someone is in it ───────────────────────────────────────────

  @state_columns ~w(title reading_mode reading_mode_desktop reading_mode_mobile reading_direction
                    reading_rotation smart_crop comments_visible tap_zone_preset
                    tap_zone_preset_desktop tap_zone_preset_mobile last_chapter last_page
                    last_page_fraction max_chapter)a

  @doc """
  The reader's saved state for a series, as `Manhwa.Store` wants it — `nil` when they have never
  saved it, which is how the reader knows to fall back to its own defaults.
  """
  def state(user_uuid, source, slug) do
    sql = """
    select l.title, l.reading_mode, l.reading_mode_desktop, l.reading_mode_mobile,
           l.reading_direction, l.reading_rotation, l.smart_crop, l.comments_visible,
           l.tap_zone_preset, l.tap_zone_preset_desktop, l.tap_zone_preset_mobile,
           l.last_chapter, l.last_page, l.last_page_fraction, l.max_chapter
      from roki_manga_library l
      join roki_manga_titles t on t.id = l.manga_id
     where l.user_uuid = $1::text::uuid and t.source = $2 and t.slug = $3
    """

    case Repo.query!(sql, [user_uuid, source, slug]) do
      %{rows: [row]} ->
        state = Enum.zip(@state_columns, row) |> Map.new()
        # The series' own title when the reader never gave it one of their own.
        if state.title in [nil, ""], do: %{state | title: title_of(source, slug)}, else: state

      _ ->
        nil
    end
  end

  defp title_of(source, slug) do
    case Repo.query!("select title from roki_manga_titles where source = $1 and slug = $2", [
           source,
           slug
         ]) do
      %{rows: [[title]]} -> title
      _ -> nil
    end
  end

  @doc "Everything one person has saved, most recently read first, optionally one shelf of it."
  def shelf(user_uuid, category_id \\ nil) do
    sql = """
    select t.id, t.source, t.slug, coalesce(nullif(l.title, ''), t.title) as title,
           coalesce(nullif(l.cover_url, ''), t.cover_url) as cover_url,
           l.last_chapter, l.last_chapter_number, l.max_chapter, l.total_chapters, l.completed,
           l.reading_seconds, l.updated_at
      from roki_manga_library l
      join roki_manga_titles t on t.id = l.manga_id
     where l.user_uuid = $1::text::uuid
       and ($2::bigint is null or l.category_id = $2::bigint
             or exists (select 1 from roki_manga_category_members cm
                         where cm.library_id = l.id and cm.category_id = $2::bigint))
     order by l.updated_at desc nulls last
    """

    %{rows: rows} = Repo.query!(sql, [user_uuid, category_id])

    for [id, source, slug, title, cover, last, last_n, max, total, done, seconds, at] <- rows do
      %{
        id: id,
        source: source,
        slug: slug,
        title: title || slug,
        cover_url: cover,
        last_chapter: last,
        last_number: last_n,
        max_chapter: max,
        total_chapters: total,
        completed: done,
        reading_seconds: seconds || 0,
        updated_at: at
      }
    end
  end

  @doc """
  The shelf as the old reader's home page arranges it: what you are in the middle of, what you
  have caught up on, what you finished, and what you have never opened. Reading first and most
  recent first within it, which is the order someone actually wants.
  """
  def home(user_uuid, category_id \\ nil) do
    shelf = shelf(user_uuid, category_id)

    groups =
      Enum.group_by(shelf, fn item ->
        cond do
          item.completed -> :completed
          item.last_chapter in [nil, ""] -> :unread
          caught_up?(item) -> :caught_up
          true -> :reading
        end
      end)

    %{
      reading: Map.get(groups, :reading, []),
      caught_up: Map.get(groups, :caught_up, []),
      completed: Map.get(groups, :completed, []),
      unread: Map.get(groups, :unread, []),
      count: length(shelf)
    }
  end

  # Caught up means there is nothing left that we know of: the chapter they are on is the last
  # one the source told us about. Without a count of chapters we cannot say, so we do not.
  defp caught_up?(%{last_number: n, total_chapters: total})
       when is_integer(n) and is_integer(total) and total > 0,
       do: n >= total

  defp caught_up?(_), do: false

  @doc "Someone's own shelves, in their order."
  def categories(user_uuid) do
    %{rows: rows} =
      Repo.query!(
        "select id, name from roki_manga_categories where user_uuid = $1::text::uuid order by position, name",
        [user_uuid]
      )

    for [id, name] <- rows, do: %{id: id, name: name}
  end

  @doc "Put a series on someone's shelf (or leave it where it is)."
  def save(user_uuid, source, slug) do
    id = series_id(source, slug)

    Repo.query!(
      """
      insert into roki_manga_library (user_uuid, manga_id, inserted_at, updated_at)
      values ($1::text::uuid, $2, now(), now())
      on conflict (user_uuid, manga_id) do nothing
      """,
      [user_uuid, id]
    )

    :ok
  end

  # ── settings ─────────────────────────────────────────────────────────

  @doc """
  One of the reader's own settings. The per-device ones land in the slot for the device asking —
  `"mobile"`, `"desktop"`, or both when the reader says `"all"`.
  """
  def put_setting(user_uuid, source, slug, setting, value, device \\ nil)

  def put_setting(user_uuid, source, slug, setting, value, device)
      when setting in [:reading_mode, :tap_zone_preset] do
    column = Atom.to_string(setting)

    columns =
      case device do
        "mobile" -> [column <> "_mobile"]
        "desktop" -> [column <> "_desktop"]
        _ -> [column, column <> "_desktop", column <> "_mobile"]
      end

    set = columns |> Enum.map(&"#{&1} = $4") |> Enum.join(", ")
    write(user_uuid, source, slug, set, [value])
  end

  def put_setting(user_uuid, source, slug, setting, value, _device)
      when setting in [:reading_direction, :reading_rotation, :smart_crop, :comments_visible] do
    write(user_uuid, source, slug, "#{setting} = $4", [value])
  end

  defp write(user_uuid, source, slug, set, params) do
    Repo.query!(
      """
      update roki_manga_library l
         set #{set}, updated_at = now()
        from roki_manga_titles t
       where t.id = l.manga_id and l.user_uuid = $1::text::uuid and t.source = $2 and t.slug = $3
      """,
      [user_uuid, source, slug] ++ params
    )

    :ok
  end

  # ── reading ──────────────────────────────────────────────────────────

  @doc """
  A progress tick from the reader: where they are, and how long since the last one.

  Everything subtle in this function came from the old reader, and the reasons are kept with it:

    * A chapter counts as read when the reader reached its last tenth **and** stayed long enough.
      "Long enough" is a second and a half a page, held between ten and sixty seconds — a flat
      ninety-second floor used to throw away genuinely finished short chapters during a binge,
      and three seconds a page was still slower than people actually read art-heavy titles.
    * Reading *behind* your furthest point is a visit, not a move: your place only follows you
      there once you have stayed five minutes, so flicking back to check something does not cost
      you your position.
    * The chapter you were on before is kept beside the current one, so stepping back to it
      restores its clock instead of starting it again from zero.

  Returns `{:ok, %{chapter_read: boolean}}`, which is what tells the reader to show its tick.
  """
  def update_progress(user_uuid, source, slug, chapter, page, elapsed, total_pages, fraction) do
    elapsed = elapsed |> max(0) |> min(@max_tick)
    fraction = (fraction || 0.0) |> max(0.0) |> min(1.0)
    saved = current(user_uuid, source, slug)

    if saved == nil do
      # Not on their shelf: opening a source to see whether it works should leave no trace.
      {:ok, %{chapter_read: false}}
    else
      place = saved.visiting_chapter || saved.last_chapter
      backward? = place != nil and chapter != place and not Chapter.gt?(chapter, place)
      near_end? = is_integer(total_pages) and total_pages > 0 and page >= ceil(total_pages * 0.9)

      before =
        cond do
          backward? and saved.visiting_chapter == chapter -> saved.visiting_seconds || 0
          saved.prev_chapter == chapter -> saved.prev_chapter_seconds || 0
          not backward? and chapter == saved.last_chapter -> saved.chapter_seconds || 0
          true -> 0
        end

      seconds = before + elapsed

      was_near_end? =
        if saved.prev_chapter == chapter and chapter != saved.last_chapter,
          do: saved.prev_chapter_near_end || false,
          else: saved.chapter_near_end || false

      required =
        case total_pages do
          n when is_integer(n) and n > 0 -> min(60, max(10, round(n * 1.5)))
          _ -> 60
        end

      counted? =
        (was_near_end? or near_end?) and seconds >= required and
          (before < required or (not was_near_end? and near_end?))

      if elapsed > 0,
        do:
          record(user_uuid, saved, source, slug, chapter, elapsed, seconds, total_pages, counted?)

      if backward?,
        do:
          visit(
            user_uuid,
            saved,
            source,
            slug,
            chapter,
            page,
            fraction,
            total_pages,
            elapsed,
            near_end?
          ),
        else:
          advance(
            user_uuid,
            saved,
            source,
            slug,
            chapter,
            page,
            fraction,
            total_pages,
            elapsed,
            near_end?
          )

      {:ok, %{chapter_read: counted?}}
    end
  end

  # What the row says before this tick.
  defp current(user_uuid, source, slug) do
    sql = """
    select l.id, l.manga_id, l.last_chapter, l.chapter_seconds, l.chapter_near_end, l.max_chapter,
           l.visiting_chapter, l.visiting_seconds, l.prev_chapter, l.prev_chapter_seconds,
           l.prev_chapter_near_end, l.reading_seconds, coalesce(nullif(l.title, ''), t.title)
      from roki_manga_library l
      join roki_manga_titles t on t.id = l.manga_id
     where l.user_uuid = $1::text::uuid and t.source = $2 and t.slug = $3
    """

    case Repo.query!(sql, [user_uuid, source, slug]) do
      %{
        rows: [[id, manga_id, last, secs, near, max, vch, vsecs, pch, psecs, pnear, total, title]]
      } ->
        %{
          id: id,
          manga_id: manga_id,
          last_chapter: last,
          chapter_seconds: secs,
          chapter_near_end: near,
          max_chapter: max,
          visiting_chapter: vch,
          visiting_seconds: vsecs,
          prev_chapter: pch,
          prev_chapter_seconds: psecs,
          prev_chapter_near_end: pnear,
          reading_seconds: total,
          title: title
        }

      _ ->
        nil
    end
  end

  # The rollups and the logs beside the row itself. None of them may break the save.
  defp record(user_uuid, saved, _source, _slug, chapter, elapsed, seconds, total_pages, counted?) do
    hour = DateTime.utc_now()

    try do
      Repo.query!(
        """
        insert into roki_manga_reading (user_uuid, manga_id, title, date, hour, reading_seconds, chapters_read, inserted_at, updated_at)
        values ($1::text::uuid, $2, $3, $4::date, $5, $6, $7, now(), now())
        on conflict (user_uuid, date, hour, manga_id) do update
          set reading_seconds = roki_manga_reading.reading_seconds + excluded.reading_seconds,
              chapters_read = roki_manga_reading.chapters_read + excluded.chapters_read,
              updated_at = now()
        """,
        [
          user_uuid,
          saved.manga_id,
          saved.title,
          DateTime.to_date(hour),
          hour.hour,
          elapsed,
          if(counted?, do: 1, else: 0)
        ]
      )

      if counted? do
        Repo.query!(
          "insert into roki_manga_reads (user_uuid, manga_id, chapter, read_at, seconds, total_pages) values ($1::text::uuid, $2, $3, now(), $4, $5)",
          [user_uuid, saved.manga_id, chapter, seconds, total_pages]
        )
      end

      # The very first tick on a title is the moment they started it. `reading_seconds` is still
      # the value from before this tick, so only the first one ever can qualify.
      if (saved.reading_seconds || 0) == 0 do
        Repo.query!(
          """
          insert into roki_manga_events (user_uuid, manga_id, event, chapter, happened_at)
          select $1::text::uuid, $2, 'started', $3, now()
           where not exists (
             select 1 from roki_manga_events
              where user_uuid = $1::text::uuid and manga_id = $2 and event = 'started')
          """,
          [user_uuid, saved.manga_id, chapter]
        )
      end
    rescue
      e -> Logger.warning("manga: logging progress failed: #{inspect(e)}")
    end
  end

  # Reading behind their place: hold the position, count the visit, and only move once they have
  # stayed five minutes.
  defp visit(
         _user_uuid,
         saved,
         _source,
         _slug,
         chapter,
         page,
         fraction,
         total_pages,
         elapsed,
         near_end?
       ) do
    before =
      cond do
        saved.visiting_chapter == chapter -> saved.visiting_seconds || 0
        saved.prev_chapter == chapter -> saved.prev_chapter_seconds || 0
        true -> 0
      end

    visiting = before + elapsed

    if visiting >= @commit_after do
      set(saved.id, elapsed,
        last_chapter: chapter,
        last_page: page,
        last_page_fraction: fraction,
        last_chapter_total_pages: total_pages,
        chapter_seconds: visiting,
        chapter_near_end: near_end?,
        visiting_chapter: nil,
        visiting_seconds: 0,
        completed: false
      )
    else
      set(saved.id, elapsed,
        visiting_chapter: chapter,
        visiting_seconds: visiting,
        completed: false
      )
    end
  end

  # Going forward, or staying put.
  defp advance(
         user_uuid,
         saved,
         _source,
         _slug,
         chapter,
         page,
         fraction,
         total_pages,
         elapsed,
         near_end?
       ) do
    changed? = saved.last_chapter != chapter
    returning? = saved.prev_chapter == chapter
    furthest? = saved.max_chapter == nil or Chapter.gt?(chapter, saved.max_chapter)

    common = [
      last_chapter: chapter,
      last_page: page,
      last_page_fraction: fraction,
      last_chapter_total_pages: total_pages,
      visiting_chapter: nil,
      visiting_seconds: 0,
      completed: false
    ]

    fields =
      cond do
        changed? and returning? ->
          # Stepping back to the chapter they were on before: its clock comes back with it, and
          # the one they are leaving takes its place.
          common ++
            [
              chapter_seconds: (saved.prev_chapter_seconds || 0) + elapsed,
              chapter_near_end: (saved.prev_chapter_near_end || false) or near_end?,
              prev_chapter: saved.last_chapter,
              prev_chapter_seconds: saved.chapter_seconds || 0,
              prev_chapter_near_end: saved.chapter_near_end || false
            ]

        changed? ->
          common ++
            [
              chapter_seconds: elapsed,
              chapter_near_end: near_end?,
              prev_chapter: saved.last_chapter,
              prev_chapter_seconds: saved.chapter_seconds || 0,
              prev_chapter_near_end: saved.chapter_near_end || false
            ]

        true ->
          common ++
            [
              chapter_seconds: (saved.chapter_seconds || 0) + elapsed,
              chapter_near_end: (saved.chapter_near_end || false) or near_end?
            ]
      end

    fields = if furthest?, do: Keyword.put(fields, :max_chapter, chapter), else: fields
    set(saved.id, elapsed, fields)
    if furthest?, do: caught_up(user_uuid, saved, chapter)
  end

  # Crossing their furthest point is the moment a title becomes one they are caught up on.
  defp caught_up(user_uuid, saved, chapter) do
    try do
      Repo.query!(
        """
        insert into roki_manga_events (user_uuid, manga_id, event, chapter, happened_at)
        select $1::text::uuid, $2, 'caught_up', $3, now()
         where not exists (
           select 1 from roki_manga_events
            where user_uuid = $1::text::uuid and manga_id = $2 and event = 'caught_up' and chapter = $3)
        """,
        [user_uuid, saved.manga_id, chapter]
      )
    rescue
      e -> Logger.warning("manga: logging caught-up failed: #{inspect(e)}")
    end
  end

  # One update, with the time always added rather than replaced.
  defp set(id, elapsed, fields) do
    {sql, params} =
      fields
      |> Enum.with_index(2)
      |> Enum.reduce({[], []}, fn {{column, value}, i}, {sets, params} ->
        {sets ++ ["#{column} = $#{i}"], params ++ [value]}
      end)

    Repo.query!(
      "update roki_manga_library set #{Enum.join(sql, ", ")}, reading_seconds = coalesce(reading_seconds, 0) + $#{length(params) + 2}, updated_at = now() where id = $1",
      [id] ++ params ++ [elapsed]
    )

    :ok
  end

  # ── page overrides ───────────────────────────────────────────────────

  @doc "The hand-fixed spreads for a chapter."
  def page_overrides(user_uuid, source, slug, chapter) do
    sql = """
    select p.page_index, p.kind
      from roki_manga_page_overrides p
      join roki_manga_titles t on t.id = p.manga_id
     where p.user_uuid = $1::text::uuid and t.source = $2 and t.slug = $3 and p.chapter = $4
    """

    %{rows: rows} = Repo.query!(sql, [user_uuid, source, slug, chapter])
    for [index, kind] <- rows, do: %{page_index: index, kind: kind}
  end

  @doc "Add a spread fix, or take it away if it is already there."
  def toggle_page_override(user_uuid, source, slug, chapter, page_index, kind) do
    id = series_id(source, slug)

    deleted =
      Repo.query!(
        """
        delete from roki_manga_page_overrides
         where user_uuid = $1::text::uuid and manga_id = $2 and chapter = $3 and page_index = $4 and kind = $5
        """,
        [user_uuid, id, chapter, page_index, kind]
      )

    if deleted.num_rows > 0 do
      {:ok, :removed}
    else
      Repo.query!(
        """
        insert into roki_manga_page_overrides (user_uuid, manga_id, chapter, page_index, kind, inserted_at, updated_at)
        values ($1::text::uuid, $2, $3, $4, $5, now(), now())
        """,
        [user_uuid, id, chapter, page_index, kind]
      )

      {:ok, :added}
    end
  end
end
