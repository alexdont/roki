defmodule Roki.Credits do
  @moduledoc """
  Who is in a title and who made it: the cast the details page shows as a row of faces, and a
  film's directors and writers for its facts. One TMDB request (credits ride along on the title's
  own endpoint), kept a day; a failure is not kept.
  """

  alias Roki.{TmdbApi, TTLCache}

  @ttl_s 24 * 3600
  @cast 18

  @doc """
  `%{cast: [%{name, character, photo}], directors: [name], writers: [name]}`, or the same with
  nothing in it when TMDB has none or cannot be reached. `type` is `"movie"` or `"tv"`.
  """
  def for_title(type, id, uuid \\ nil) when type in ["movie", "tv"] and is_integer(id) do
    case TTLCache.fetch({:credits, type, id}, @ttl_s, fn -> lookup(type, id, uuid) end) do
      {:ok, credits} -> credits
      _ -> empty()
    end
  end

  def empty, do: %{cast: [], directors: [], writers: []}

  defp lookup(type, id, uuid) do
    case Roki.Laev.public(uuid, fn -> TmdbApi.get("/#{type}/#{id}/credits") end) do
      {:ok, body} -> {:ok, parse(body)}
      error -> error
    end
  end

  @doc "The credits answer, cut down to what the page shows."
  def parse(%{} = body) do
    cast =
      for %{"name" => name} = person <- Enum.take(body["cast"] || [], @cast) do
        %{
          name: name,
          character: blank(person["character"]),
          photo:
            person["profile_path"] && "https://image.tmdb.org/t/p/w185#{person["profile_path"]}"
        }
      end

    crew = body["crew"] || []

    %{
      cast: cast,
      directors: names(crew, &(&1["job"] == "Director")),
      writers: names(crew, &(&1["job"] in ["Screenplay", "Writer", "Story"]), 3)
    }
  end

  def parse(_), do: empty()

  defp names(crew, keep, limit \\ 3) do
    crew |> Enum.filter(keep) |> Enum.map(& &1["name"]) |> Enum.uniq() |> Enum.take(limit)
  end

  defp blank(""), do: nil
  defp blank(value), do: value
end
