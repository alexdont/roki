defmodule Roki.Repo.Migrations.ProfileRankedShelves do
  use Ecto.Migration

  # Which of a user's shelves show their places as numbers, 1 to 10 (Roki.Profile). A shelf is
  # an unranked ten favourites until its owner turns the numbers on.
  def change do
    alter table(:roki_profiles) do
      add :ranked, {:array, :text}, null: false, default: []
    end
  end
end
