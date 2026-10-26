defmodule Roki.Repo.Migrations.CreateWatchDates do
  use Ecto.Migration

  # When the owner says something was watched (Roki.Profile.set_watched_at/3): a film found years
  # later and marked finished is stamped today by laev, and this puts it back where it belongs in
  # the history. Kept apart from `roki_watched`, which is rebuilt from laev's marks on every sync.
  def change do
    create table(:roki_watch_dates, primary_key: false) do
      add :user_uuid, :uuid, null: false, primary_key: true
      # "movie" or "tv" with a TMDB id; "mal" with a MyAnimeList id (as in roki_watched).
      add :type, :text, null: false, primary_key: true
      add :id, :integer, null: false, primary_key: true
      add :watched_at, :utc_datetime, null: false
    end
  end
end
