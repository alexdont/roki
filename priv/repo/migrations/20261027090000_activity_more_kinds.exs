defmodule Roki.Repo.Migrations.ActivityMoreKinds do
  use Ecto.Migration

  # The activity feed is about more than finishing: saving a title for later, rating it, and
  # saying afterwards when it was really watched. `watched_on` is that date (a "backdated" entry:
  # the person marked it and then put it on an earlier day, which is not "just watched it");
  # `score` is a rating.
  def change do
    alter table(:roki_activity) do
      add :watched_on, :date
      add :score, :float
    end

    create index(:roki_activity, [:user_uuid, :at])
  end
end
