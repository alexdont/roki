defmodule Roki.Manga.Library.MangaTierlist do
  use Ecto.Schema

  schema "manga_tierlist" do
    field :user_id, Ecto.UUID
    field :source, :string
    field :slug, :string
    field :tier, :string
    field :position, :integer, default: 0

    timestamps()
  end
end
