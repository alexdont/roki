defmodule Roki.Manga.Library.MangaStoryData do
  @moduledoc """
  Locally saved fabledex story structure for a `{source, slug}`: the
  matched story, its arcs, volumes, and per-chapter units (titles, summaries,
  characters, page counts). Written by `Roki.Manga.Fabledex.sync/2`;
  the details pages render from this row and never call fabledex.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "manga_story_data" do
    field :source, :string
    field :slug, :string
    field :story_slug, :string
    field :story, :map, default: %{}
    field :arcs, {:array, :map}, default: []
    field :volumes, {:array, :map}, default: []
    field :units, {:array, :map}, default: []
    field :synced_at, :utc_datetime

    timestamps()
  end

  def changeset(row, attrs) do
    row
    |> cast(attrs, [:source, :slug, :story_slug, :story, :arcs, :volumes, :units, :synced_at])
    |> validate_required([:source, :slug, :synced_at])
    |> unique_constraint([:source, :slug])
  end
end
