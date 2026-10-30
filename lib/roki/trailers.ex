defmodule Roki.Trailers do
  @moduledoc """
  A title's trailer: the YouTube key of the best official one TMDB lists for it.

  TMDB holds no video of its own, only the addresses of YouTube ones, so a trailer is played by
  embedding YouTube's player. Not every video may be embedded (the owner can switch it off, and
  then the player shows an error instead of a film), so each candidate is asked about first —
  YouTube's own oEmbed answer is 200 for one that can be and not for one that cannot — and the
  first that can be is the one. Kept a day; a title with no trailer is kept as that, so a page full
  of such titles is not a page of requests.
  """

  alias Roki.TTLCache

  @base "https://api.themoviedb.org/3"
  @ttl_s 24 * 3600

  @doc "The YouTube key of this film's or show's trailer, or nil. `type` is `\"movie\"` or `\"tv\"`."
  def key(type, id, uuid \\ nil) when type in ["movie", "tv"] and is_integer(id) do
    case TTLCache.fetch({:trailer, type, id}, @ttl_s, fn -> lookup(type, id, uuid) end) do
      {:ok, key} -> key
      _ -> nil
    end
  end

  defp lookup(type, id, uuid) do
    case Roki.Laev.public(uuid, fn -> videos(type, id) end) do
      {:ok, results} -> {:ok, results |> candidates() |> Enum.find(&embeddable?/1)}
      error -> error
    end
  end

  @doc """
  The YouTube keys worth trying, best first, from TMDB's `results`: trailers before teasers, the
  official ones first, then the newest. Nothing else (clips, featurettes, other sites).
  """
  def candidates(results) when is_list(results) do
    results
    |> Enum.filter(
      &(&1["site"] == "YouTube" and &1["type"] in ["Trailer", "Teaser"] and is_binary(&1["key"]))
    )
    |> Enum.sort_by(
      &{&1["type"] != "Trailer", &1["official"] != true, invert(&1["published_at"])}
    )
    |> Enum.map(& &1["key"])
    |> Enum.uniq()
    |> Enum.take(3)
  end

  def candidates(_), do: []

  # Newest first by sorting the text of the date backwards (ISO dates sort as dates).
  defp invert(nil), do: []
  defp invert(date), do: date |> String.to_charlist() |> Enum.map(&(-&1))

  defp embeddable?(key) do
    case Req.get("https://www.youtube.com/oembed",
           params: [url: "https://www.youtube.com/watch?v=#{key}", format: "json"],
           retry: false,
           receive_timeout: 4_000
         ) do
      {:ok, %{status: 200}} -> true
      _ -> false
    end
  rescue
    _ -> false
  end

  defp videos(type, id) do
    case Laev.Scope.get(:tmdb_key) do
      key when is_binary(key) and key != "" ->
        {auth, params} =
          if String.starts_with?(key, "eyJ"),
            do: {[auth: {:bearer, key}], []},
            else: {[], [api_key: key]}

        case Req.get(
               Req.new(base_url: @base, retry: false, receive_timeout: 6_000),
               [
                 url: "/#{type}/#{id}/videos",
                 params: params ++ [include_video_language: "en,null"]
               ] ++ auth
             ) do
          {:ok, %{status: 200, body: %{"results" => results}}} -> {:ok, results}
          {:ok, %{status: status}} -> {:error, {:tmdb, status}}
          {:error, reason} -> {:error, reason}
        end

      _ ->
        {:error, :no_tmdb_key}
    end
  end
end
