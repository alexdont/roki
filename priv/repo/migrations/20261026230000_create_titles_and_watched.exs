defmodule Roki.Repo.Migrations.CreateTitlesAndWatched do
  use Ecto.Migration

  # The site's own copy of what TMDB says about a title (Roki.Titles), so a page can be drawn
  # without asking again; and each user's finished titles (Roki.Profile), so a profile reads
  # a table rather than laev's files.
  def change do
    create table(:roki_titles, primary_key: false) do
      add :type, :text, null: false, primary_key: true
      add :id, :integer, null: false, primary_key: true
      # The card: what a list row needs.
      add :name, :text
      add :year, :text
      add :poster_path, :text
      add :overview, :text
      # The whole title as the title page shows it, once one read it; nil for a card alone.
      add :data, :map
      # A film out, a show ended: nothing left to change, never read again.
      add :final, :boolean, null: false, default: false
      add :fetched_at, :utc_datetime
      add :seen_at, :utc_datetime, null: false
    end

    create table(:roki_watched, primary_key: false) do
      add :user_uuid, :uuid, null: false
      # "movie" or "tv" with a TMDB id; "mal" with a MyAnimeList id.
      add :type, :text, null: false
      add :id, :integer, null: false
      # For a MyAnimeList entry, the TMDB title it maps to (nil when none is known).
      add :tmdb_type, :text
      add :tmdb_id, :integer
      add :season, :integer
      add :title, :text
      add :anime, :boolean, null: false, default: false
      add :at, :utc_datetime, null: false
      # Whether `at` is when it was watched, or only when the mark was made (an import).
      add :dated, :boolean, null: false, default: true
    end

    create unique_index(:roki_watched, [:user_uuid, :type, :id])
    create index(:roki_watched, [:user_uuid, :at])
  end
end
