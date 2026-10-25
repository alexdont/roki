defmodule Roki.Repo.Migrations.ActivitySeconds do
  use Ecto.Migration

  # How far into it someone is, on a "started" entry (seconds), kept up to date while they watch.
  def change do
    alter table(:roki_activity) do
      add :seconds, :integer
    end
  end
end
