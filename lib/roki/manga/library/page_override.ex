defmodule Roki.Manga.Library.PageOverride do
  @moduledoc """
  One row = one user's manual fix to a chapter's page list. See the
  migration `CreateChapterPageOverrides` for the rationale.

    * `kind = "insert_blank_before"` — splice a synthetic blank image
      just before `page_index` in the natural image list.
    * `kind = "solo"` — force the natural image at `page_index` to
      display alone (never paired in double-page mode).

  `page_index` is 1-based against the natural (un-overridden) image
  list as returned by the source module. Overrides are applied in
  `page_index` order so multiple inserts on the same chapter compose
  predictably.
  """

  use Ecto.Schema
  import Ecto.Changeset

  @kinds ~w(insert_blank_before solo)

  schema "chapter_page_overrides" do
    field :user_id, Ecto.UUID
    field :source, :string
    field :slug, :string
    field :chapter, :string
    field :page_index, :integer
    field :kind, :string

    timestamps()
  end

  def changeset(override, attrs) do
    override
    |> cast(attrs, [:user_id, :source, :slug, :chapter, :page_index, :kind])
    |> validate_required([:user_id, :source, :slug, :chapter, :page_index, :kind])
    |> validate_inclusion(:kind, @kinds)
    |> validate_number(:page_index, greater_than: 0)
    |> unique_constraint([:user_id, :source, :slug, :chapter, :page_index, :kind],
      name: :chapter_page_overrides_user_chapter_index_kind_index
    )
  end

  def kinds, do: @kinds
end
