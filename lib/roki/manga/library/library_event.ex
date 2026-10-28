defmodule Roki.Manga.Library.LibraryEvent do
  @moduledoc """
  One row per library milestone — the discrete event behind status
  changes that the aggregate columns only store as current state.
  Written by `Library` at the moment the transition happens, so
  "when did I finish this / catch up on this, and at which chapter"
  is queryable directly.

  Events:

    * `"completed"` — the user marked the series complete;
      `chapter` is the chapter it was completed at (when known).
    * `"caught_up"` — the reading position crossed the latest known
      chapter (the home page's caught-up category); `chapter` is the
      chapter that crossed the threshold.
    * `"started"` — the first reading tick ever recorded on the
      title; `chapter` is where reading began. Logged once per saved
      row (re-saving after an unsave can log it again).
  """
  use Ecto.Schema

  schema "library_events" do
    field :user_id, Ecto.UUID
    field :source, :string
    field :slug, :string
    field :event, :string
    field :chapter, :string
    field :happened_at, :utc_datetime_usec
  end
end
