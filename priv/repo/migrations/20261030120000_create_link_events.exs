defmodule Roki.Repo.Migrations.CreateLinkEvents do
  use Ecto.Migration

  # One row per episode watched together through a link (Roki.Link.mirror): who was in on it and
  # how long it ran. It is what the "time together" stat adds up. An episode counts once per link
  # however often it is marked again.
  def change do
    create table(:roki_link_events, primary_key: false) do
      add :link_id, references(:roki_links, type: :uuid, on_delete: :delete_all), null: false
      add :tmdb_id, :bigint, null: false
      add :season, :integer, null: false
      add :episode, :integer, null: false
      add :minutes, :integer, null: false
      # Everyone the episode was marked for, the person who marked it included.
      add :participants, {:array, :uuid}, null: false
      timestamps(updated_at: false)
    end

    create unique_index(:roki_link_events, [:link_id, :season, :episode])
    create index(:roki_link_events, [:tmdb_id])
    execute "create index roki_link_events_participants_index on roki_link_events using gin (participants)",
            "drop index roki_link_events_participants_index"
  end
end
