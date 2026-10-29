defmodule Roki.Repo.Migrations.CreateMangaArcDates do
  use Ecto.Migration

  # When an arc (or a volume) of a series was read, where that is not
  # today and the site never saw it. On-site reading is already logged
  # day by day; this is for the hours entered by hand, which carry no
  # day at all — 421 of this account's 549 reading hours when the table
  # was added. A dated arc takes its share of them.
  #
  # Manga-side table, like every other row the reader owns: the key is
  # {source, slug}, not an id in roki's own tables.
  def change do
    create table(:manga_arc_dates, primary_key: false) do
      add :user_id, :uuid, null: false
      add :source, :string, null: false
      add :slug, :string, null: false
      # "arc" | "volume" — a series can be browsed either way and the
      # positions of the two collide.
      add :kind, :string, null: false
      add :position, :integer, null: false
      add :at, :naive_datetime, null: false

      timestamps()
    end

    create unique_index(:manga_arc_dates, [:user_id, :source, :slug, :kind, :position])
  end
end
