defmodule Roki.Repo.Migrations.CreateRecommendations do
  use Ecto.Migration

  # A person vouching for a film or a show: "Recommended by users" on the home page. One row per
  # person and title; the title's name, year and poster are kept with it so the row draws with no
  # lookup.
  def change do
    create table(:roki_recommendations, primary_key: false) do
      add :user_uuid, :uuid, null: false, primary_key: true
      add :type, :text, null: false, primary_key: true
      add :id, :integer, null: false, primary_key: true
      add :title, :text
      add :year, :text
      add :poster, :text
      add :recommended_at, :utc_datetime, null: false, default: fragment("now()")
    end

    create index(:roki_recommendations, [:recommended_at])
  end
end
