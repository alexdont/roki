defmodule Roki.Manga.Library.MangaTrackerToken do
  @moduledoc """
  A user's OAuth tokens for an external tracker (MyAnimeList). One
  row per user per provider — connections are fully per-user, so a
  user's reading only ever syncs to their own list.
  """
  use Ecto.Schema
  import Ecto.Changeset

  schema "manga_tracker_tokens" do
    field :user_id, Ecto.UUID
    field :provider, :string
    field :access_token, :string
    field :refresh_token, :string
    field :expires_at, :utc_datetime_usec
    field :remote_username, :string

    timestamps()
  end

  def changeset(token, attrs) do
    token
    |> cast(attrs, [
      :user_id,
      :provider,
      :access_token,
      :refresh_token,
      :expires_at,
      :remote_username
    ])
    |> validate_required([:user_id, :provider, :access_token])
    |> unique_constraint([:user_id, :provider])
  end
end
