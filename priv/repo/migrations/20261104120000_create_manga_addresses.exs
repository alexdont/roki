defmodule Roki.Repo.Migrations.CreateMangaAddresses do
  use Ecto.Migration

  # The clean addresses of manga pages: `/manga/nozoki-ana` names a title; each row says which
  # source entry the name stands for. One title can be on several sources under the same name.
  def change do
    create table(:manga_addresses) do
      add :name, :string, null: false
      add :source, :string, null: false
      add :slug, :text, null: false
      add :title, :text
      timestamps(type: :utc_datetime)
    end

    create unique_index(:manga_addresses, [:source, :slug])
    create index(:manga_addresses, [:name])
  end
end
