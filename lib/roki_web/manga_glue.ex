defmodule RokiWeb.MangaGlue do
  @moduledoc """
  The few things the packaged reader asks the surrounding site for: who is reading, and where its
  own links should point. Configured under `config :manhwa` in `config/config.exs`.
  """

  @doc """
  Who is reading. roki's `:browser` pipeline leaves PhoenixKit's *scope* on the connection and
  not the user, and a reader route is a plain controller route, so both are looked at — read
  only one and an unauthenticated-looking request quietly gets the reader's defaults instead of
  the person's own saved place.
  """
  def current_user(conn) do
    conn.assigns[:phoenix_kit_current_user] ||
      PhoenixKit.Users.Auth.Scope.user(conn.assigns[:phoenix_kit_current_scope])
  end

  @doc "The page behind a chapter: the series on the shelf."
  def series_url([source, slug]), do: "/manga/#{source}/#{slug}"
  def series_url(_), do: "/manga"
end
