defmodule Roki.Repo.Migrations.CreateKept do
  use Ecto.Migration

  # Answers kept from TMDB beside the titles (Roki.Kept): a season's episodes, a title's
  # recommendations, a film collection — one row per answer, as JSON.
  def change do
    create table(:roki_kept, primary_key: false) do
      add :kind, :text, null: false, primary_key: true
      add :key, :text, null: false, primary_key: true
      add :data, :map, null: false
      # Nothing left to change (a season whose episodes have all aired): never read again.
      add :final, :boolean, null: false, default: false
      add :fetched_at, :utc_datetime, null: false
    end
  end
end
