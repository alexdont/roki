defmodule Roki.Manga.Library.MangaMark do
  @moduledoc """
  Per-(user, source, slug, chapter) bag of reader overlay items.

  Each row owns an `items` jsonb array; each entry has a `type` field
  identifying what it is (`"annotation"`, `"drawing"`, `"marker"`, ...).
  Adding a new feature means defining a new `type`, no schema change.

  Concurrency: each user writes only to their own row, so reads
  inside the chapter for "show everyone's annotations" pull multiple
  rows (one per user) and concat their `items` in Elixir. Writes
  never collide.

  Annotation items reference a `phoenix_kit_comment` via `comment_uuid`
  in the item map — the comment itself stays in `phoenix_kit_comments`,
  so likes / replies / status reuse the existing comments machinery.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @valid_types ~w(annotation drawing marker highlight etcher_shape)
  @valid_visibilities ~w(public private)

  schema "manga_marks" do
    field :user_id, Ecto.UUID
    field :source, :string
    field :slug, :string
    field :chapter, :string
    field :items, {:array, :map}, default: []

    timestamps()
  end

  def changeset(mark, attrs) do
    mark
    |> cast(attrs, [:user_id, :source, :slug, :chapter, :items])
    |> validate_required([:user_id, :source, :slug, :chapter])
    |> validate_items()
    |> unique_constraint([:user_id, :source, :slug, :chapter])
  end

  # ── Item shape validation ────────────────────────────────────────
  # We keep items loosely shaped (it's the whole point of a jsonb
  # bag), but enforce the minimum invariants so reads can rely on
  # them: every item has a stable `id`, a recognized `type`, and a
  # visibility marker. Type-specific fields are not validated here —
  # that's the caller's job at item-build time.

  defp validate_items(changeset) do
    items = get_field(changeset, :items) || []

    case Enum.find(items, &invalid_item?/1) do
      nil -> changeset
      bad -> add_error(changeset, :items, "invalid item: #{inspect(bad)}")
    end
  end

  defp invalid_item?(item) when is_map(item) do
    not (is_binary(item["id"]) and
           item["type"] in @valid_types and
           item["visibility"] in @valid_visibilities)
  end

  defp invalid_item?(_), do: true

  def valid_types, do: @valid_types
  def valid_visibilities, do: @valid_visibilities
end
