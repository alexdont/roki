defmodule Roki.Repo.Migrations.CreateLaevDocuments do
  use Ecto.Migration

  # The laev terminal app's sync store (moved here from the blog): one opaque JSON document per
  # (sha256 of the key's server half, doc name), kept byte for byte.
  def change do
    create table(:laev_documents, primary_key: false) do
      add :token_hash, :text, null: false, primary_key: true
      add :doc, :text, null: false, primary_key: true
      add :body, :text, null: false
      add :etag, :text, null: false
      add :updated_at, :naive_datetime, null: false
    end
  end
end
