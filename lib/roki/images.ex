defmodule Roki.Images do
  @moduledoc """
  Pictures from elsewhere — TMDB's posters, backdrops and stills, MyAnimeList's anime
  pictures — kept in PhoenixKit's media library (`Roki.Media`, folder "roki / Pictures") and
  served from there.

  One file per picture, whatever sizes pages ask for: TMDB's picture is fetched once at a
  size big enough for every page (780 px across for a poster or a still, 1280 for a backdrop),
  the library makes its smaller variants of it, and a page asking for a small size is given
  the smallest variant that is at least as wide — a missing variant is stood in for by a
  bigger one until it is made.

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
    {:ok, %{}}
  end

  # A picture is fetched once however many pages ask for it at the same time, and by a task of
  # its own: a browser that gives up on the request (the page swapped the picture's address, the
  # tab scrolled on) must not kill the fetch half-way and leave the picture neither held nor
  # lost, which is what left posters grey until the page was reloaded.
  @impl true
  def handle_call({:fetch, key, url}, from, state) do
    case state do
      %{^key => waiting} ->
        {:noreply, Map.put(state, key, [from | waiting])}

      _ ->
        server = self()

        Task.start(fn ->
          result =
            try do
              fetch(key, url)
            rescue
              e -> {:error, e}
            end

          send(server, {:fetched, key, result})
        end)

        {:noreply, Map.put(state, key, [from])}
    end
  end

  @impl true
  def handle_info({:fetched, key, result}, state) do
    {waiting, state} = Map.pop(state, key, [])
    for from <- waiting, do: GenServer.reply(from, result)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  defp fetch_once(key, url) do
    GenServer.call(__MODULE__, {:fetch, key, url}, 30_000)
  catch
    :exit, _ -> {:error, :timeout}
  end

  # Every picture held, into memory: a few thousand small rows. `held_at` 0: long ago.
  defp load do
    %{rows: rows} = Roki.Repo.query!("select key, file_uuid from roki_pictures")
    for [key, uuid] <- rows, do: :ets.insert(@table, {key, Ecto.UUID.load!(uuid), 0})
    :ok
  rescue
    _ -> :ok
  end

  # The library makes a picture's smaller sizes a little after the picture is stored, and asked
  # for a size it has not made yet (with nothing smaller to stand in) it answers a grey
  # placeholder — a 200, which a browser then shows as the poster until the page is reloaded.
  # So for its first while a picture is served as the original, which is there from the start.
  @settle_s 120

  defp variant_now(url, held_at) do
    if System.os_time(:second) - held_at < @settle_s, do: "original", else: variant_for(url)
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
          [{_, uuid, held_at}] -> Roki.Media.url(uuid, variant_now(url, held_at))
          [] -> "/img/" <> short(url)
        end
    end
  rescue
    _ -> url
  end

  def local(other), do: other

  # The key of a picture the site keeps copies of: the picture, whatever size was asked for —
  # `image.tmdb.org/abc.jpg` for any `image.tmdb.org/t/p/<size>/abc.jpg`.
  @doc false
  def key(@tmdb <> rest) do
    case String.split(rest, "/", parts: 2) do
      [size, file] when size in @sizes -> if file?(file), do: "image.tmdb.org/" <> file
      _ -> nil
    end
  end

  def key(@mal <> rest), do: if(mal_path?(rest), do: "cdn.myanimelist.net/images/" <> rest)
  def key(_), do: nil

  # The short form a `/img/` address carries: the size asked for stays in it, so the fetch
  # knows whether this is a poster or a backdrop.
  defp short(@tmdb <> rest), do: rest
  defp short(@mal <> rest), do: "mal/" <> rest

  # The library's variant for the size a page asked for: the smallest that is at least as wide,
  # else the original. A MyAnimeList picture is one size; a page gets its original.
  @doc false
  def variant_for(@tmdb <> rest) do
    case String.split(rest, "/", parts: 2) do
      ["original", _] -> "original"
      ["w" <> n, _] -> variant_at_least(String.to_integer(n))
      _ -> "original"
    end
  end

  def variant_for(_url), do: "original"

  defp variant_at_least(width) do
    dimensions()
    |> Enum.filter(fn {_name, w} -> is_integer(w) and w >= width end)
    |> Enum.min_by(fn {_name, w} -> w end, fn -> {"original", nil} end)
    |> elem(0)
  end

  # The enabled variants of the default set, widest last, remembered for an hour.
  defp dimensions do
    case :persistent_term.get({__MODULE__, :dimensions}, nil) do
      {at, dims} when is_integer(at) ->
        if System.os_time(:second) - at < 3600, do: dims, else: read_dimensions()

      _ ->
        read_dimensions()
    end
  end

  defp read_dimensions do
    dims =
      try do
        for d <- PhoenixKit.Modules.Storage.list_dimensions_for_type("image"), d.enabled, d.name != "original", is_integer(d.width), do: {d.name, d.width}
      rescue
        _ -> []
      end

    :persistent_term.put({__MODULE__, :dimensions}, {System.os_time(:second), dims})
    dims
  end

  # The size a picture is fetched at, once, for every page: a backdrop at 1280 across, a
  # poster or a still at 780.
  defp master(@tmdb <> rest) do
    case String.split(rest, "/", parts: 2) do
      [size, file] when size in ["w1280", "original"] -> @tmdb <> "w1280/" <> file
      [_size, file] -> @tmdb <> "w780/" <> file
    end
  end

  defp master(url), do: url

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
          [{_, uuid, held_at}] -> {:ok, Roki.Media.url(uuid, variant_now(source_url, held_at))}
          [] -> with {:ok, uuid} <- fetch_once(key, master(source_url)), do: {:ok, Roki.Media.url(uuid, "original")}
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
        {:ok, uuid}
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

    :ets.insert(@table, {key, uuid, System.os_time(:second)})
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
