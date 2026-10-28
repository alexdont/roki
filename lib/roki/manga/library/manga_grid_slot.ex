defmodule Roki.Manga.Library.MangaGridSlot do
  use Ecto.Schema

  schema "manga_grid_slots" do
    field :user_id, Ecto.UUID
    field :slot, :integer
    field :mode, :string, default: "overall"
    field :label, :string
    field :source, :string
    field :slug, :string

    timestamps()
  end
end
