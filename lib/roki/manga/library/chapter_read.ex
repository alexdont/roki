defmodule Roki.Manga.Library.ChapterRead do
  @moduledoc """
  One row per counted chapter completion — the discrete event behind
  the aggregate chapters_read counters. Written by
  `Library.update_progress` at the moment a chapter crosses the
  counting bar, so "which chapter was read, at what time" is
  queryable directly (and joinable to stint sessions by time window).
  """
  use Ecto.Schema

  schema "chapter_reads" do
    field :user_id, Ecto.UUID
    field :source, :string
    field :slug, :string
    field :chapter, :string
    field :read_at, :utc_datetime_usec
    field :seconds, :integer, default: 0
    field :total_pages, :integer
  end
end
