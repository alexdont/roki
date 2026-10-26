defmodule Roki.Repo.Migrations.CreateProfiles do
  use Ecto.Migration

  # The public profile (see Roki.Profile): what a user shows of themselves — a few words, a
  # banner — and whether the page is open at all. Ratings are copied here from TMDB and
  # MyAnimeList so a profile can be read without the owner's keys.
  def change do
    create table(:roki_profiles, primary_key: false) do
      add :user_uuid, :uuid, primary_key: true
      add :bio, :text
      add :banner, :text
      add :public, :boolean, null: false, default: false
      add :show_history, :boolean, null: false, default: true
      add :show_ratings, :boolean, null: false, default: true
      add :ratings_synced_at, :utc_datetime
      timestamps(type: :utc_datetime)
    end

    create table(:roki_ratings, primary_key: false) do
      add :user_uuid, :uuid, null: false, primary_key: true
      # "movie" or "tv" with a TMDB id; "mal" with a MyAnimeList id.
      add :type, :text, null: false, primary_key: true
      add :id, :integer, null: false, primary_key: true
      add :score, :float, null: false
      add :rated_at, :utc_datetime
    end
  end
end
