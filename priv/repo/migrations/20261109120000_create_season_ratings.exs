defmodule Roki.Repo.Migrations.CreateSeasonRatings do
  use Ecto.Migration

  # What a person gave one season of a show. TMDB rates a show as a whole, so these live on Roki
  # alone (never sent anywhere). A season without a row of its own reads as the show's rating
  # (`Roki.Profile.season_rating/3`) — nothing is copied, so the show's rating changing carries
  # every season that was never rated apart.
  def change do
    create table(:roki_season_ratings, primary_key: false) do
      add :user_uuid, :uuid, null: false, primary_key: true
      add :tmdb_id, :integer, null: false, primary_key: true
      add :season, :integer, null: false, primary_key: true
      add :score, :float, null: false
      add :rated_at, :utc_datetime, null: false, default: fragment("now()")
    end
  end
end
