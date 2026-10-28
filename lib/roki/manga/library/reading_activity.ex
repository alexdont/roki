defmodule Roki.Manga.Library.ReadingActivity do
  use Ecto.Schema
  import Ecto.Changeset

  schema "reading_activity" do
    field :user_id, Ecto.UUID
    field :date, :date
    field :source, :string
    field :slug, :string
    field :title, :string
    field :hour, :integer, default: 0
    field :reading_seconds, :integer, default: 0
    field :chapters_read, :integer, default: 0

    timestamps()
  end

  def changeset(activity, attrs) do
    activity
    |> cast(attrs, [
      :user_id,
      :date,
      :hour,
      :source,
      :slug,
      :title,
      :reading_seconds,
      :chapters_read
    ])
    |> validate_required([:user_id, :date, :source, :slug, :title])
    |> unique_constraint([:user_id, :date, :hour, :source, :slug])
  end
end
