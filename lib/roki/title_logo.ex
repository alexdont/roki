defmodule Roki.TitleLogo do
  @moduledoc """
  The title as its makers drew it: TMDB keeps a transparent PNG of the name (the "logo") for most
  films and shows. The details page shows it in place of the plain heading when there is one.
  Kept a day (a miss too, so a title without one is not asked again); a failure is not kept.
  """

  alias Roki.{TmdbApi, TTLCache}

  @ttl_s 24 * 3600

  @doc "The logo's address, or `nil`. `language` is the person's own (`\"en\"`), tried first."
  def for_title(type, id, uuid \\ nil, language \\ "en")
      when type in ["movie", "tv"] and is_integer(id) do
    case TTLCache.fetch({:title_logo, type, id, language}, @ttl_s, fn ->
           lookup(type, id, uuid, language)
         end) do
      {:ok, url} -> url
      _ -> nil
    end
  end

  @doc """
  What is already known, without asking TMDB: `{:ok, url_or_nil}` or `:miss`. The page uses it to
  draw the logo (or the plain name) in its very first paint.
  """
  def peek(type, id, language \\ "en"), do: TTLCache.peek({:title_logo, type, id, language})

  @doc "Could this person's page ever get a logo? It takes a TMDB key: the site's, or their own."
  def possible?(uuid),
    do: Roki.Featured.configured?() or (uuid != nil and Roki.Laev.connected?(uuid))

  defp lookup(type, id, uuid, language) do
    result =
      Roki.Laev.public(uuid, fn ->
        TmdbApi.get("/#{type}/#{id}/images", include_image_language: "#{language},en,null")
      end)

    case result do
      {:ok, body} -> {:ok, pick(body, language)}
      error -> error
    end
  end

  @doc "The best logo of an images answer: the person's language, else English, else none-specific."
  def pick(%{"logos" => [_ | _] = logos}, language) do
    rank = fn l ->
      lang = l["iso_639_1"]

      lang_rank =
        cond do
          lang == language -> 0
          lang == "en" -> 1
          lang == nil -> 2
          true -> 3
        end

      {lang_rank, -(l["vote_average"] || 0), -(l["width"] || 0)}
    end

    logos
    |> Enum.filter(
      &(is_binary(&1["file_path"]) and not String.ends_with?(&1["file_path"], ".svg"))
    )
    |> Enum.min_by(rank, fn -> nil end)
    |> case do
      %{"file_path" => path} -> "https://image.tmdb.org/t/p/w500" <> path
      _ -> nil
    end
  end

  def pick(_, _), do: nil
end
