defmodule Roki.Repo.Migrations.RatingsInOrder do
  use Ecto.Migration

  # TMDB hands a rated list back in the order the ratings were made, with no dates; `seq` keeps
  # that order (per type), so "the last films rated 8" can be answered. A rating made on the
  # site goes after the rest. MyAnimeList's carry a date (`rated_at`).
  def change do
    alter table(:roki_ratings) do
      add :seq, :integer
    end
  end
end
