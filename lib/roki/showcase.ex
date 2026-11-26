defmodule Roki.Showcase do
  @moduledoc """
  What the profile's showcase draws beyond the favourites themselves (worked out in
  `/lab/profile3d.html`): the recently watched row, the scores this person gave, and — one title at
  a time, when it is opened full screen — what it is: tagline, description, genres, length, who
  made it and who is in it.

  Read from the site's own copies (`Roki.Profile`, `Roki.Titles`, the manga library); only the
  credits of an opened film or show may ask TMDB, once a day per title (`Roki.Credits`).
  """

  alias Roki.Profile

  @doc """
  The last `n` films and shows finished, newest first, each as the showcase draws an item:
  `%{type, id, title, poster, year, at, score}` (`score` from `scores`, nil when unrated).
  """
  def recent(uuid, scores, n \\ 24) when is_binary(uuid) do
    uuid
    |> Profile.history()
    |> Enum.filter(&(&1.type in ["movie", "tv"] and is_integer(&1.id) and is_binary(&1.poster)))
    |> Enum.take(n)
    |> Enum.map(fn i ->
      %{
        type: i.type,
        id: i.id,
        title: i.title,
        poster: i.poster,
        year: i[:year],
        at: i.at,
        score: Map.get(scores, {i.type, i.id})
      }
    end)
  end

  @doc "The favourites as the showcase draws them: each with its score and the link to its page."
  def favorites(favs, scores) when is_map(favs) do
    Map.new(favs, fn {kind, list} ->
      {kind,
       Enum.map(list, fn i ->
         %{
           type: i.type || "manga",
           id: i.id || i[:mal_id],
           title: i.title,
           poster: i[:poster],
           position: i[:position],
           score: Map.get(scores, {i.type, i.id}),
           href: RokiWeb.PosterComponents.href(i)
         }
       end)}
    end)
  end

  @doc """
  What a title is, for the opened view: `%{overview, tagline, genres, minutes, vote, year, status,
  seasons, episodes, networks, studios, countries, directors, cast, authors}` — any of them nil or
  empty when not known. A manga is read from the manga library (`source`/`slug` from its link).
  """
  def details(type, id, viewer \\ nil)

  def details(type, id, viewer) when type in ["movie", "tv"] and is_integer(id) do
    case Roki.Titles.get(type, id) do
      {:ok, t, _} ->
        credits = Roki.Credits.for_title(type, id, viewer)
        seasons = t[:seasons]

        %{
          overview: t[:overview],
          tagline: t[:tagline],
          genres: names(t[:genres]),
          minutes: t[:minutes],
          vote: t[:vote],
          year: t[:year],
          status: t[:status],
          seasons: is_list(seasons) && Enum.count(seasons, &((&1[:number] || 0) > 0)),
          episodes: t[:episodes_total],
          networks: Enum.take(names(t[:networks]), 2),
          studios: Enum.take(names(t[:studios]), 2),
          countries: Enum.take(names(t[:countries]), 2),
          directors: Enum.take(names(credits[:directors]), 2),
          cast: Enum.take(names(credits[:cast]), 5)
        }

      _ ->
        %{}
    end
  end

  def details("manga", href, _viewer) when is_binary(href) do
    with [_, source, slug] <- Regex.run(~r{^/manga/([^/]+)/(.+)$}, href),
         %{} = md <- Roki.Manga.Library.get_manga_metadata(source, URI.decode(slug)),
         m <- Roki.Manga.Library.metadata_to_manga_map(md) do
      %{
        overview: m[:synopsis],
        genres: Enum.take(names(m[:genres]), 5),
        status: m[:status],
        year: m[:year],
        authors: names(List.wrap(m[:written_by]) ++ List.wrap(m[:illustrated_by]))
      }
    else
      _ -> %{}
    end
  end

  def details(_type, _id, _viewer), do: %{}

  # Names from TMDB's lists (strings, or maps with a name).
  defp names(list) when is_list(list) do
    for x <- list, n = if(is_map(x), do: x[:name] || x["name"], else: x), is_binary(n), do: n
  end

  defp names(_), do: []

  @doc """
  The ratings as the 3D piles draw them: per kind (`"all"`, `"movie"`, `"tv"`, `"mal"`), the
  average and the bars with their colours.
  """
  def ratings(counts) when is_map(counts) do
    for {k, kinds} <- [{"all", nil}, {"movie", ["movie"]}, {"tv", ["tv"]}, {"mal", ["mal"]}],
        k == "all" or Map.has_key?(counts, k),
        b = Profile.rating_breakdown(counts, kinds),
        b != nil,
        into: %{} do
      {k,
       %{
         avg_text: Profile.score_text(b.average),
         total: b.total,
         bars:
           for(
             {s, n} <- b.bars,
             do: %{score: s, n: n, color: RokiWeb.ScoreColor.color(s)}
           )
       }}
    end
  end

  def ratings(_), do: %{}
end
