defmodule Roki.Repo.Migrations.CreatePictures do
  use Ecto.Migration

  # Which PhoenixKit media file holds a picture the site fetched from elsewhere (Roki.Images):
  # the key is the picture's address without its scheme, e.g.
  # `image.tmdb.org/t/p/w342/abc.jpg`.
  def change do
    create table(:roki_pictures, primary_key: false) do
      add :key, :text, primary_key: true
      add :file_uuid, :uuid, null: false
      add :inserted_at, :utc_datetime, null: false
    end
  end
end
