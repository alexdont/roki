defmodule Roki.Profile do
  @moduledoc """
  A user's public page (`/:username`): a banner and a few words of their own, and what they
  have watched — newest first, or by their own ratings, so the ten-out-of-tens can be shown.

  The page is private until its owner opens it, and the owner chooses whether the history and
  the ratings are on it. The history is laev's list of finished titles, read in the owner's
  scope and remembered for a few minutes; the ratings are copied into the site's own table from
  TMDB (the owner's TMDB account) and MyAnimeList (their list) now and then, and kept up to date
  by the ratings made here, so a visitor's view never needs the owner's keys.
  """

  alias Roki.{Repo, TTLCache}

  @bio_max 600
  @history_ttl_s 5 * 60
  @ratings_every_s 3600

  @defaults %{
    bio: "",
    banner: nil,
    public: false,
    show_history: true,
    show_ratings: true,
    ratings_synced_at: nil
  }

  # ── who ───────────────────────────────────────────────────────────

  @doc "The account behind a username, or nil."
  def user(username) when is_binary(username) and username != "",
    do: PhoenixKit.Users.Auth.get_user_by_username(username)

  def user(_), do: nil

  # ── the profile row ───────────────────────────────────────────────

  @doc "The profile of a user: the row, or the defaults (private, nothing written) for one who never set it up."
  def get(uuid) when is_binary(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    case Repo.query!(
           "select bio, banner, public, show_history, show_ratings, ratings_synced_at from roki_profiles where user_uuid = $1",
           [bin]
         ) do
      %{rows: [[bio, banner, public, history, ratings, synced]]} ->
        %{
          user_uuid: uuid,
          bio: bio || "",
          banner: banner,
          public: public,
          show_history: history,
          show_ratings: ratings,
          ratings_synced_at: synced
        }

      _ ->
        Map.put(@defaults, :user_uuid, uuid)
    end
  end

  @doc """
  Change what the owner wrote and chose: `bio` (text, at most #{@bio_max} characters), `public`,
  `show_history`, `show_ratings` (true/false or "true"/"false"). `{:ok, profile}` or
  `{:error, message}`.
  """
  def update(uuid, attrs) when is_binary(uuid) and is_map(attrs) do
    current = get(uuid)
    bio = attrs |> Map.get("bio", current.bio) |> to_string() |> String.trim()

    if String.length(bio) > @bio_max do
      {:error, "Keep the description under #{@bio_max} characters."}
    else
      flags =
        for key <- [:public, :show_history, :show_ratings], into: %{} do
          {key, bool(Map.get(attrs, Atom.to_string(key), current[key]))}
        end

      {:ok, bin} = Ecto.UUID.dump(uuid)
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.query!(
        """
        insert into roki_profiles (user_uuid, bio, public, show_history, show_ratings, inserted_at, updated_at)
        values ($1, $2, $3, $4, $5, $6, $6)
        on conflict (user_uuid) do update
          set bio = excluded.bio, public = excluded.public, show_history = excluded.show_history,
              show_ratings = excluded.show_ratings, updated_at = excluded.updated_at
        """,
        [bin, bio, flags.public, flags.show_history, flags.show_ratings, now]
      )

      {:ok, get(uuid)}
    end
  end

  defp bool(true), do: true
  defp bool("true"), do: true
  defp bool("on"), do: true
  defp bool(_), do: false

  # ── the banner ────────────────────────────────────────────────────

  @doc "Where banners are kept: beside laev's accounts, in the data that survives a container."
  def banner_dir,
    do: Application.get_env(:roki, :banner_dir) || Path.join(System.user_home!(), "roki-banners")

  @doc "The address a profile's banner is served at, or nil without one."
  def banner_url(%{banner: name}) when is_binary(name) and name != "", do: "/banners/#{name}"
  def banner_url(_profile), do: nil

  @doc "The file behind a banner name, when the name is one this module writes; nil otherwise."
  def banner_file(name) when is_binary(name) do
    if Regex.match?(~r/^[0-9a-f-]{36}-\d+\.jpg$/, name), do: Path.join(banner_dir(), name)
  end

  def banner_file(_), do: nil

  @doc """
  Keep an uploaded picture as the user's banner: made into a JPEG no wider than 1800 px (a
  phone's photo is far larger than any screen it is shown on), under a name that changes with
  every upload so browsers never show a stale one. The old file goes. `{:ok, profile}` or
  `{:error, message}`.
  """
  def store_banner(uuid, path) when is_binary(uuid) and is_binary(path) do
    dir = banner_dir()
    File.mkdir_p!(dir)
    name = "#{uuid}-#{System.os_time(:second)}.jpg"
    out = Path.join(dir, name)

    args =
      ~w(-nostdin -loglevel error -y -i) ++
        [path, "-frames:v", "1", "-vf", "scale='min(1800,iw)':-2", "-q:v", "4", out]

    case System.cmd("ffmpeg", args, stderr_to_stdout: true) do
      {_, 0} ->
        old = get(uuid).banner
        set_banner(uuid, name)
        if old, do: File.rm(Path.join(dir, old))
        {:ok, get(uuid)}

      {out_text, _} ->
        File.rm(out)
        {:error, "That picture could not be read (#{String.slice(String.trim(out_text), 0, 80)})."}
    end
  end

  @doc "Take the banner off the profile (and its file off the disk)."
  def clear_banner(uuid) when is_binary(uuid) do
    case get(uuid).banner do
      nil -> :ok
      old -> File.rm(Path.join(banner_dir(), old))
    end

    set_banner(uuid, nil)
    :ok
  end

  defp set_banner(uuid, name) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.query!(
      """
      insert into roki_profiles (user_uuid, banner, inserted_at, updated_at) values ($1, $2, $3, $3)
      on conflict (user_uuid) do update set banner = excluded.banner, updated_at = excluded.updated_at
      """,
      [bin, name, now]
    )

    :ok
  end

  # ── what they watched ─────────────────────────────────────────────

  @doc """
  Everything the user finished, newest first, as laev lists it (`Roki.Laev.completed/1`):
  `[%{type:, id:, mal_id:, title:, poster:, anime:, at:, dated?:}]`. Remembered for a few
  minutes: it reads the owner's files, and a profile is looked at more often than it changes.
  """
  def history(uuid) when is_binary(uuid) do
    case TTLCache.fetch({:profile_history, uuid}, @history_ttl_s, fn ->
           if Roki.Laev.connected?(uuid),
             do: {:ok, Roki.Laev.completed(uuid)},
             else: {:ok, []}
         end) do
      {:ok, items} when is_list(items) -> items
      _ -> []
    end
  end

  @doc "Forget the remembered history (after a sync, say)."
  def forget_history(uuid), do: TTLCache.delete({:profile_history, uuid})

  @doc "Posters for the shown rows that have none yet (one TMDB read each, once), by {type, id}."
  def posters(uuid, items), do: Roki.Laev.completed_posters(uuid, items)

  @doc "The kinds a profile's history is filtered by."
  def kinds, do: [all: "All", movie: "Movies", tv: "Shows", anime: "Anime"]

  @doc "The kind named in an address, else :all."
  def kind(value), do: Enum.find_value(kinds(), :all, fn {k, _} -> Atom.to_string(k) == value && k end)

  @doc "The order named in an address: :top for the owner's ratings, else :latest."
  def sort("top"), do: :top
  def sort(_), do: :latest

  @doc """
  The history as the page shows it: of one `kind` (`:all`, `:movie`, `:tv`, `:anime`), in
  `order` (`:latest` — newest first — or `:top` — the owner's own rating first, the unrated last),
  and only the tens when `tens?`. Each item gets its `score` (nil when unrated) and, in the
  rating order, the score as its badge.
  """
  def arrange(items, ratings, kind, order, tens? \\ false) do
    items
    |> Enum.filter(&of_kind?(&1, kind))
    |> Enum.map(&Map.put(&1, :score, score_of(ratings, &1)))
    |> Enum.filter(&(not tens? or &1.score == 10.0))
    |> then(fn list ->
      case order do
        :top ->
          list
          |> Enum.sort_by(&{if(&1.score, do: 0, else: 1), -(&1.score || 0), -&1.at})
          |> Enum.map(&Map.put(&1, :badge, badge(&1.score)))

        _ ->
          list
      end
    end)
  end

  defp of_kind?(_item, :all), do: true
  defp of_kind?(item, :anime), do: item.anime
  defp of_kind?(item, kind), do: not item.anime and item.type == Atom.to_string(kind)

  defp badge(nil), do: nil
  defp badge(score), do: "★ " <> score_text(score)

  @doc "A score as the page writes it: `10`, `8.5`."
  def score_text(score) when is_float(score) do
    if score == Float.round(score), do: Integer.to_string(trunc(score)), else: :erlang.float_to_binary(score, decimals: 1)
  end

  def score_text(score), do: to_string(score)

  # An anime is rated on MyAnimeList when it has an entry there (the site rates it there too);
  # everything else on TMDB.
  defp score_of(ratings, %{mal_id: mal} = item) when is_integer(mal),
    do: ratings[{"mal", mal}] || ratings[{item.type, item.id}]

  defp score_of(ratings, item), do: ratings[{item.type, item.id}]

  # ── the ratings ───────────────────────────────────────────────────

  @doc "The user's ratings as copied here, by {type, id}: `{\"movie\", 10331}` to 8.5, `{\"mal\", 5114}` to 9.0."
  def ratings(uuid) when is_binary(uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    %{rows: rows} = Repo.query!("select type, id, score from roki_ratings where user_uuid = $1", [bin])
    Map.new(rows, fn [type, id, score] -> {{type, id}, score * 1.0} end)
  end

  @doc """
  A rating made or taken back on the site, noted here at once: `target` is `{"mal", id}` or
  `{"movie" | "tv", id}`, `score` the rating or nil for none.
  """
  def note_rating(uuid, {type, id}, score) when is_binary(uuid) and is_binary(type) and is_integer(id) do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    if is_number(score) and score > 0 do
      now = DateTime.utc_now() |> DateTime.truncate(:second)

      Repo.query!(
        """
        insert into roki_ratings (user_uuid, type, id, score, rated_at) values ($1, $2, $3, $4, $5)
        on conflict (user_uuid, type, id) do update set score = excluded.score, rated_at = excluded.rated_at
        """,
        [bin, type, id, score * 1.0, now]
      )
    else
      Repo.query!("delete from roki_ratings where user_uuid = $1 and type = $2 and id = $3", [bin, type, id])
    end

    :ok
  end

  def note_rating(_uuid, _target, _score), do: :ok

  @doc """
  Copy the user's ratings here from TMDB (their account's rated films and shows) and
  MyAnimeList (the scores on their list), at most once an hour: a long-standing TMDB account
  is many pages. One copy at a time, and an hour counts from a copy that finished — a page
  that goes away half-way through leaves the next one to do it. `:ok`, `:recent` when done
  lately, `:not_connected` without laev.
  """
  def refresh_ratings(uuid) when is_binary(uuid) do
    cond do
      not Roki.Laev.connected?(uuid) ->
        :not_connected

      TTLCache.cached?({:ratings_refresh, uuid}) ->
        :recent

      true ->
        TTLCache.fetch({:ratings_refresh, uuid}, @ratings_every_s, fn ->
          replace_ratings(uuid, read_ratings(uuid))
          {:ok, :done}
        end)

        :ok
    end
  end

  defp read_ratings(uuid) do
    Roki.Laev.run(uuid, fn -> 
            tmdb =
              if Laev.Tmdb.account?() do
                for {kind, type} <- [{"movies", "movie"}, {"tv", "tv"}],
                    r <- Laev.Tmdb.rated(kind),
                    is_integer(r["id"]) and is_number(r["rating"]) do
                  {type, r["id"], r["rating"] * 1.0, nil}
                end
              else
                []
              end

            mal =
              if Laev.MAL.authenticated?() do
                case Laev.MAL.list() do
                  {:ok, entries} ->
                    for %{mal_id: id, score: score} = e <- entries, is_integer(score) and score > 0 do
                      {"mal", id, score * 1.0, e[:updated] && DateTime.from_unix!(e[:updated])}
                    end

                  _ ->
                    []
                end
              else
                []
              end

            tmdb ++ mal
    end)
  end

  defp replace_ratings(uuid, rows) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.transaction(fn ->
      Repo.query!("delete from roki_ratings where user_uuid = $1", [bin])

      rows
      |> Enum.uniq_by(fn {type, id, _, _} -> {type, id} end)
      |> Enum.chunk_every(500)
      |> Enum.each(fn chunk ->
        {values, params} =
          chunk
          |> Enum.with_index()
          |> Enum.map_reduce([], fn {{type, id, score, at}, i} , acc ->
            n = i * 4
            {"($1, $#{n + 2}, $#{n + 3}, $#{n + 4}, $#{n + 5})", acc ++ [type, id, score, at]}
          end)

        Repo.query!(
          "insert into roki_ratings (user_uuid, type, id, score, rated_at) values " <> Enum.join(values, ", "),
          [bin | params]
        )
      end)

      Repo.query!(
        """
        insert into roki_profiles (user_uuid, ratings_synced_at, inserted_at, updated_at) values ($1, $2, $2, $2)
        on conflict (user_uuid) do update set ratings_synced_at = excluded.ratings_synced_at
        """,
        [bin, now]
      )
    end)

    :ok
  end
end
