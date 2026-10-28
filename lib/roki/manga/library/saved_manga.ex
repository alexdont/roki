defmodule Roki.Manga.Library.SavedManga do
  use Ecto.Schema
  import Ecto.Changeset

  @reading_modes ["scroll", "paged", "double_page"]

  schema "saved_manga" do
    field :user_id, Ecto.UUID
    field :source, :string, default: "mangafreak"
    field :slug, :string
    field :title, :string
    field :cover_url, :string
    field :reading_mode, :string, default: "scroll"
    field :reading_mode_desktop, :string
    field :reading_mode_mobile, :string
    field :last_chapter, :string
    field :last_page, :integer
    field :last_page_fraction, :float, default: 0.0
    field :last_chapter_total_pages, :integer
    field :reading_rotation, :integer, default: 0
    field :max_chapter, :string
    field :visiting_chapter, :string
    field :visiting_seconds, :integer, default: 0
    field :reading_seconds, :integer, default: 0
    field :reading_seconds_adjusted, :integer
    field :reading_seconds_offsite, :integer
    field :reading_seconds_offsite_approximate, :boolean, default: false
    field :comments_visible, :boolean, default: false
    field :reading_direction, :string, default: "rtl"
    field :tap_zone_preset, :string, default: "default"
    field :tap_zone_preset_desktop, :string
    field :tap_zone_preset_mobile, :string
    field :total_chapters, :integer
    field :last_chapter_number, :integer
    field :category_id, :integer
    field :chapter_seconds, :integer, default: 0
    field :chapter_near_end, :boolean, default: false
    field :prev_chapter, :string
    field :prev_chapter_seconds, :integer, default: 0
    field :prev_chapter_near_end, :boolean, default: false
    field :smart_crop, :boolean, default: false
    field :cover_file_uuid, Ecto.UUID
    field :completed, :boolean, default: false
    field :newest_chapter_at, :utc_datetime

    # Not persisted — the linked MyAnimeList media type ("manga",
    # "manhwa", "manhua", …), populated by list_saved_manga so the
    # manga/manhwa categorization can prefer MAL's authoritative type.
    field :mal_media_type, :string, virtual: true

    timestamps()
  end

  def changeset(saved_manga, attrs) do
    saved_manga
    |> cast(attrs, [:user_id, :source, :slug, :title, :cover_url, :reading_mode, :reading_mode_desktop, :reading_mode_mobile, :reading_direction, :last_chapter, :last_page, :last_page_fraction, :last_chapter_total_pages, :total_chapters, :last_chapter_number, :category_id, :tap_zone_preset, :tap_zone_preset_desktop, :tap_zone_preset_mobile, :completed, :newest_chapter_at])
    |> validate_required([:user_id, :source, :slug, :title, :cover_url, :reading_mode])
    |> validate_inclusion(:reading_mode, @reading_modes)
    |> validate_inclusion(:reading_mode_desktop, @reading_modes ++ [nil])
    |> validate_inclusion(:reading_mode_mobile, @reading_modes ++ [nil])
    |> unique_constraint([:user_id, :source, :slug])
  end
end
