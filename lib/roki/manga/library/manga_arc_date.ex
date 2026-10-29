defmodule Roki.Manga.Library.MangaArcDate do
  @moduledoc """
  When one arc (or volume) of a series was read, as this account says.

  Written by `Roki.Manga.ArcDates`, which is also where the arithmetic
  that uses it lives.
  """
  use Ecto.Schema

  @primary_key false
  schema "manga_arc_dates" do
    field :user_id, Ecto.UUID
    field :source, :string
    field :slug, :string
    field :kind, :string
    field :position, :integer
    field :at, :naive_datetime

    timestamps()
  end
end
