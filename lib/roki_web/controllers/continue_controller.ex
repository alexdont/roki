defmodule RokiWeb.ContinueController do
  @moduledoc """
  `/continue/:type/:id` — the home page's Continue button. It does what Play on the title page
  does, without the title page: works out what is next for this person (a film; for a series the
  episode left half-way, else the first unseen one) and goes straight to playing it, by the
  sources page's `?auto=1` — the best source starts by itself. One press, and it is playing.
  """
  use RokiWeb, :controller

  alias Roki.Watch

  def show(conn, %{"type" => type, "id" => id}) when type in ["movie", "tv"] do
    uuid =
      case conn.assigns[:phoenix_kit_current_user] do
        %{uuid: uuid} when is_binary(uuid) -> uuid
        _ -> nil
      end

    with uuid when is_binary(uuid) <- uuid,
         {n, ""} <- Integer.parse(id),
         {:ok, path} <- Watch.continue_path(uuid, type, n) do
      redirect(conn, to: path)
    else
      # Not signed in, or not something that can be played: the title's own page says why.
      _ -> redirect(conn, to: title_path(type, id))
    end
  end

  def show(conn, _params), do: redirect(conn, to: ~p"/")

  defp title_path(type, id) do
    case Integer.parse(id) do
      {n, ""} -> ~p"/title/#{type}/#{n}"
      _ -> ~p"/"
    end
  end
end
