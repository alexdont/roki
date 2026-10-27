defmodule Roki.Repo.Migrations.TitleGenres do
  use Ecto.Migration

  # TMDB's genre ids of a title, kept once read (`Roki.Genres`): what the watched page and the
  # search filter by. NULL is "not read yet"; an empty array is "TMDB lists none".
  def change do
    alter table(:roki_titles) do
      add :genres, {:array, :integer}
    end
  end
end
