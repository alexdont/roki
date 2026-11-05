defmodule Roki.People do
  @moduledoc """
  An actor and everything they have been in: the page a face in a title's cast row leads to.
  One TMDB request (the person with their combined credits riding along), kept beside the
  titles (`Roki.Kept`) for a month and in memory for half a day. Public data, read with the key
  `Roki.Laev.public/2` picks.
  """

  alias Roki.{Kept, TmdbApi, TTLCache}

  @ttl_s 12 * 3600
  @kept_s 30 * 24 * 3600

  # Talk, news, reality: appearing on them is not acting.
  @not_acting [10763, 10764, 10767]

  @doc """
  `{:ok, %{id, name, photo, known_for, cards}}` or `{:error, reason}`. `cards` are the titles
  they acted in, newest first, in the shape every poster grid takes (plus `character`).
  """
  def for_person(uuid, id) when is_integer(id) do
    TTLCache.fetch({:person, 1, id}, @ttl_s, fn ->
      Kept.fetch("person", Integer.to_string(id), @kept_s, fn ->
        with {:ok, body} <-
               Roki.Laev.public(uuid, fn ->
                 TmdbApi.get("/person/#{id}", append_to_response: "combined_credits")
               end),
             %{} = person <- parse(body) do
          Roki.Titles.remember_later(person.cards)
          {:ok, person}
        else
          nil -> {:error, :not_found}
          error -> error
        end
      end)
    end)
  end

  def for_person(_uuid, _id), do: {:error, :not_found}

  @doc "TMDB's person answer (with `combined_credits`), cut down to the page."
  def parse(%{"id" => id, "name" => name} = body) do
    cards =
      (get_in(body, ["combined_credits", "cast"]) || [])
      |> Enum.filter(&acting?/1)
      |> Enum.map(&card/1)
      |> Enum.uniq_by(&{&1.type, &1.id})
      |> Enum.sort_by(&{&1.date || "", &1.popularity || 0}, :desc)

    %{
      id: id,
      name: name,
      photo: body["profile_path"] && "https://image.tmdb.org/t/p/w342#{body["profile_path"]}",
      known_for: body["known_for_department"],
      cards: cards
    }
  end

  def parse(_), do: nil

  # A film or a show they played a part in: not a talk show, not themselves in a documentary.
  defp acting?(%{"media_type" => type} = c) when type in ["movie", "tv"] do
    genres = c["genre_ids"] || []
    character = c["character"] || ""

    not Enum.any?(genres, &(&1 in @not_acting)) and
      not Regex.match?(
        ~r/^\s*(self|himself|herself|themself|themselves)\b|\((as )?(him|her|them)self\)/i,
        character
      )
  end

  defp acting?(_), do: false

  defp card(c) do
    date = c["release_date"] || c["first_air_date"]

    %{
      type: c["media_type"],
      id: c["id"],
      title: c["title"] || c["name"],
      year: Laev.Tmdb.year(date),
      date: blank(date),
      overview: c["overview"],
      poster: Laev.Tmdb.poster_url(c["poster_path"], "w342"),
      vote: c["vote_average"],
      popularity: c["popularity"],
      character: blank(c["character"])
    }
  end

  defp blank(""), do: nil
  defp blank(v), do: v
end
