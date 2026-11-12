defmodule Roki.Soundtrack do
  @moduledoc """
  The music of a title, for the details page: the soundtrack albums MusicBrainz lists for it,
  with their tracks, and for an anime the opening and ending songs MyAnimeList knows. Each track
  is a link to a YouTube search for it — nothing here plays, and no YouTube key is needed.

  MusicBrainz is asked through the `musicbrainz` package (made from this module; the user agent
  is set in config) for the release groups of secondary type *soundtrack* whose name is the
  title's, within a year of a film's release. The albums list is kept beside the titles (`Roki.Kept`) for a
  month, an album's tracks for a year (they never change), and both in memory for half a day.
  A failure is not kept. MyAnimeList's themes need the server's `MAL_CLIENT_ID`; without it
  an anime has only its albums.
  """

  alias Roki.{Kept, TTLCache}

  @ttl_s 12 * 3600
  @kept_s 30 * 24 * 3600
  @album_s 365 * 24 * 3600
  @albums 8
  @tracks 60

  @doc false
  # Kept rows come back with their string keys turned into atoms that exist (`Roki.Kept`). The
  # shapes kept here are made by the `soundtrack` and `myanimelist` packages, whose modules may
  # not be loaded yet when a kept row is read before either is called — so the keys are named
  # here, which is what makes the atoms exist once this module is loaded.
  def kept_keys,
    do: [:id, :title, :year, :artist, :tracks, :n, :secs, :song, :eps, :openings, :endings]

  @doc """
  `%{albums: [album], themes: [season]}` for a title (`Roki.Watch.title/3`'s map). `mals` are
  the anime's MyAnimeList entries as `[{label, mal_id}]`, a season each. The first album comes
  with its `tracks`; the others carry `tracks: nil` until `tracks/1` reads them.
  """
  def for_title(title, mals \\ []) do
    albums = albums(title)
    themes = for {label, mal} <- mals, is_integer(mal), s = themes(label, mal), s != nil, do: s

    albums =
      case albums do
        [first | rest] -> [%{first | tracks: tracks(first.id)} | rest]
        [] -> []
      end

    %{albums: albums, themes: themes}
  end

  @doc "The soundtrack albums of a title: `%{id, title, year, artist, tracks: nil}`, best first."
  def albums(%{type: type, id: id} = title) do
    case TTLCache.fetch({:ost_albums, 2, type, id}, @ttl_s, fn ->
           Kept.fetch("ost_albums", "#{type}:#{id}", @kept_s, fn -> search_albums(title) end)
         end) do
      {:ok, albums} -> albums
      _ -> []
    end
  end

  @doc "An album's tracks, `[%{n, title, artist, secs}]`, or `[]`."
  def tracks(mbid) when is_binary(mbid) do
    case TTLCache.fetch({:ost_tracks, 2, mbid}, @ttl_s, fn ->
           Kept.fetch("ost_tracks", mbid, @album_s, fn -> read_tracks(mbid) end, fn _ -> true end)
         end) do
      {:ok, tracks} -> tracks
      _ -> []
    end
  end

  # ── MusicBrainz (the `musicbrainz` package) ───────────────────────

  defp search_albums(title) do
    year = if title.type == "movie", do: title[:year]

    with {:ok, albums} <-
           MusicBrainz.albums(title.title,
             names: [title[:original_title]],
             year: year,
             limit: @albums
           ) do
      {:ok, Enum.map(albums, &Map.put(&1, :tracks, nil))}
    end
  end

  defp read_tracks(mbid), do: MusicBrainz.tracks(mbid, limit: @tracks)

  @doc "A YouTube search for these words (a word said twice — a track named after the film — once)."
  defdelegate youtube(words), to: MusicBrainz

  # ── MyAnimeList ──────────────────────────────────────────────────

  @doc "An anime's opening and ending songs, `%{label, mal, openings, endings}`, or nil."
  def themes(label, mal) when is_integer(mal) do
    case TTLCache.fetch({:ost_themes, 1, mal}, @ttl_s, fn ->
           Kept.fetch("ost_themes", Integer.to_string(mal), @kept_s, fn -> read_themes(mal) end)
         end) do
      {:ok, %{openings: [], endings: []}} -> nil
      {:ok, themes} -> Map.merge(themes, %{label: label, mal: mal})
      _ -> nil
    end
  end

  defp read_themes(mal) do
    case Application.get_env(:laev, :mal_client_id) do
      id when is_binary(id) and id != "" ->
        MyAnimeList.themes(mal, id, req_options: [receive_timeout: 8_000])

      _ ->
        {:error, :no_mal_client}
    end
  end

  @doc false
  # MAL's answer (`opening_themes`/`ending_themes`) read by the myanimelist package's parser.
  def parse_themes(body) do
    %{
      openings: for(t <- body["opening_themes"] || [], s = theme(t["text"]), s != nil, do: s),
      endings: for(t <- body["ending_themes"] || [], s = theme(t["text"]), s != nil, do: s)
    }
  end

  @doc false
  # MAL writes a theme as a line: `#2: "Space Lion" by The Seatbelts (ep 13)`.
  defdelegate theme(text), to: MyAnimeList, as: :parse_theme
end
