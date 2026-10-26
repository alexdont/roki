defmodule Roki.Repo.Migrations.CreateFavorites do
  use Ecto.Migration

  # A user's top ten of each kind (films, shows, anime, manga), picked from what they watched
  # (Roki.Profile): one row per place.
  def change do
    create table(:roki_favorites, primary_key: false) do
      add :user_uuid, :uuid, null: false, primary_key: true
      add :kind, :text, null: false, primary_key: true
      add :position, :integer, null: false, primary_key: true
      # "movie" or "tv" with a TMDB id; "mal" with a MyAnimeList id.
      add :type, :text, null: false
      add :id, :integer, null: false
      add :title, :text
      add :inserted_at, :utc_datetime, null: false
    end

    create unique_index(:roki_favorites, [:user_uuid, :type, :id])
  end
end
