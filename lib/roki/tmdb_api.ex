defmodule Roki.TmdbApi do
  @moduledoc """
  A plain GET against TMDB's v3 API, with the key of whoever's laev scope this runs in (the same
  rule `Laev.Tmdb` and `Roki.Browse` follow: a v4 token goes as a bearer, a v3 key as `api_key`).
  `{:ok, body}`, or `{:error, :no_tmdb_key | {:tmdb, status} | exception}`. Call it inside a scope
  (`Roki.Laev.public/2`).
  """

  @base "https://api.themoviedb.org/3"

  def get(path, params \\ []) do
    case Laev.Scope.get(:tmdb_key) do
      key when is_binary(key) and key != "" ->
        {auth, params} =
          if String.starts_with?(key, "eyJ"),
            do: {[auth: {:bearer, key}], params},
            else: {[], Keyword.put(params, :api_key, key)}

        case Req.get(
               Req.new(base_url: @base, retry: false, receive_timeout: 6_000),
               [url: path, params: params] ++ auth
             ) do
          {:ok, %{status: 200, body: body}} -> {:ok, body}
          {:ok, %{status: status}} -> {:error, {:tmdb, status}}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :no_tmdb_key}
    end
  end
end
