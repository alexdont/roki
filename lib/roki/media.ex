defmodule Roki.Media do
  @moduledoc """
  The site's files in PhoenixKit's media library: the pictures fetched from TMDB and
  MyAnimeList (`Roki.Images`) and the profile banners (`Roki.Profile`), each in a folder of
  its own under "roki", served by PhoenixKit's file route under a signed address.

  A picture the site fetched belongs to the site's owner (the account `Roki.Keys` names);
  a banner to the user who uploaded it.
  """

  alias PhoenixKit.Modules.Storage
  alias PhoenixKit.Modules.Storage.URLSigner

  @root "roki"

  @doc "The account the site's own files belong to: the owner of the site's keys, or nil when none is set."
  def owner_uuid do
    case Roki.Keys.config() do
      %{owner_uuid: uuid} when is_binary(uuid) -> uuid
      _ -> nil
    end
  end

  @doc """
  Put a file into the media library: `store(path, folder: "TMDB pictures", user: uuid,
  filename: "abc.jpg", mime: "image/jpeg")`. `{:ok, file_uuid}` or `{:error, reason}`. A file
  the same account already has (same bytes) is not stored twice.
  """
  def store(path, opts) when is_binary(path) and is_list(opts) do
    user = Keyword.get(opts, :user) || owner_uuid()
    filename = Keyword.get(opts, :filename) || Path.basename(path)
    ext = filename |> Path.extname() |> String.trim_leading(".") |> String.downcase()
    mime = Keyword.get(opts, :mime) || mime(ext)

    with true <- is_binary(user) || {:error, :no_owner},
         {:ok, data} <- File.read(path),
         checksum = :crypto.hash(:sha256, data) |> Base.encode16(case: :lower),
         {:ok, file} <- stored(Storage.store_file_in_buckets(path, "image", user, checksum, ext, filename, mime_type: mime)) do
      with folder when is_binary(folder) <- folder(Keyword.get(opts, :folder)),
           do: Storage.attach_file_to_folder(file, folder)

      {:ok, file.uuid}
    end
  rescue
    e -> {:error, e}
  end

  defp stored({:ok, file}), do: {:ok, file}
  defp stored({:ok, file, :duplicate}), do: {:ok, file}
  defp stored(other), do: other

  @doc "The address a media file is served at (its original)."
  def url(file_uuid, variant \\ "original") when is_binary(file_uuid), do: URLSigner.signed_url(file_uuid, variant)

  @doc "Whether a value is a media file's uuid (as against a file name of the old kind)."
  def uuid?(value), do: is_binary(value) and match?({:ok, _}, Ecto.UUID.cast(value))

  @doc """
  The folder `name` under the site's "#{@root}" folder in the media library, made when it is
  not there; nil when there is no name. Remembered once found.
  """
  def folder(nil), do: nil

  def folder(name) when is_binary(name) do
    case :persistent_term.get({__MODULE__, :folder, name}, nil) do
      nil ->
        with root when is_binary(root) <- find_or_make(@root, nil),
             uuid when is_binary(uuid) <- find_or_make(name, root) do
          :persistent_term.put({__MODULE__, :folder, name}, uuid)
          uuid
        else
          _ -> nil
        end

      uuid ->
        uuid
    end
  rescue
    _ -> nil
  end

  defp find_or_make(name, parent) do
    case Enum.find(Storage.list_folders(parent, nil, []), &(&1.name == name)) do
      %{uuid: uuid} ->
        uuid

      nil ->
        case Storage.create_folder(%{name: name, parent_uuid: parent}) do
          {:ok, %{uuid: uuid}} -> uuid
          _ -> nil
        end
    end
  end

  defp mime("png"), do: "image/png"
  defp mime("webp"), do: "image/webp"
  defp mime("gif"), do: "image/gif"
  defp mime(_), do: "image/jpeg"
end
