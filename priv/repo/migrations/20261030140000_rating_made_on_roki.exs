defmodule Roki.Repo.Migrations.RatingMadeOnRoki do
  use Ecto.Migration

  # A rating made on Roki by someone with no TMDB account to send it to lives only here. The rows
  # the site copies from TMDB and MyAnimeList are rewritten on every refresh; these are not.
  def change do
    alter table(:roki_ratings) do
      add :local, :boolean, null: false, default: false
    end
  end
end
