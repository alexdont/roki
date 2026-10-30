defmodule Roki.Repo.Migrations.CreateLinkRounds do
  use Ecto.Migration

  # A "round" is the rating moment when a linked group finishes a season (or the whole series):
  # each member gives a score, and the scores are shown once everyone has (or someone asks).
  # The scores live here; they are not written to anyone's TMDB account unless that person says so.
  def change do
    create table(:roki_link_rounds, primary_key: false) do
      add :id, :uuid, primary_key: true, default: fragment("gen_random_uuid()")
      add :link_id, references(:roki_links, type: :uuid, on_delete: :delete_all), null: false
      # nil: the whole series
      add :season, :integer
      add :revealed, :boolean, null: false, default: false
      timestamps()
    end

    create unique_index(:roki_link_rounds, [:link_id, "coalesce(season, -1)"],
             name: :roki_link_rounds_link_season_index
           )

    create table(:roki_link_scores, primary_key: false) do
      add :round_id, references(:roki_link_rounds, type: :uuid, on_delete: :delete_all),
        null: false

      add :user_uuid, :uuid, null: false
      # nil with skipped: true — "I'd rather not say"
      add :score, :float
      add :skipped, :boolean, null: false, default: false
      timestamps()
    end

    create unique_index(:roki_link_scores, [:round_id, :user_uuid])
  end
end
