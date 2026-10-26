defmodule Roki.Images do
  @moduledoc """
  Pictures from elsewhere — TMDB's posters, backdrops and stills, MyAnimeList's anime
  pictures — kept in PhoenixKit's media library (`Roki.Media`, folder "roki / Pictures") and
  served from there.

  A page names a picture through `local/1`: one the site already holds comes out as its media
  address; one it has never fetched comes out as `/img/…`, which fetches it, keeps it, and
  sends the browser on to the media address. Which pictures are held is a table
  (`roki_pictures`) mirrored in memory, so naming sixty posters costs sixty lookups in an
  ETS table and no query.
  """
  use GenServer

  @table __MODULE__
  @folder "Pictures"
  @tmdb "https://image.tmdb.org/t/p/"
  @mal "https://cdn.myanimelist.net/images/"
  @sizes ~w(w92 w185 w300 w342 w500 w780 w1280 original)

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    :ets.new(@table, [:named_table, :set, :public, read_concurrency: true])
    load()
    {:ok, nil}
  end

  # Every picture held, into memory: a few thousand small rows.
  defp load do
    %{rows: rows} = Roki.Repo.query!("select key, file_uuid from roki_pictures")
    for [key, uuid] <- rows, do: :ets.insert(@table, {key, Ecto.UUID.load!(uuid)})
    :ok
  rescue
    _ -> :ok
  end

  @doc "The sizes TMDB serves."
  def sizes, do: @sizes

  @doc """
  A picture's address for a page: its media address when the site holds it, else the site's
  own fetching address (`/img/w342/abc.jpg`, `/img/mal/anime/1/2.jpg`); anything that is not
  a picture the site keeps copies of is left as it is.
  """
  def local(url) when is_binary(url) do
    case key(url) do
      nil ->
        url

      key ->
        case :ets.lookup(@table, key) do
          [{_, uuid}] -> Roki.Media.url(uuid)
          [] -> "/img/" <> short(key)
        end
    end
  rescue
    _ -> url
  end

  def local(other), do: other

  # The key of a picture the site keeps copies of: its address without the scheme and the
  # host's fixed part, so `image.tmdb.org/t/p/w342/abc.jpg` is `tmdb/w342/abc.jpg` in short.
  @doc false
  def key(@tmdb <> rest) do
    case String.split(rest, "/", parts: 2) do
      [size, file] when size in @sizes -> if file?(file), do: "image.tmdb.org/t/p/" <> size <> "/" <> file
      _ -> nil
    end
  end

  def key(@mal <> rest), do: if(mal_path?(rest), do: "cdn.myanimelist.net/images/" <> rest)
  def key(_), do: nil

  defp short("image.tmdb.org/t/p/" <> rest), do: rest
  defp short("cdn.myanimelist.net/images/" <> rest), do: "mal/" <> rest

  # TMDB names a picture by a short token and an extension; MyAnimeList by a kind, a shelf and
  # a number (`anime/1234/56789l.jpg`). Nothing else is fetched.
  defp file?(file), do: Regex.match?(~r/^[A-Za-z0-9]{1,64}\.(jpg|jpeg|png|webp)$/, file)
  defp mal_path?(rest), do: Regex.match?(~r/^(anime|manga|characters)\/\d{1,8}\/\d{1,10}[a-z]?\.(jpg|jpeg|png|webp)$/, rest)

  @doc """
  The media address of a picture named by the short form a `/img/` address carries (`"w342/
  abc.jpg"`, `"mal/anime/1/2.jpg"`), fetching and keeping it first when the site does not hold
  it yet: `{:ok, url}`, `{:error, :bad_name}` for anything that is not such a picture, or
  `{:error, reason}` when it could not be fetched (the caller then sends the browser to the
  source for this once).
  """
  def ensure(short) when is_binary(short) do
    case source(short) do
      nil ->
        {:error, :bad_name}

      {key, source_url} ->
        case :ets.lookup(@table, key) do
          [{_, uuid}] -> {:ok, Roki.Media.url(uuid)}
          [] -> fetch(key, source_url)
        end
    end
  end

  @doc "The source address of a picture named in short form, or nil."
  def source_url(short) do
    case source(short) do
      {_key, url} -> url
      nil -> nil
    end
  end

  defp source("mal/" <> rest), do: with(k when is_binary(k) <- key(@mal <> rest), do: {k, @mal <> rest})
  defp source(rest), do: with(k when is_binary(k) <- key(@tmdb <> rest), do: {k, @tmdb <> rest})

  defp fetch(key, source_url) do
    file = Path.basename(key)
    tmp = Path.join(System.tmp_dir!(), "roki-pic-#{System.unique_integer([:positive])}-#{file}")

    try do
      with {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) > 0 <-
             Req.get(source_url, retry: false, receive_timeout: 20_000, decode_body: false),
           :ok <- File.write(tmp, body),
           {:ok, uuid} <- Roki.Media.store(tmp, folder: @folder, filename: file) do
        remember(key, uuid)
        {:ok, Roki.Media.url(uuid)}
      else
        {:ok, %{status: status}} -> {:error, {:source, status}}
        {:error, reason} -> {:error, reason}
        other -> {:error, other}
      end
    after
      File.rm(tmp)
    end
  end

  defp remember(key, uuid) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Roki.Repo.query!(
      "insert into roki_pictures (key, file_uuid, inserted_at) values ($1, $2, $3) on conflict (key) do update set file_uuid = excluded.file_uuid",
      [key, bin, now]
    )

    :ets.insert(@table, {key, uuid})
    :ok
  end

  @doc """
  Hold a picture named by its source address, fetching it when the site does not yet: `:ok`
  when it is held, `:skip` for an address the site keeps no copies of, else `{:error, reason}`.
  """
  def hold(url) when is_binary(url) do
    case key(url) do
      nil ->
        :skip

      key ->
        case :ets.lookup(@table, key) do
          [_] -> :ok
          [] -> with {:ok, _} <- ensure(short(key)), do: :ok
        end
    end
  end

  def hold(_), do: :skip

  @doc "How many pictures the site holds."
  def count, do: :ets.info(@table, :size)
end
