defmodule Roki.Manga.Import do
  @moduledoc """
  Copies one person's manga reading out of the old reader (`sasha.don.ee`, the `:habit_tracker`
  app) into this one. `dev_docs/manga-migration-plan.md` has the why; this is the how.

  The tables here are the reader's own, name for name and column for column, so this is a row
  copy and not a translation: every column is carried across by name, with `user_id` swapped for
  the matching account here and the primary keys kept so the rows that point at each other still
  do. Nothing is written to the reader — its tables are staged into this database first, as the
  schema `reader_import` (`dev_docs/manga-import-staging.md`).

  **Re-runnable, and it replaces rather than merges.** Every run clears the mapped people's rows
  and writes them again. Until the cutover the old reader is where reading actually happens, so
  it is the truth and anything entered here meanwhile is a copy to be overwritten.
  """
  alias Roki.Repo

  # Who is being brought across, by username on each side.
  @pairs [{"sasha", "alex"}, {"maxdon2001", "max"}, {"masha", "masha"}]

  # Theirs alone, in an order that respects what points at what: shelves first, then the library
  # row that may name one, then the join between them.
  @owned ~w(manga_categories saved_manga manga_category_memberships chapter_reads
            reading_activity library_events manga_marks manga_annotations
            chapter_page_overrides manga_grid_slots manga_tierlist manga_mal_links
            manga_tracker_tokens)

  # Nobody's in particular: what the sources said about a series, and its arcs.
  @shared ~w(manga_metadata manga_story_data)

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
  exist yet on one side or the other, and `run/1` refuses while anyone is blocked unless told
  which people to bring.
  """
  def people do
    rows =
      for {from, to} <- @pairs do
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

        %{from: from, to: to, reader_uuid: first(reader), roki_uuid: first(roki)}
      end

    Enum.split_with(rows, &(not is_nil(&1.reader_uuid) and not is_nil(&1.roki_uuid)))
  end

  defp first([[uuid] | _]), do: uuid
  defp first(_), do: nil

  @doc "What a run would write, per table, without writing anything: `{counts, blocked}`."
  def report do
    {ready, blocked} = people()
    {if(ready == [], do: [], else: counts(ready)), blocked}
  end

  @doc """
  The whole copy inside a transaction that is then rolled back: proof that every statement runs
  against the real rows, leaving nothing behind.
  """
  def rehearse do
    {ready, blocked} = people()

    result =
      Repo.transaction(fn -> copy(ready) && Repo.rollback(counts(ready)) end, timeout: 300_000)

    case result do
      {:error, counts} -> {counts, blocked}
      other -> other
    end
  end

  @doc """
  Do it. `only: ["sasha"]` brings just those people; without it everyone in `@pairs` comes at
  once or not at all, since a half-finished import is worse than none.
  """
  def run(opts \\ []) do
    {ready, blocked} = people()

    case Keyword.get(opts, :only) do
      nil when blocked == [] -> do_run(ready)
      nil -> {:error, {:blocked, blocked}}
      names -> ready |> Enum.filter(&(&1.from in names)) |> do_run()
    end
  end

  defp do_run(people) do
    Repo.transaction(
      fn ->
        copy(people)
        resequence()
        counts(people)
      end,
      timeout: 300_000
    )
  end

  # ── the copy itself ──────────────────────────────────────────────────

  defp copy(people) do
    for table <- Enum.reverse(@owned), do: clear(table, people)
    for table <- @shared, do: copy_shared(table)
    for table <- @owned, do: copy_owned(table, people)
    rehost_sidecar()
    drop_missing_covers()
    true
  end

  @doc """
  Cover addresses that point at a sidecar, pointed at ours.

  A series whose pages come from an extension has the sidecar's own address saved inside its
  cover url. On the machine this data came from that was a process on the loopback; here it is a
  container on this stack's network, so the saved address resolves to nothing and the cover
  silently fails to load. The address is in the rows, so every import brings it back — which is
  why this runs as part of one rather than by hand afterwards.

  Matched on shape (`scheme://host:port/sources/...`) rather than on the old host, so it keeps
  working if either end moves again.
  """
  def rehost_sidecar do
    base = Application.get_env(:roki, :kotatsu_url, "http://kotatsu:8420")

    %{num_rows: saved} =
      Repo.query!(
        """
        update saved_manga
           set cover_url = $1 || substring(cover_url from '/sources/.*$')
         where cover_url ~ '^https?://[^/]+:[0-9]+/sources/'
           and cover_url not like $2
        """,
        [base, base <> "%"]
      )

    %{num_rows: meta} =
      Repo.query!(
        """
        update manga_metadata
           set data = jsonb_set(data, '{cover_url}',
                        to_jsonb($1::text || substring(data->>'cover_url' from '/sources/.*$')))
         where data->>'cover_url' ~ '^https?://[^/]+:[0-9]+/sources/'
           and data->>'cover_url' not like $2
        """,
        [base, base <> "%"]
      )

    {saved, meta}
  end

  @doc """
  Covers that point at a file nobody copied, forgotten.

  `saved_manga.cover_file_uuid` points into the media library. A row whose file did not come
  across still carries the uuid, so the page asks for a file that is not there and the cover
  404s — four times per cover on the home page — while the `cover_url` beside it sits unused.
  Clearing the uuid is what lets the address take over.

  Runs as part of an import rather than by hand afterwards, for the same reason
  `rehost_sidecar/0` does: the rows bring it back every time.
  """
  def drop_missing_covers do
    %{num_rows: n} =
      Repo.query!("""
      update saved_manga s
         set cover_file_uuid = null
       where s.cover_file_uuid is not null
         and not exists (select 1 from phoenix_kit_files f where f.uuid = s.cover_file_uuid)
      """)

    n
  end

  # Their rows, by whichever column that table uses to say whose they are.
  defp clear("manga_category_memberships", people) do
    exec(
      """
      delete from manga_category_memberships cm
       using saved_manga s, map m
       where cm.saved_manga_id = s.id and s.user_id = m.roki
      """,
      people
    )
  end

  defp clear(table, people),
    do: exec("delete from #{table} t using map m where t.user_id = m.roki", people)

  # Every column by name, so this keeps working as columns come and go — `user_id` swapped for
  # the account here, everything else carried as it stands.
  defp copy_owned("manga_category_memberships", people) do
    exec(
      """
      insert into manga_category_memberships (id, saved_manga_id, category_id, inserted_at, updated_at)
      select cm.id, cm.saved_manga_id, cm.category_id, cm.inserted_at, cm.updated_at
        from reader_import.manga_category_memberships cm
        join reader_import.saved_manga s on s.id = cm.saved_manga_id
        join map m on m.reader = s.user_id
      """,
      people
    )
  end

  defp copy_owned(table, people) do
    cols = columns(table)

    select =
      Enum.map_join(cols, ", ", fn
        "user_id" -> "m.roki"
        c -> "t.#{quoted(c)}"
      end)

    exec(
      "insert into #{table} (#{Enum.map_join(cols, ", ", &quoted/1)}) " <>
        "select #{select} from reader_import.#{table} t join map m on m.reader = t.user_id",
      people
    )
  end

  defp copy_shared(table) do
    cols = Enum.map_join(columns(table), ", ", &quoted/1)

    Repo.query!(
      "insert into #{table} (#{cols}) select #{cols} from reader_import.#{table} " <>
        "on conflict do nothing",
      []
    )
  end

  # The rows carry their original ids, so each table's sequence has to be moved past them or the
  # next insert collides with a row that is already there.
  defp resequence do
    for table <- @owned ++ @shared do
      Repo.query!(
        "select setval(pg_get_serial_sequence($1, 'id'), coalesce((select max(id) from #{table}), 1))",
        [table]
      )
    end
  end

  # ── the small print ──────────────────────────────────────────────────

  defp columns(table) do
    %{rows: rows} =
      Repo.query!(
        "select column_name from information_schema.columns where table_schema = 'public' and table_name = $1 order by ordinal_position",
        [table]
      )

    for [c] <- rows, do: c
  end

  # "position" is a reserved word in Postgres and one of these tables uses it as a column.
  defp quoted(column), do: ~s("#{column}")

  defp with_map(sql) do
    "with map(reader, roki) as (select r::uuid, k::uuid from unnest($1::text[], $2::text[]) as t(r, k)) " <>
      sql
  end

  defp params(people), do: [Enum.map(people, & &1.reader_uuid), Enum.map(people, & &1.roki_uuid)]

  defp exec(sql, people), do: Repo.query!(with_map(sql), params(people), timeout: 300_000)

  defp counts(people) do
    for table <- @shared ++ @owned do
      sql =
        case table do
          t when t in @shared ->
            "select count(*) from #{t}"

          "manga_category_memberships" ->
            "select count(*) from manga_category_memberships cm join saved_manga s on s.id = cm.saved_manga_id join map m on m.roki = s.user_id"

          t ->
            "select count(*) from #{t} t join map m on m.roki = t.user_id"
        end

      %{rows: [[n]]} =
        if table in @shared,
          do: Repo.query!(sql, []),
          else: Repo.query!(with_map(sql), params(people))

      {table, n}
    end
  end
end
