defmodule Roki.Repo.Migrations.WatchedStatus do
  use Ecto.Migration

  # The history is everything watched, not only what was finished: a show started and left, a show
  # caught up on while it is still airing, a show put on hold. `status` says which ("finished",
  # "progress", "up_to_date", "on_hold"); `note` is laev's progress line ("2/5 seasons").
  def change do
    alter table(:roki_watched) do
      add :status, :text, null: false, default: "finished"
      add :note, :text
    end
  end
end
