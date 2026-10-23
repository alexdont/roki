defmodule Roki.SubCache do
  @moduledoc """
  Subtitle files that cost a download from OpenSubtitles (a small daily quota on a free account),
  kept on disk so the same file is never fetched twice: by file id for the ones picked from the
  list, by title/episode/language for the one fetched automatically, and, per user, which files
  were picked for which title, so a reload puts them back without asking the service anything.

  Lives under the laev users directory (`_subs/`), which is in `data/`. A file's text is the same
  for everyone, so the file cache is shared; the picks are per user.
  """

  def dir, do: Path.join(Roki.Laev.base_dir(), "_subs")

  @doc "The WebVTT text of a downloaded OpenSubtitles file, if kept."
  def get_file(id) when is_integer(id) do
    case File.read(Path.join([dir(), "files", "#{id}.vtt"])) do
      {:ok, vtt} -> {:ok, vtt}
      _ -> :miss
    end
  end

  def put_file(id, vtt) when is_integer(id) do
    path = Path.join([dir(), "files", "#{id}.vtt"])
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, vtt)
  end

  @doc "What the automatic fetch found for a title, episode and language: `%{label, vtt}`."
  def get_auto(key) do
    with {:ok, body} <- File.read(auto_path(key)),
         {:ok, %{"label" => label, "vtt" => vtt}} <- Jason.decode(body) do
      {:ok, %{label: label, vtt: vtt}}
    else
      _ -> :miss
    end
  end

  def put_auto(key, %{label: label, vtt: vtt}) do
    path = auto_path(key)
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, Jason.encode!(%{label: label, vtt: vtt}))
  end

  defp auto_path(key) do
    name = :sha256 |> :crypto.hash(:erlang.term_to_binary(key)) |> Base.encode16(case: :lower)
    Path.join([dir(), "auto", binary_part(name, 0, 24) <> ".json"])
  end

  @doc "The files this user picked for a title: `[%{id, lang, release}]`."
  def picks(uuid, media) do
    with {:ok, body} <- File.read(picks_path(uuid)),
         {:ok, %{} = all} <- Jason.decode(body),
         list when is_list(list) <- all[media] do
      for %{"id" => id, "lang" => lang} = p <- list, is_integer(id) do
        %{id: id, lang: lang, release: p["release"]}
      end
    else
      _ -> []
    end
  end

  def add_pick(uuid, media, %{id: id} = pick) do
    all =
      with {:ok, body} <- File.read(picks_path(uuid)), {:ok, %{} = m} <- Jason.decode(body) do
        m
      else
        _ -> %{}
      end

    list = Enum.reject(all[media] || [], &(&1["id"] == id))
    entry = %{"id" => id, "lang" => pick.lang, "release" => pick.release}
    File.mkdir_p!(Path.dirname(picks_path(uuid)))
    File.write!(picks_path(uuid), Jason.encode!(Map.put(all, media, list ++ [entry])))
  end

  defp picks_path(uuid), do: Path.join(Roki.Laev.dir(uuid), "os-picks.json")
end
