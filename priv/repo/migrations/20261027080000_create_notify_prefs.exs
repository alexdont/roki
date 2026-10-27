defmodule Roki.Repo.Migrations.CreateNotifyPrefs do
  use Ecto.Migration

  # Which kinds of notification a person wants (`Roki.Notify`). A row only exists once someone
  # has chosen; until then each kind has its own default. And `roki_health`: what each person
  # was last told is wrong with a connection, so a problem is told when it starts (and again
  # when it gets worse), not at every check.
  def change do
    create table(:roki_notify_prefs, primary_key: false) do
      add :user_uuid, :uuid, null: false, primary_key: true
      add :key, :text, null: false, primary_key: true
      add :enabled, :boolean, null: false
    end

    create table(:roki_health, primary_key: false) do
      add :user_uuid, :uuid, null: false, primary_key: true
      add :service, :text, null: false, primary_key: true
      add :state, :text, null: false
      add :told_at, :utc_datetime, null: false, default: fragment("now()")
    end
  end
end
