defmodule Roki.Manga.Import do
  @moduledoc """
  Copies one person's manga reading out of the old reader (`sasha.don.ee`, the `:habit_tracker`
  app) into this one. `dev_docs/manga-migration-plan.md` has the why; this is the how.

  The reader keeps serving and keeps its data — nothing here writes to it. Its tables are staged
  into this database first, as the schema `reader_import`, by the two `pg_dump` steps in
  `dev_docs/manga-import-staging.md`. Everything below reads that staging schema.

  **Re-runnable, and it replaces rather than merges.** Every run deletes the mapped people's rows
  from the manga tables and writes them again from the staging schema. That is deliberate: until
  the cutover the old reader is where reading actually happens, so it is the truth and anything
  entered here in the meantime is a copy to be overwritten. After the cutover this task has no
  further business running.

  The shared tables — `roki_manga_titles` and `roki_manga_arcs` — are upserted instead, since
  they belong to no one and other people's rows may already be in them.
  """
  alias Roki.Repo

  # Every series these people have touched, plus every series the reader holds metadata for.
  # One definition, used both to write the series rows and to count them before writing.
  @series """
  select source, slug, max(title) as title, max(cover_url) as cover_url from (
    select s.source, s.slug, s.title, s.cover_url from reader_import.saved_manga s join map m on m.reader = s.user_id
    union all select r.source, r.slug, null, null from reader_import.chapter_reads r join map m on m.reader = r.user_id
    union all select e.source, e.slug, null, null from reader_import.library_events e join map m on m.reader = e.user_id
    union all select k.source, k.slug, null, null from reader_import.manga_marks k join map m on m.reader = k.user_id
    union all select a.source, a.slug, null, null from reader_import.manga_annotations a join map m on m.reader = a.user_id
    union all select p.source, p.slug, null, null from reader_import.chapter_page_overrides p join map m on m.reader = p.user_id
    union all select ti.source, ti.slug, null, null from reader_import.manga_tierlist ti join map m on m.reader = ti.user_id
    union all select g.source, g.slug, null, null from reader_import.manga_grid_slots g join map m on m.reader = g.user_id where g.source is not null
    union all select l.source, l.slug, null, null from reader_import.manga_mal_links l join map m on m.reader = l.user_id
    union all select ra.source, ra.slug, null, null from reader_import.reading_activity ra join map m on m.reader = ra.user_id where ra.source is not null
    union all select md2.source, md2.slug, null, null from reader_import.manga_metadata md2
  ) u group by source, slug
  """

  # Who is being brought across, by username on each side. Everyone else stayed on the old
  # reader: twelve of the eighteen accounts never finished a chapter.
  @pairs [{"sasha", "alex"}, {"maxdon2001", "max"}, {"masha", "masha"}]

  @doc "The username pairs this import knows, reader side first."
  def pairs, do: @pairs

  @doc "Whether the staging schema is loaded."
  def staged? do
    %{rows: [[n]]} =
      Repo.query!(
        "select count(*) from information_schema.tables where table_schema = 'reader_import'"
      )

    n > 0
  end

  @doc """
  The people, resolved on both sides: `{ready, blocked}`. Blocked means the account does not
  exist yet on one side or the other — `masha` has no account here until someone makes her one,
  and a half-done import is worse than none, so `run/0` refuses while anyone is blocked.
  """
  def people do
    rows =
      for {from, to} <- @pairs do
        # `uuid::text`, because Postgrex hands back a uuid column as its raw sixteen bytes.
        %{rows: reader} =
          Repo.query!(
            "select uuid::text from reader_import.reader_users where lower(username) = $1",
            [from]
          )

        %{rows: roki} =
          Repo.query!(
            "select uuid::text from phoenix_kit_users where lower(username::text) = $1",
            [to]
          )

        %{
          from: from,
          to: to,
          reader_uuid: first_uuid(reader),
          roki_uuid: first_uuid(roki)
        }
      end

    Enum.split_with(rows, &(not is_nil(&1.reader_uuid) and not is_nil(&1.roki_uuid)))
  end

  defp first_uuid([[uuid] | _]), do: uuid
  defp first_uuid(_), do: nil

  @doc """
  What a run would write, per table, without writing anything — for whoever resolves, so the
  mapping can be checked against real rows before every account exists: `{counts, blocked}`.
  """
  def report do
    {ready, blocked} = people()

    counts =
      if ready == [], do: [], else: for({label, sql} <- counts(), do: {label, one(sql, ready)})

    {counts, blocked}
  end

  @doc """
  The whole copy, for whoever resolves, inside a transaction that is then rolled back: proof that
  every statement runs against the real rows, leaving nothing behind. Returns what each table
  held before the rollback.
  """
  def rehearse do
    {ready, blocked} = people()

    result =
      Repo.transaction(
        fn ->
          copy(ready)
          Repo.rollback(for({label, sql} <- landed(), do: {label, one(sql, ready)}))
        end,
        timeout: 120_000
      )

    case result do
      {:error, counts} -> {counts, blocked}
      other -> other
    end
  end

  @doc """
  Do it, for everyone in `@pairs` at once or not at all: `{:ok, [{table, count}]}`, or
  `{:error, {:blocked, people}}` when an account is still missing.
  """
  def run do
    case people() do
      {ready, []} -> do_run(ready)
      {_, blocked} -> {:error, {:blocked, blocked}}
    end
  end

  defp do_run(people) do
    Repo.transaction(
      fn ->
        copy(people)
        for {label, sql} <- landed(), do: {label, one(sql, people)}
      end,
      timeout: 120_000
    )
  end

  # Children before parents: the library points at categories, and the membership rows at both.
  defp copy(people) do
    for sql <- deletes(), do: exec(sql, people)
    for sql <- shared(), do: exec(sql, people)
    for sql <- inserts(), do: exec(sql, people)
    :ok
  end

  # What these people now have here, read back from the manga tables themselves.
  defp landed do
    [
      {"titles (shared)", "select count(*) from roki_manga_titles"},
      {"arcs (shared)", "select count(*) from roki_manga_arcs"},
      {"categories",
       "select count(*) from roki_manga_categories c join map m on m.roki = c.user_uuid"},
      {"library", "select count(*) from roki_manga_library l join map m on m.roki = l.user_uuid"},
      {"category members",
       "select count(*) from roki_manga_category_members cm join roki_manga_library l on l.id = cm.library_id join map m on m.roki = l.user_uuid"},
      {"reads", "select count(*) from roki_manga_reads r join map m on m.roki = r.user_uuid"},
      {"reading hours",
       "select count(*) from roki_manga_reading r join map m on m.roki = r.user_uuid"},
      {"events", "select count(*) from roki_manga_events e join map m on m.roki = e.user_uuid"},
      {"marks", "select count(*) from roki_manga_marks k join map m on m.roki = k.user_uuid"},
      {"annotations",
       "select count(*) from roki_manga_annotations a join map m on m.roki = a.user_uuid"},
      {"page overrides",
       "select count(*) from roki_manga_page_overrides p join map m on m.roki = p.user_uuid"},
      {"tiers", "select count(*) from roki_manga_tiers t join map m on m.roki = t.user_uuid"},
      {"grid slots", "select count(*) from roki_manga_grid g join map m on m.roki = g.user_uuid"},
      {"mal links", "select count(*) from roki_manga_mal l join map m on m.roki = l.user_uuid"}
    ]
  end

  # ── the people, as a CTE every statement starts with ─────────────────

  # The pairs arrive as two arrays rather than interpolated text, so no identifier is ever built
  # by hand into a statement.
  defp with_map(sql) do
    "with map(reader, roki) as (select r::uuid, k::uuid from unnest($1::text[], $2::text[]) as t(r, k)) " <>
      sql
  end

  defp params(people), do: [Enum.map(people, & &1.reader_uuid), Enum.map(people, & &1.roki_uuid)]

  defp exec(sql, people), do: Repo.query!(with_map(sql), params(people), timeout: 120_000)

  defp one(sql, people) do
    %{rows: [[n]]} = Repo.query!(with_map(sql), params(people), timeout: 120_000)
    n
  end

  # ── clearing what a previous run wrote ───────────────────────────────

  defp deletes do
    [
      "delete from roki_manga_category_members cm using roki_manga_library l, map m where cm.library_id = l.id and l.user_uuid = m.roki",
      "delete from roki_manga_library l using map m where l.user_uuid = m.roki",
      "delete from roki_manga_categories c using map m where c.user_uuid = m.roki",
      "delete from roki_manga_reads r using map m where r.user_uuid = m.roki",
      "delete from roki_manga_reading r using map m where r.user_uuid = m.roki",
      "delete from roki_manga_events e using map m where e.user_uuid = m.roki",
      "delete from roki_manga_marks k using map m where k.user_uuid = m.roki",
      "delete from roki_manga_annotations a using map m where a.user_uuid = m.roki",
      "delete from roki_manga_page_overrides p using map m where p.user_uuid = m.roki",
      "delete from roki_manga_tiers t using map m where t.user_uuid = m.roki",
      "delete from roki_manga_grid g using map m where g.user_uuid = m.roki",
      "delete from roki_manga_mal l using map m where l.user_uuid = m.roki"
    ]
  end

  # ── the series everyone shares ───────────────────────────────────────

  defp shared do
    [
      """
      insert into roki_manga_titles (source, slug, title, cover_url, cover_file_uuid, data, inserted_at, updated_at)
      select t.source, t.slug,
             coalesce(md.data->>'title', t.title),
             coalesce(md.data->>'cover_url', t.cover_url),
             md.cover_file_uuid,
             coalesce(md.data, '{}'::jsonb),
             now(), now()
      from (#{@series}) t
      left join reader_import.manga_metadata md on md.source = t.source and md.slug = t.slug
      on conflict (source, slug) do update set
        title = coalesce(excluded.title, roki_manga_titles.title),
        cover_url = coalesce(excluded.cover_url, roki_manga_titles.cover_url),
        cover_file_uuid = coalesce(excluded.cover_file_uuid, roki_manga_titles.cover_file_uuid),
        data = case when excluded.data = '{}'::jsonb then roki_manga_titles.data else excluded.data end,
        updated_at = now()
      """,
      """
      insert into roki_manga_arcs (manga_id, story_slug, story, arcs, units, volumes, synced_at, inserted_at, updated_at)
      select t.id, d.story_slug, d.story, d.arcs, d.units, d.volumes, d.synced_at, d.inserted_at, d.updated_at
      from reader_import.manga_story_data d
      join roki_manga_titles t on t.source = d.source and t.slug = d.slug
      on conflict (manga_id) do update set
        story_slug = excluded.story_slug, story = excluded.story, arcs = excluded.arcs,
        units = excluded.units, volumes = excluded.volumes, synced_at = excluded.synced_at,
        updated_at = now()
      """
    ]
  end

  # ── one person's own rows ────────────────────────────────────────────

  defp inserts do
    [
      # Shelves first: the library points at them.
      """
      insert into roki_manga_categories (user_uuid, name, position, inserted_at, updated_at)
      select m.roki, c.name, c.position, c.inserted_at, c.updated_at
      from reader_import.manga_categories c join map m on m.reader = c.user_id
      """,
      """
      insert into roki_manga_library (
        user_uuid, manga_id, title, cover_url, cover_file_uuid, category_id,
        reading_mode, reading_mode_desktop, reading_mode_mobile, reading_direction, reading_rotation,
        smart_crop, comments_visible, tap_zone_preset, tap_zone_preset_desktop, tap_zone_preset_mobile,
        last_chapter, last_chapter_number, last_chapter_total_pages, last_page, last_page_fraction,
        max_chapter, total_chapters, completed, newest_chapter_at,
        reading_seconds, reading_seconds_adjusted, reading_seconds_offsite,
        reading_seconds_offsite_approximate, chapter_seconds, visiting_chapter, visiting_seconds,
        chapter_near_end, prev_chapter, prev_chapter_seconds, prev_chapter_near_end,
        inserted_at, updated_at)
      select m.roki, t.id, s.title, s.cover_url, s.cover_file_uuid, rc.id,
             s.reading_mode, s.reading_mode_desktop, s.reading_mode_mobile, s.reading_direction, s.reading_rotation,
             s.smart_crop, s.comments_visible, s.tap_zone_preset, s.tap_zone_preset_desktop, s.tap_zone_preset_mobile,
             s.last_chapter, s.last_chapter_number, s.last_chapter_total_pages, s.last_page, s.last_page_fraction,
             s.max_chapter, s.total_chapters, s.completed, s.newest_chapter_at,
             s.reading_seconds, s.reading_seconds_adjusted, s.reading_seconds_offsite,
             s.reading_seconds_offsite_approximate, s.chapter_seconds, s.visiting_chapter, s.visiting_seconds,
             s.chapter_near_end, s.prev_chapter, s.prev_chapter_seconds, s.prev_chapter_near_end,
             s.inserted_at, s.updated_at
      from reader_import.saved_manga s
      join map m on m.reader = s.user_id
      join roki_manga_titles t on t.source = s.source and t.slug = s.slug
      left join reader_import.manga_categories oc on oc.id = s.category_id
      left join roki_manga_categories rc on rc.user_uuid = m.roki and rc.name = oc.name
      """,
      """
      insert into roki_manga_category_members (library_id, category_id, inserted_at, updated_at)
      select l.id, rc.id, mm.inserted_at, mm.updated_at
      from reader_import.manga_category_memberships mm
      join reader_import.saved_manga s on s.id = mm.saved_manga_id
      join map m on m.reader = s.user_id
      join roki_manga_titles t on t.source = s.source and t.slug = s.slug
      join roki_manga_library l on l.user_uuid = m.roki and l.manga_id = t.id
      join reader_import.manga_categories oc on oc.id = mm.category_id
      join roki_manga_categories rc on rc.user_uuid = m.roki and rc.name = oc.name
      """,
      """
      insert into roki_manga_reads (user_uuid, manga_id, chapter, read_at, seconds, total_pages)
      select m.roki, t.id, r.chapter, r.read_at, r.seconds, r.total_pages
      from reader_import.chapter_reads r
      join map m on m.reader = r.user_id
      join roki_manga_titles t on t.source = r.source and t.slug = r.slug
      """,
      """
      insert into roki_manga_reading (user_uuid, manga_id, title, date, hour, reading_seconds, chapters_read, inserted_at, updated_at)
      select m.roki, t.id, ra.title, ra.date, ra.hour, ra.reading_seconds, ra.chapters_read, ra.inserted_at, ra.updated_at
      from reader_import.reading_activity ra
      join map m on m.reader = ra.user_id
      left join roki_manga_titles t on t.source = ra.source and t.slug = ra.slug
      """,
      """
      insert into roki_manga_events (user_uuid, manga_id, event, chapter, happened_at)
      select m.roki, t.id, e.event, e.chapter, e.happened_at
      from reader_import.library_events e
      join map m on m.reader = e.user_id
      join roki_manga_titles t on t.source = e.source and t.slug = e.slug
      """,
      """
      insert into roki_manga_marks (user_uuid, manga_id, chapter, items, inserted_at, updated_at)
      select m.roki, t.id, k.chapter,
             array(select jsonb_array_elements(k.items)), k.inserted_at, k.updated_at
      from reader_import.manga_marks k
      join map m on m.reader = k.user_id
      join roki_manga_titles t on t.source = k.source and t.slug = k.slug
      """,
      """
      insert into roki_manga_annotations (user_uuid, comment_uuid, manga_id, chapter, page, title,
        x_pct, y_pct, w_pct, h_pct, color, visibility, inserted_at, updated_at)
      select m.roki, a.comment_uuid, t.id, a.chapter, a.page, a.title,
             a.x_pct, a.y_pct, a.w_pct, a.h_pct, a.color, a.visibility, a.inserted_at, a.updated_at
      from reader_import.manga_annotations a
      join map m on m.reader = a.user_id
      join roki_manga_titles t on t.source = a.source and t.slug = a.slug
      """,
      """
      insert into roki_manga_page_overrides (user_uuid, manga_id, chapter, page_index, kind, inserted_at, updated_at)
      select m.roki, t.id, p.chapter, p.page_index, p.kind, p.inserted_at, p.updated_at
      from reader_import.chapter_page_overrides p
      join map m on m.reader = p.user_id
      join roki_manga_titles t on t.source = p.source and t.slug = p.slug
      """,
      """
      insert into roki_manga_tiers (user_uuid, manga_id, tier, position, inserted_at, updated_at)
      select m.roki, t.id, ti.tier, ti.position, ti.inserted_at, ti.updated_at
      from reader_import.manga_tierlist ti
      join map m on m.reader = ti.user_id
      join roki_manga_titles t on t.source = ti.source and t.slug = ti.slug
      """,
      """
      insert into roki_manga_grid (user_uuid, mode, slot, label, manga_id, inserted_at, updated_at)
      select m.roki, g.mode, g.slot, g.label, t.id, g.inserted_at, g.updated_at
      from reader_import.manga_grid_slots g
      join map m on m.reader = g.user_id
      left join roki_manga_titles t on t.source = g.source and t.slug = g.slug
      """,
      """
      insert into roki_manga_mal (user_uuid, manga_id, mal_id, data, inserted_at, updated_at)
      select m.roki, t.id, l.mal_id, l.data, l.inserted_at, l.updated_at
      from reader_import.manga_mal_links l
      join map m on m.reader = l.user_id
      join roki_manga_titles t on t.source = l.source and t.slug = l.slug
      """
    ]
  end

  # ── what a run would write (the same joins, counted) ─────────────────

  defp counts do
    [
      {"titles (shared)", "select count(*) from (#{@series}) t"},
      {"arcs (shared)",
       "select count(*) from reader_import.manga_story_data d where exists (select 1 from (#{@series}) t where t.source = d.source and t.slug = d.slug)"},
      {"categories",
       "select count(*) from reader_import.manga_categories c join map m on m.reader = c.user_id"},
      {"library",
       "select count(*) from reader_import.saved_manga s join map m on m.reader = s.user_id"},
      {"category members",
       "select count(*) from reader_import.manga_category_memberships mm join reader_import.saved_manga s on s.id = mm.saved_manga_id join map m on m.reader = s.user_id"},
      {"reads",
       "select count(*) from reader_import.chapter_reads r join map m on m.reader = r.user_id"},
      {"reading hours",
       "select count(*) from reader_import.reading_activity ra join map m on m.reader = ra.user_id"},
      {"events",
       "select count(*) from reader_import.library_events e join map m on m.reader = e.user_id"},
      {"marks",
       "select count(*) from reader_import.manga_marks k join map m on m.reader = k.user_id"},
      {"annotations",
       "select count(*) from reader_import.manga_annotations a join map m on m.reader = a.user_id"},
      {"page overrides",
       "select count(*) from reader_import.chapter_page_overrides p join map m on m.reader = p.user_id"},
      {"tiers",
       "select count(*) from reader_import.manga_tierlist ti join map m on m.reader = ti.user_id"},
      {"grid slots",
       "select count(*) from reader_import.manga_grid_slots g join map m on m.reader = g.user_id"},
      {"mal links",
       "select count(*) from reader_import.manga_mal_links l join map m on m.reader = l.user_id"}
    ]
  end
end
