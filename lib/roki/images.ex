defmodule Roki.Images do
  @moduledoc """
  TMDB's pictures, kept here. A poster is drawn on every page that lists the title, and
  every browser was fetching it from TMDB's image servers each time; now a page names
  `/img/w342/abc.jpg` instead, the first request fetches that picture from TMDB and keeps it
  on disk (`dir/0`, in the data that survives a container), and every later one is a file.

  `local/1` turns a TMDB image URL into the site's own address and leaves any other URL alone,
  so a page need not know where a picture came from.
  """

  @tmdb "https://image.tmdb.org/t/p/"
  @sizes ~w(w92 w185 w300 w342 w500 w780 w1280 original)

  @doc "Where the pictures are kept: beside laev's accounts, in the data that survives a container."
  def dir, do: Application.get_env(:roki, :images_dir) || Path.join(System.user_home!(), "roki-images")

  @doc "The sizes TMDB serves and this site keeps."
  def sizes, do: @sizes

  @doc "A TMDB image URL as the site's own address (`/img/w342/abc.jpg`); anything else as it is."
  def local(@tmdb <> rest) do
    case String.split(rest, "/", parts: 2) do
      [size, file] when size in @sizes -> if valid_file?(file), do: "/img/#{size}/#{file}", else: @tmdb <> rest
      _ -> @tmdb <> rest
    end
  end

  def local(other), do: other

  @doc "The file for a picture, fetched from TMDB and kept when it is not here yet: `{:ok, path}` or `{:error, reason}`."
  def file(size, file) do
    cond do
      size not in @sizes -> {:error, :bad_size}
      not valid_file?(file) -> {:error, :bad_name}
      true -> fetch(size, file)
    end
  end

  # TMDB names a picture by a short token and an extension; nothing else is a picture here.
  defp valid_file?(file), do: Regex.match?(~r/^[A-Za-z0-9]{1,64}\.(jpg|jpeg|png|webp)$/, file)

  defp fetch(size, file) do
    path = Path.join([dir(), size, file])

    if File.regular?(path) do
      {:ok, path}
    else
      File.mkdir_p!(Path.dirname(path))
      tmp = path <> ".#{System.unique_integer([:positive])}.part"

      case Req.get(@tmdb <> size <> "/" <> file, retry: false, receive_timeout: 20_000, decode_body: false) do
        {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) > 0 ->
          File.write!(tmp, body)
          File.rename!(tmp, path)
          {:ok, path}

        {:ok, %{status: status}} ->
          {:error, {:tmdb, status}}

        {:error, reason} ->
          {:error, reason}
      end
    end
  rescue
    e -> {:error, e}
  end

  @doc "The content type of a kept picture, by its name."
  def content_type(file) do
    cond do
      String.ends_with?(file, ".png") -> "image/png"
      String.ends_with?(file, ".webp") -> "image/webp"
      true -> "image/jpeg"
    end
  end
end
