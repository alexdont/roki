defmodule Roki.Manga.Library.MangaCategory do
  use Ecto.Schema
  import Ecto.Changeset

  schema "manga_categories" do
    field :user_id, Ecto.UUID
    field :name, :string
    field :position, :integer, default: 0

    timestamps()
  end

  def changeset(category, attrs) do
    category
    |> cast(attrs, [:user_id, :name, :position])
    |> validate_required([:user_id, :name])
    |> validate_length(:name, min: 1, max: 50)
    |> unique_constraint([:user_id, :name])
  end
end
