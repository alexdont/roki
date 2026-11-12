defmodule Roki.Soundtrack do
  @moduledoc """
  The music of a title, for the details page: the soundtrack albums MusicBrainz lists for it,
  with their tracks, and for an anime the opening and ending songs MyAnimeList knows. Each track
  is a link to a YouTube search for it — nothing here plays, and no YouTube key is needed.

  MusicBrainz (free, no key; one request a second, with a user agent that names the site) is
  asked for the release groups of secondary type *soundtrack* whose name is the title's, within
  a year of a film's release. The albums list is kept beside the titles (`Roki.Kept`) for a
  month, an album's tracks for a year (they never change), and both in memory for half a day.
  A failure is not kept. MyAnimeList's themes need the server's `MAL_CLIENT_ID`; without it
  an anime has only its albums.
  """

  alias Roki.{Kept, TTLCache}

  @mb "https://musicbrainz.org/ws/2"
  @agent "roki.ee/0.1 (https://roki.ee)"
  @ttl_s 12 * 3600
  @kept_s 30 * 24 * 3600
  @album_s 365 * 24 * 3600
  @albums 8
  @tracks 60

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

  # ── MusicBrainz ──────────────────────────────────────────────────

  defp search_albums(title) do
    names =
      Enum.uniq(for n <- [title.title, title[:original_title]], is_binary(n), n != "", do: n)

    Enum.reduce_while(names, {:ok, []}, fn name, acc ->
      case mb_get("/release-group/", query: query(name, title), limit: 25) do
        {:ok, %{"release-groups" => groups}} ->
          case pick_albums(groups, name) do
            [] -> {:cont, acc}
            albums -> {:halt, {:ok, albums}}
          end

        error ->
          {:halt, if(acc == {:ok, []}, do: error, else: acc)}
      end
    end)
  end

  @doc false
  # The Lucene query: the name, soundtracks only, and a film within a year of its release.
  def query(name, title) do
    base = ~s(releasegroup:"#{escape(name)}" AND secondarytype:soundtrack)

    case {title.type, title[:year]} do
      {"movie", year} when is_binary(year) ->
        y = String.to_integer(year)
        base <> " AND firstreleasedate:[#{y - 1} TO #{y + 1}]"

      _ ->
        base
    end
  end

  defp escape(s), do: Regex.replace(~r/(["\\])/, s, "\\\\\\1")

  @doc false
  # The release groups whose name begins with this title's (a search also matches on a word:
  # "Body Heat" is not Heat's), best first.
  def pick_albums(groups, name) when is_list(groups) do
    want = words(name)

    groups
    |> Enum.filter(fn g ->
      is_binary(g["id"]) and is_binary(g["title"]) and (g["score"] || 0) >= 50 and
        g["primary-type"] in ["Album", "EP", nil] and
        List.starts_with?(words(g["title"]), want)
    end)
    # Oldest first: the original album before its expanded editions, a show's seasons in order.
    |> Enum.sort_by(&{&1["first-release-date"] || "9999", -(&1["score"] || 0)})
    |> Enum.take(@albums)
    |> Enum.map(fn g ->
      %{
        id: g["id"],
        title: g["title"],
        year: Laev.Tmdb.year(g["first-release-date"]),
        artist: credit(g["artist-credit"]),
        tracks: nil
      }
    end)
  end

  def pick_albums(_, _), do: []

  # A name as it is compared: its words, lower case.
  defp words(s), do: s |> String.downcase() |> String.split(~r/[^\p{L}\p{N}]+/u, trim: true)

  defp read_tracks(mbid) do
    with {:ok, %{"releases" => releases}} <-
           mb_get("/release/",
             "release-group": mbid,
             inc: "recordings+artist-credits",
             status: "official",
             limit: 5
           ) do
      {:ok, parse_tracks(releases)}
    end
  end

  @doc false
  # The tracks of the fullest release of the group, numbered through its discs.
  def parse_tracks(releases) when is_list(releases) do
    releases
    |> Enum.map(fn r ->
      for m <- r["media"] || [], t <- m["tracks"] || [], is_binary(t["title"]), do: t
    end)
    |> Enum.max_by(&length/1, fn -> [] end)
    |> Enum.take(@tracks)
    |> Enum.with_index(1)
    |> Enum.map(fn {t, n} ->
      %{
        n: n,
        title: t["title"],
        artist: credit(t["artist-credit"] || get_in(t, ["recording", "artist-credit"])),
        secs: secs(t["length"] || get_in(t, ["recording", "length"]))
      }
    end)
  end

  def parse_tracks(_), do: []

  defp credit(credits) when is_list(credits) and credits != [] do
    credits
    |> Enum.map_join("", fn c -> credited(c) <> (c["joinphrase"] || "") end)
    # A Japanese credit joins its names with "、".
    |> String.replace("、", ", ")
    |> String.trim()
    |> blank()
  end

  defp credit(_), do: nil

  # The name as credited — in Latin letters when MusicBrainz has one (a Japanese artist's own
  # name is kept in kana; the sort name, "Kanno, Yoko", is the Latin one), so a YouTube search
  # finds the song from here.
  defp credited(c) do
    name = c["name"] || get_in(c, ["artist", "name"]) || ""

    if Regex.match?(~r/[A-Za-z]/, name) do
      name
    else
      case get_in(c, ["artist", "sort-name"]) do
        sort when is_binary(sort) ->
          if Regex.match?(~r/[A-Za-z]/, sort), do: unsorted(sort), else: name

        _ ->
          name
      end
    end
  end

  # "Kanno, Yoko" → "Yoko Kanno"; "The Seatbelts" stays.
  defp unsorted(sort) do
    case String.split(sort, ", ", parts: 2) do
      [last, first] -> first <> " " <> last
      _ -> sort
    end
  end

  defp secs(ms) when is_integer(ms) and ms > 0, do: div(ms, 1000)
  defp secs(_), do: nil

  defp mb_get(path, params) do
    case Req.get(
           Req.new(
             base_url: @mb,
             retry: false,
             receive_timeout: 8_000,
             headers: [{"user-agent", @agent}, {"accept", "application/json"}]
           ),
           url: path,
           params: Keyword.put(params, :fmt, "json")
         ) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      {:ok, %{status: status}} -> {:error, {:musicbrainz, status}}
      {:error, reason} -> {:error, reason}
    end
  end

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

  # ── YouTube ──────────────────────────────────────────────────────

  @doc "A YouTube search for these words (a word said twice — a track named after the film — once)."
  def youtube(words) when is_list(words) do
    q =
      words
      |> Enum.filter(&(is_binary(&1) and &1 != ""))
      |> Enum.uniq_by(&String.downcase/1)
      |> Enum.join(" ")

    "https://www.youtube.com/results?search_query=" <> URI.encode_www_form(q)
  end

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(v), do: v
end
