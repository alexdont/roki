defmodule Roki.Manga.Library.MangaMetadata do
  use Ecto.Schema
  import Ecto.Changeset

  schema "manga_metadata" do
    field :source, :string
    field :slug, :string
    field :cover_file_uuid, :binary_id
    field :data, :map, default: %{}

    timestamps()
  end

  def changeset(metadata, attrs) do
    metadata
    |> cast(attrs, [:source, :slug, :cover_file_uuid, :data])
    |> validate_required([:source, :slug])
    |> validate_data_title()
    |> unique_constraint([:source, :slug])
  end

  defp validate_data_title(changeset) do
    case get_field(changeset, :data) do
      %{"title" => title} when is_binary(title) and title != "" -> changeset
      _ -> add_error(changeset, :data, "must include a title")
    end
  end
end
