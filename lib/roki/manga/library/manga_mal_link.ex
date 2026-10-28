defmodule Roki.Manga.Library.MangaMalLink do
  @moduledoc """
  A single user's MyAnimeList binding for a title: which MAL entry
  `{source, slug}` maps to, plus a cached copy of MAL's public
  metadata (`data`). Per-user — one user's link never affects
  another user's view, and progress sync (later) uses per-user
  tokens, so accounts stay fully isolated.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "manga_mal_links" do
    field :user_id, Ecto.UUID
    field :source, :string
    field :slug, :string
    field :mal_id, :integer
    field :data, :map, default: %{}

    timestamps()
  end

  def changeset(link, attrs) do
    link
    |> cast(attrs, [:user_id, :source, :slug, :mal_id, :data])
    |> validate_required([:user_id, :source, :slug, :mal_id])
    |> unique_constraint([:user_id, :source, :slug])
  end
end
