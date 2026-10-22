defmodule RokiWeb.PeekController do
  @moduledoc """
  `/peek/:type/:id` — the few facts a poster's hover card shows (year, length, rating, genres,
  a short overview), as JSON. Signed-in users only: the lookup uses their own TMDB key. A title
  is looked up once and remembered for twelve hours (`Roki.Watch.title/3`), and a user is held
  to a modest number of lookups a minute, so sweeping the mouse over a page cannot become a
  burst of TMDB requests.
  """
  use RokiWeb, :controller

  def show(conn, %{"type" => type, "id" => id}) do
    with user when not is_nil(user) <- conn.assigns[:phoenix_kit_current_user],
         true <- type in ["movie", "tv"],
         {n, ""} <- Integer.parse(id),
         uuid = user.uuid,
         :ok <- Roki.RateLimit.check(:peek, {:user, uuid}, 90, 60_000),
         {:ok, t} <- Roki.Watch.title(type, n, uuid) do
      conn
      |> put_resp_header("cache-control", "private, max-age=3600")
      |> json(%{
        title: t.title,
        year: t.year,
        date: t.date,
        minutes: t.minutes,
        vote: t.vote,
        genres: Enum.take(t.genres || [], 4),
        tagline: t.tagline,
        overview: shorten(t.overview),
        seasons: if(type == "tv", do: length(t.seasons || []))
      })
    else
      nil -> send_resp(conn, 401, "")
      {:error, {:rate_limited, _}} -> send_resp(conn, 429, "")
      _ -> send_resp(conn, 404, "")
    end
  end

  defp shorten(nil), do: nil

  defp shorten(text) do
    if String.length(text) > 260, do: String.slice(text, 0, 257) <> "…", else: text
  end
end
