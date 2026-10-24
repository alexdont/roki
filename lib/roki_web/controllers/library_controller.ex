defmodule RokiWeb.LibraryController do
  @moduledoc """
  The two actions on a poster's hover card, without opening the title: save it for later, and mark
  it watched. `GET /library/:type/:id` says where the title stands for the signed-in user, and
  `POST /library/:type/:id/saved|watched` flips one and answers with the new state. A film is
  watched with its own mark; a series is marked completed — every episode, and the series itself
  (see `Roki.Watch.set_series_watched/3`) — or taken back out. Only for an account that has set up
  its shelf; anyone else gets a 404 and the card shows no buttons.
  """
  use RokiWeb, :controller

  alias Roki.Watch

  def show(conn, %{"type" => type, "id" => id}) do
    with {:ok, uuid, title} <- context(conn, type, id) do
      json(conn, state(uuid, title))
    else
      other -> fail(conn, other)
    end
  end

  def toggle(conn, %{"type" => type, "id" => id, "what" => what})
      when what in ["saved", "watched"] do
    with {:ok, uuid, title} <- context(conn, type, id) do
      flip(what, uuid, title)
      json(conn, state(uuid, title))
    else
      other -> fail(conn, other)
    end
  end

  def toggle(conn, _params), do: send_resp(conn, 404, "")

  defp flip("saved", uuid, title), do: Watch.toggle_saved(uuid, title)

  defp flip("watched", uuid, %{type: "movie"} = title) do
    Watch.set_watched(uuid, title, nil, nil, not Watch.library(uuid, title).watched?)
  end

  defp flip("watched", uuid, title) do
    Watch.set_series_watched(uuid, title, not Watch.library(uuid, title).all_watched?)
  end

  defp state(uuid, title) do
    lib = Watch.library(uuid, title)

    %{
      saved: lib.saved?,
      watched: if(title.type == "movie", do: lib.watched?, else: lib.all_watched?)
    }
  end

  defp context(conn, type, id) do
    with user when not is_nil(user) <- conn.assigns[:phoenix_kit_current_user],
         true <- type in ["movie", "tv"],
         {n, ""} <- Integer.parse(id),
         true <- Roki.Laev.connected?(user.uuid),
         :ok <- Roki.RateLimit.check(:library, {:user, user.uuid}, 60, 60_000),
         {:ok, title} <- Watch.title(type, n, user.uuid) do
      {:ok, user.uuid, title}
    end
  end

  defp fail(conn, nil), do: send_resp(conn, 401, "")
  defp fail(conn, {:error, {:rate_limited, _}}), do: send_resp(conn, 429, "")
  defp fail(conn, _other), do: send_resp(conn, 404, "")
end
