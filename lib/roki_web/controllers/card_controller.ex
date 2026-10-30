defmodule RokiWeb.CardController do
  @moduledoc """
  `/card/:type/:id` — what the wide card on a home-page row shows once it has opened: the facts
  (length, genres), the picture to show wide, and the trailer's YouTube key. Public, like the page
  it serves; held to a modest number of lookups a minute per person (or address), so sweeping the
  pointer along a row is not a burst of TMDB requests. The title itself is the site's own kept
  copy (`Roki.Watch.title/3`); the trailer is looked up once a day (`Roki.Trailers`).
  """
  use RokiWeb, :controller

  def show(conn, %{"type" => type, "id" => id}) do
    user = conn.assigns[:phoenix_kit_current_user]
    uuid = user && user.uuid

    with true <- type in ["movie", "tv"],
         {n, ""} <- Integer.parse(id),
         :ok <- Roki.RateLimit.check(:card, client(conn, uuid), 120, 60_000),
         {:ok, t} <- Roki.Watch.title(type, n, uuid) do
      conn
      |> put_resp_header("cache-control", "private, max-age=300")
      |> json(%{
        title: t.title,
        year: t.year,
        minutes: t.minutes,
        vote: t.vote,
        genres: Enum.take(t.genres || [], 3),
        backdrop: t.backdrop && Roki.Images.local(t.backdrop),
        trailer: Roki.Trailers.key(type, n, uuid),
        seasons: if(type == "tv", do: length(t.seasons || []))
      })
    else
      {:error, {:rate_limited, _}} -> send_resp(conn, 429, "")
      _ -> send_resp(conn, 404, "")
    end
  end

  defp client(_conn, uuid) when is_binary(uuid), do: {:user, uuid}
  defp client(conn, _), do: {:ip, conn.remote_ip |> :inet.ntoa() |> to_string()}
end
