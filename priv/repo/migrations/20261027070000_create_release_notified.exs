defmodule Roki.Repo.Migrations.CreateReleaseNotified do
  use Ecto.Migration

  # What each person has already been told is out (`Roki.Releases`): one row per person and
  # episode or film release, so the same news is never sent twice however often the schedules are
  # read. `season` and `episode` are 0 for a film or an anime without a season number.
  def change do
    create table(:roki_release_notified, primary_key: false) do
      add :user_uuid, :uuid, null: false, primary_key: true
      add :type, :text, null: false, primary_key: true
      add :id, :integer, null: false, primary_key: true
      add :season, :integer, null: false, default: 0, primary_key: true
      add :episode, :integer, null: false, default: 0, primary_key: true
      add :kind, :text, null: false, primary_key: true
      add :told_at, :utc_datetime, null: false, default: fragment("now()")
    end
  end
end
