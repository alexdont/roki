defmodule Roki.Manga.Library.MangaAnnotation do
  use Ecto.Schema
  import Ecto.Changeset

  schema "manga_annotations" do
    field :comment_uuid, Ecto.UUID
    field :user_id, Ecto.UUID
    field :source, :string
    field :slug, :string
    field :chapter, :string
    field :page, :integer
    field :title, :string
    field :x_pct, :float
    field :y_pct, :float
    field :w_pct, :float
    field :h_pct, :float
    field :color, :string, default: "blue"
    field :visibility, :string, default: "public"

    timestamps()
  end

  def changeset(annotation, attrs) do
    annotation
    |> cast(attrs, [:comment_uuid, :user_id, :source, :slug, :chapter, :page, :title, :x_pct, :y_pct, :w_pct, :h_pct, :color, :visibility])
    |> validate_required([:comment_uuid, :user_id, :source, :slug, :chapter, :page, :title, :x_pct, :y_pct, :w_pct, :h_pct])
    |> validate_inclusion(:color, ~w(blue pink green purple))
    |> validate_inclusion(:visibility, ~w(public private))
    |> validate_number(:page, greater_than: 0)
    |> validate_number(:x_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:y_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:w_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
    |> validate_number(:h_pct, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end
end
