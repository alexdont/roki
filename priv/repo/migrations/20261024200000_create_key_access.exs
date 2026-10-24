defmodule Roki.Repo.Migrations.CreateKeyAccess do
  use Ecto.Migration

  # Lending the owner's API keys to chosen accounts: who may use them, what is shared, and a
  # per-day count of what each account did with them (see Roki.Keys).
  def change do
    create table(:roki_key_grants, primary_key: false) do
      add :user_uuid, :uuid, primary_key: true
      add :granted_at, :utc_datetime, null: false
      add :daily_plays, :integer
      add :note, :text
    end

    create table(:roki_key_usage, primary_key: false) do
      add :user_uuid, :uuid, null: false, primary_key: true
      add :day, :date, null: false, primary_key: true
      add :kind, :text, null: false, primary_key: true
      add :count, :integer, null: false, default: 0
    end

    create index(:roki_key_usage, [:day])

    create table(:roki_key_settings, primary_key: false) do
      add :id, :integer, primary_key: true
      add :owner_uuid, :uuid
      add :shared, {:array, :text}, null: false, default: []
    end
  end
end
