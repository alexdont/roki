defmodule Roki.Similar do
  @moduledoc """
  "More like this": what TMDB recommends for a film or a show, topped up from its similar list.
  Public data, so it is read with whichever key `Roki.Laev.public/2` picks and kept for everyone
  half a day. Laev has no call for these two endpoints yet; this asks TMDB the way
  `Laev.Tmdb` does and gives the same card shape (`%{id, type, title, year, poster, vote}`).
  """

  alias Roki.TTLCache

  @ttl_s 12 * 3600
  @max 12

  @doc "`{:ok, [card]}` (possibly empty) or `{:error, reason}`."
  def for_title(uuid, type, id) when type in ["movie", "tv"] and is_integer(id) do
    TTLCache.fetch({:similar, type, id}, @ttl_s, fn ->
      Roki.Laev.public(uuid, fn -> load(type, id) end)
    end)
  end

  def for_title(_uuid, _type, _id), do: {:ok, []}

  defp load(type, id) do
    with {:ok, recommended} <- get("/#{type}/#{id}/recommendations", type) do
      cards =
        if length(recommended) >= @max do
          recommended
        else
          case get("/#{type}/#{id}/similar", type) do
            {:ok, similar} -> recommended ++ similar
            _ -> recommended
          end
        end

      {:ok, cards |> Enum.uniq_by(& &1.id) |> Enum.reject(&(&1.id == id)) |> Enum.take(@max)}
    end
  end

  defp get(path, type) do
    case Laev.Scope.get(:tmdb_key) do
      key when is_binary(key) and key != "" ->
        {auth, params} =
          if String.starts_with?(key, "eyJ"),
            do: {[auth: {:bearer, key}], []},
            else: {[], [api_key: key]}

        opts = [url: path, params: params, retry: false] ++ auth

        case Req.request(Req.new(base_url: "https://api.themoviedb.org/3"), opts) do
          {:ok, %{status: 200, body: %{"results" => results}}} ->
            {:ok, for(r <- results, r["poster_path"], do: card(r, type))}

          {:ok, %{status: status}} ->
            {:error, {:tmdb, status}}

          {:error, reason} ->
            {:error, reason}
        end

      _ ->
        {:error, :no_tmdb_key}
    end
  end

  defp card(r, type) do
    %{
      id: r["id"],
      type: type,
      title: r["title"] || r["name"],
      year: Laev.Tmdb.year(r["release_date"] || r["first_air_date"]),
      poster: Laev.Tmdb.poster_url(r["poster_path"], "w342"),
      vote: r["vote_average"]
    }
  end
end
