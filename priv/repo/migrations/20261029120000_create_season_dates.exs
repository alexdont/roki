defmodule Roki.Repo.Migrations.CreateSeasonDates do
  use Ecto.Migration

  # When someone says they watched one season of a show, rather than the show.
  #
  # roki_watched holds one row per title — laev reports a season with each completion, but the
  # rows are collapsed to one per title and the season is only informational. Marking an old
  # season watched today therefore charged its whole runtime to today, and backdating the title
  # would have moved the seasons still being watched along with it.
  #
  # A table of its own rather than widening roki_watched: that table is rewritten wholesale
  # from laev on every sync, and these are answers laev does not have.
  def change do
    create table(:roki_season_dates, primary_key: false) do
      add :user_uuid, :uuid, null: false, primary_key: true
      # "tv" or "mal", with its id — the same key shape as everything else here.
      add :type, :text, null: false, primary_key: true
      add :id, :integer, null: false, primary_key: true
      add :season, :integer, null: false, primary_key: true
      add :at, :utc_datetime, null: false
      add :inserted_at, :utc_datetime, null: false
      add :updated_at, :utc_datetime, null: false
    end
  end
end
