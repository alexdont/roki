defmodule Roki.Repo.Migrations.CreateTvSeasons do
  use Ecto.Migration

  # What TMDB says about a show's seasons — when each began and its own poster — kept so a poster can
  # be the season's and not the show's (`Roki.SeasonPosters`). `roki_tv_seasons_read` says when a show
  # was read, so a show with no season posters is not asked about again and again.
  def change do
    create table(:roki_tv_seasons, primary_key: false) do
      add :tv_id, :integer, null: false, primary_key: true
      add :season, :integer, null: false, primary_key: true
      add :air_date, :date
      add :poster_path, :text
    end

    create table(:roki_tv_seasons_read, primary_key: false) do
      add :tv_id, :integer, null: false, primary_key: true
      add :read_at, :naive_datetime, null: false
    end
  end
end
