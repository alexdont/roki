defmodule Roki.Repo.Migrations.CreateActivity do
  use Ecto.Migration

  # Who finished what, newest first: the strip of recent activity on the Featured page
  # (see Roki.Activity). One row per episode or film finished.
  def change do
    create table(:roki_activity) do
      add :user_uuid, :uuid, null: false
      add :type, :text, null: false
      add :tmdb_id, :integer, null: false
      add :season, :integer
      add :episode, :integer
      add :title, :text, null: false
      add :poster, :text
      add :at, :utc_datetime, null: false
    end

    create index(:roki_activity, [:at])
    create index(:roki_activity, [:user_uuid, :tmdb_id, :at])
  end
end
