defmodule Roki.Repo.Migrations.CreateLinks do
  use Ecto.Migration

  # Linked progress: a group of friends whose marks on one show are kept the same
  # (Roki.Link). A link belongs to a show; the people in it are rows of their own, so a group
  # is any size and someone can join or leave without ending it for the rest.
  def change do
    create table(:roki_links, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :type, :string, null: false, default: "tv"
      add :tmdb_id, :bigint, null: false
      add :created_by, :uuid, null: false
      # A link begun with "start over": what its members had watched before is not carried in.
      add :fresh, :boolean, null: false, default: false
      add :status, :string, null: false, default: "active"
      timestamps()
    end

    create index(:roki_links, [:type, :tmdb_id])

    create table(:roki_link_members, primary_key: false) do
      add :link_id, references(:roki_links, type: :uuid, on_delete: :delete_all), null: false
      add :user_uuid, :uuid, null: false
      # invited | active | declined | left
      add :status, :string, null: false, default: "invited"
      # While paused, a member neither sends marks to the others nor takes theirs.
      add :paused, :boolean, null: false, default: false
      add :invited_by, :uuid
      add :joined_at, :naive_datetime
      timestamps()
    end

    create unique_index(:roki_link_members, [:link_id, :user_uuid])
    create index(:roki_link_members, [:user_uuid, :status])

    # Marks taken off a member when they chose someone else's progress as the right one, kept
    # so that the choice can be undone.
    create table(:roki_link_snapshots, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :link_id, references(:roki_links, type: :uuid, on_delete: :delete_all), null: false
      add :user_uuid, :uuid, null: false
      add :removed, :map, null: false
      add :restored, :boolean, null: false, default: false
      timestamps()
    end

    create index(:roki_link_snapshots, [:link_id, :user_uuid])
  end
end
