defmodule Roki.Repo.Migrations.ActivityKind do
  use Ecto.Migration

  # An entry is either a start ("started …": opened it and began playing) or a finish.
  def change do
    alter table(:roki_activity) do
      add :kind, :text, null: false, default: "finished"
    end
  end
end
