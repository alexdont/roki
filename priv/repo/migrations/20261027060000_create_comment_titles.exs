defmodule Roki.Repo.Migrations.CreateCommentTitles do
  use Ecto.Migration

  # A title's comment thread is filed under an id made from its kind and TMDB number
  # (`Roki.Social.title_uuid/2`), which cannot be turned back into either. This remembers which
  # title an id is, the first time its page is shown, so a notification or the moderation list
  # can name the title and link to it.
  def change do
    create table(:roki_comment_titles, primary_key: false) do
      add :uuid, :uuid, primary_key: true
      add :type, :text, null: false
      add :id, :integer, null: false
      add :name, :text
    end
  end
end
