defmodule Roki.Repo.Migrations.CreateMangaTables do
  @moduledoc """
  The manga reader's tables, as `dev_docs/manga-migration-plan.md` sets them out.

  The columns are the reader's own, name for name, because its store reads and writes them and
  the semantics are not ours to reinvent — `visiting_chapter`, `prev_chapter_near_end` and the
  rest encode how reading is actually counted over there.

  Two deliberate differences. A series is `(source, slug)` in the reader and an **integer id**
  here: `roki_manga_titles` holds one row per series — the shape `roki_titles` already has for
  TMDB — so a manga can sit in `roki_favorites`, `roki_watched`, `roki_ratings` and
  `roki_activity`, which all key on `(type, id)` with an integer id, without widening any of
  them. And the owner column is `user_uuid`, as everywhere else here, not `user_id`.
  """
  use Ecto.Migration

  def change do
    # ── the series itself: shared, one row per (source, slug) ──────────
    create table(:roki_manga_titles) do
      add :source, :string, null: false
      add :slug, :string, null: false
      add :title, :string
      add :cover_url, :string
      add :cover_file_uuid, :uuid
      add :mal_id, :integer
      # Whatever the source said about it: synopsis, genres, chapter list.
      add :data, :map, null: false, default: %{}
      timestamps()
    end

    create unique_index(:roki_manga_titles, [:source, :slug])
    create index(:roki_manga_titles, [:mal_id])

    # Fabledex's arcs, volumes and per-chapter units for a series.
    create table(:roki_manga_arcs) do
      add :manga_id, references(:roki_manga_titles, on_delete: :delete_all), null: false
      add :story_slug, :string
      add :story, :map, null: false, default: %{}
      add :arcs, {:array, :map}, null: false, default: []
      add :units, {:array, :map}, null: false, default: []
      add :volumes, {:array, :map}, null: false, default: []
      add :synced_at, :naive_datetime, null: false
      timestamps()
    end

    create unique_index(:roki_manga_arcs, [:manga_id])

    # ── one person's shelf ─────────────────────────────────────────────
    create table(:roki_manga_categories) do
      add :user_uuid, :uuid, null: false
      add :name, :string, null: false
      add :position, :integer, null: false, default: 0
      timestamps()
    end

    create index(:roki_manga_categories, [:user_uuid])
    create unique_index(:roki_manga_categories, [:user_uuid, :name])

    # The library row: progress, the per-device reading settings, and the second-by-second
    # counters the reader keeps. `title` and `cover_url` are the reader's custom-title and
    # custom-cover overrides, not a copy of the series' own.
    create table(:roki_manga_library) do
      add :user_uuid, :uuid, null: false
      add :manga_id, references(:roki_manga_titles, on_delete: :delete_all), null: false
      add :title, :string
      add :cover_url, :string
      add :cover_file_uuid, :uuid
      add :category_id, references(:roki_manga_categories, on_delete: :nilify_all)

      add :reading_mode, :string, null: false, default: "scroll"
      add :reading_mode_desktop, :string
      add :reading_mode_mobile, :string
      add :reading_direction, :string, default: "rtl"
      add :reading_rotation, :integer, null: false, default: 0
      add :smart_crop, :boolean, default: false
      add :comments_visible, :boolean, null: false, default: false
      add :tap_zone_preset, :string, null: false, default: "default"
      add :tap_zone_preset_desktop, :string
      add :tap_zone_preset_mobile, :string

      add :last_chapter, :string
      add :last_chapter_number, :integer
      add :last_chapter_total_pages, :integer
      add :last_page, :integer
      add :last_page_fraction, :float, null: false, default: 0.0
      add :max_chapter, :string
      add :total_chapters, :integer
      add :completed, :boolean, null: false, default: false
      add :newest_chapter_at, :naive_datetime

      # How long has been spent reading, and where the reader had got to when it last looked.
      add :reading_seconds, :integer, null: false, default: 0
      add :reading_seconds_adjusted, :integer
      add :reading_seconds_offsite, :integer
      add :reading_seconds_offsite_approximate, :boolean, null: false, default: false
      add :chapter_seconds, :integer, null: false, default: 0
      add :visiting_chapter, :string
      add :visiting_seconds, :integer, default: 0
      add :chapter_near_end, :boolean, default: false
      add :prev_chapter, :string
      add :prev_chapter_seconds, :integer, default: 0
      add :prev_chapter_near_end, :boolean, default: false

      timestamps()
    end

    create index(:roki_manga_library, [:user_uuid])
    create index(:roki_manga_library, [:category_id])
    create unique_index(:roki_manga_library, [:user_uuid, :manga_id])

    create table(:roki_manga_category_members) do
      add :library_id, references(:roki_manga_library, on_delete: :delete_all), null: false
      add :category_id, references(:roki_manga_categories, on_delete: :delete_all), null: false
      timestamps()
    end

    create index(:roki_manga_category_members, [:category_id])
    create unique_index(:roki_manga_category_members, [:library_id, :category_id])

    # ── what was read, and when ────────────────────────────────────────
    # One row per chapter counted as read: the event log the aggregates are built from.
    create table(:roki_manga_reads) do
      add :user_uuid, :uuid, null: false
      add :manga_id, references(:roki_manga_titles, on_delete: :delete_all), null: false
      add :chapter, :string, null: false
      add :read_at, :naive_datetime, null: false
      add :seconds, :integer, null: false, default: 0
      add :total_pages, :integer
    end

    create index(:roki_manga_reads, [:user_uuid, :read_at])
    create index(:roki_manga_reads, [:user_uuid, :manga_id])

    # Reading time and chapters, rolled up by day and hour.
    create table(:roki_manga_reading) do
      add :user_uuid, :uuid, null: false
      add :manga_id, references(:roki_manga_titles, on_delete: :delete_all)
      add :title, :string
      add :date, :date, null: false
      add :hour, :integer, null: false, default: 0
      add :reading_seconds, :integer, null: false, default: 0
      add :chapters_read, :integer, null: false, default: 0
      timestamps()
    end

    create unique_index(:roki_manga_reading, [:user_uuid, :date, :hour, :manga_id])

    # Started / caught up / completed.
    create table(:roki_manga_events) do
      add :user_uuid, :uuid, null: false
      add :manga_id, references(:roki_manga_titles, on_delete: :delete_all), null: false
      add :event, :string, null: false
      add :chapter, :string
      add :happened_at, :naive_datetime, null: false
    end

    create index(:roki_manga_events, [:user_uuid, :happened_at])
    create index(:roki_manga_events, [:user_uuid, :manga_id])

    # ── what was drawn and written on the page ─────────────────────────
    # The current system: one row per (person, series, chapter) holding every mark as jsonb.
    create table(:roki_manga_marks) do
      add :user_uuid, :uuid, null: false
      add :manga_id, references(:roki_manga_titles, on_delete: :delete_all), null: false
      add :chapter, :string, null: false
      add :items, {:array, :map}, null: false, default: []
      timestamps()
    end

    create index(:roki_manga_marks, [:manga_id, :chapter])
    create unique_index(:roki_manga_marks, [:user_uuid, :manga_id, :chapter])

    # The older one, kept because people's notes are in it: a rectangle on a page whose words
    # live in a PhoenixKit comment.
    create table(:roki_manga_annotations) do
      add :user_uuid, :uuid, null: false
      add :comment_uuid, :uuid, null: false
      add :manga_id, references(:roki_manga_titles, on_delete: :delete_all), null: false
      add :chapter, :string, null: false
      add :page, :integer, null: false
      add :title, :string, null: false
      add :x_pct, :float, null: false
      add :y_pct, :float, null: false
      add :w_pct, :float, null: false
      add :h_pct, :float, null: false
      add :color, :string, null: false, default: "blue"
      add :visibility, :string, null: false, default: "public"
      timestamps()
    end

    create index(:roki_manga_annotations, [:comment_uuid])
    create index(:roki_manga_annotations, [:manga_id, :chapter])

    create constraint(:roki_manga_annotations, :visibility_must_be_valid,
             check: "visibility in ('public', 'private')"
           )

    # A hand-fixed double-page spread: a blank inserted before a page, or a page left alone.
    create table(:roki_manga_page_overrides) do
      add :user_uuid, :uuid, null: false
      add :manga_id, references(:roki_manga_titles, on_delete: :delete_all), null: false
      add :chapter, :string, null: false
      add :page_index, :integer, null: false
      add :kind, :string, null: false
      timestamps()
    end

    create index(:roki_manga_page_overrides, [:user_uuid, :manga_id, :chapter])

    create unique_index(
             :roki_manga_page_overrides,
             [:user_uuid, :manga_id, :chapter, :page_index, :kind],
             name: :roki_manga_page_overrides_user_chapter_page_kind_index
           )

    # ── ranking and linking ────────────────────────────────────────────
    create table(:roki_manga_tiers) do
      add :user_uuid, :uuid, null: false
      add :manga_id, references(:roki_manga_titles, on_delete: :delete_all), null: false
      add :tier, :string, null: false
      add :position, :integer, null: false, default: 0
      timestamps()
    end

    create unique_index(:roki_manga_tiers, [:user_uuid, :manga_id])
    create index(:roki_manga_tiers, [:user_uuid, :tier, :position])

    # The owner's top-N grid: a slot may be empty, so the series is optional.
    create table(:roki_manga_grid) do
      add :user_uuid, :uuid, null: false
      add :mode, :string, null: false, default: "overall"
      add :slot, :integer, null: false
      add :label, :string, null: false
      add :manga_id, references(:roki_manga_titles, on_delete: :nilify_all)
      timestamps()
    end

    create unique_index(:roki_manga_grid, [:user_uuid, :mode, :slot])

    # Which MyAnimeList entry a series is, per person — MAL cannot tell us which scraper slug is
    # which of its ids, so the mapping is ours to keep.
    create table(:roki_manga_mal) do
      add :user_uuid, :uuid, null: false
      add :manga_id, references(:roki_manga_titles, on_delete: :delete_all), null: false
      add :mal_id, :integer, null: false
      add :data, :map, null: false, default: %{}
      timestamps()
    end

    create index(:roki_manga_mal, [:user_uuid])
    create unique_index(:roki_manga_mal, [:user_uuid, :manga_id])
  end
end
