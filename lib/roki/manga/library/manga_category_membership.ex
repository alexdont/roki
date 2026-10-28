defmodule Roki.Manga.Library.MangaCategoryMembership do
  use Ecto.Schema
  import Ecto.Changeset

  schema "manga_category_memberships" do
    belongs_to :saved_manga, Roki.Manga.Library.SavedManga
    belongs_to :category, Roki.Manga.Library.MangaCategory

    timestamps()
  end

  def changeset(membership, attrs) do
    membership
    |> cast(attrs, [:saved_manga_id, :category_id])
    |> validate_required([:saved_manga_id, :category_id])
    |> unique_constraint([:saved_manga_id, :category_id])
  end
end
