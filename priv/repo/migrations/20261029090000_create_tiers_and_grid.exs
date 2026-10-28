defmodule Roki.Repo.Migrations.CreateTiersAndGrid do
  use Ecto.Migration

  # The tierlist and the grid, for the things this site knows about: films, shows and anime.
  #
  # Manga keeps its own two tables (`manga_tierlist`, `manga_grid_slots`), which came from the
  # reader with the rest of it and which the MyAnimeList sync writes through. The page draws
  # both together; the storage stays apart, so neither side has to learn the other's keys.
  def change do
    create table(:roki_tiers, primary_key: false) do
      add :user_uuid, :uuid, null: false, primary_key: true
      # "movie" or "tv" with a TMDB id; "mal" with a MyAnimeList id, as everywhere else here.
      add :type, :text, null: false, primary_key: true
      add :id, :integer, null: false, primary_key: true
      add :tier, :text, null: false
      add :position, :integer, null: false, default: 0
      add :title, :text
      add :inserted_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end

    create index(:roki_tiers, [:user_uuid, :tier])

    create table(:roki_grid_slots, primary_key: false) do
      add :user_uuid, :uuid, null: false, primary_key: true
      # Which board: "overall", "movie", "tv", "anime".
      add :mode, :text, null: false, primary_key: true
      add :slot, :integer, null: false, primary_key: true
      add :label, :text
      add :type, :text
      add :id, :integer
      add :inserted_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end
  end
end
