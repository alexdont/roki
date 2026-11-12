defmodule Roki.Direct do
  @moduledoc """
  The site's use of the `direct` package (made from this module on 2026-11-12): a conversion
  that leaves the video alone — ffmpeg copies it into a fragmented MP4 that plays while it is
  written, for a browser that decodes the codec itself. What stays here is what is laev's or
  the site's: the output lives in laev's remux directory under an id of the same shape
  (`config :direct, dir: {Laev.Remux, :dir}`), so the stream route, the subtitle files written
  next to it and laev's housekeeping all apply unchanged; the subtitle tracks listed in a
  master come from `Roki.Subs`; and the title's original language is kept beside the
  conversion for the audio to start on.
  """

  @doc "Whether this device can decode the release's video (`caps` from the browser), by its name."
  def wanted?(source, caps), do: Direct.Caps.decodable?(codec_of(source), caps)

  defp codec_of({source, _stream}), do: codec_of(source)
  defp codec_of(%{codec: codec}), do: codec
  defp codec_of(_), do: nil

  @doc """
  Start converting (or join the conversion of) `stream` for a browser with `caps`, from
  `from` seconds in: `{:ok, id, part}`, `:skip` when the browser does not decode the video
  (laev's path then applies), `{:error, :unreachable}` when the file could not be read. Keyed
  like laev's remux (name and size) under a different hash, so the two never share a directory.
  """
  def start(stream, caps, from \\ 0) do
    if is_binary(stream[:url]) do
      Laev.Remux.sweep()

      Direct.start(stream.url,
        id: Direct.id_for(stream[:filename], stream[:filesize]),
        caps: caps,
        from: from
      )
    else
      :skip
    end
  end

  @doc """
  What the player loads for a part: the package's playlist with the site's subtitle tracks
  listed, the first of `prefer` (languages in order, `["en", "ko"]`) the release has as the
  default audio.
  """
  def playlist(id, part \\ 0, prefer \\ nil),
    do: Direct.playlist(id, part, prefer: prefer, subs: Roki.Subs.tracks(id, part))

  @doc "laev's master playlist for a multi-audio TS conversion, made fit for the player."
  def tidy_master(content, prefer \\ nil, subs \\ []),
    do: Direct.Playlist.tidy_master(content, prefer: prefer, subs: subs)

  @doc "laev's single-audio media playlist under a master, so subtitle renditions can ride along."
  defdelegate wrap_media(media_name, subs), to: Direct.Playlist

  @doc """
  Keep what the playlist needs to know of the title beside a conversion (laev's or this one's):
  its original language, the audio to start with when the account's language is not there.
  """
  def remember_title(id, ctx) when is_binary(id) do
    dir = Direct.dir(id)
    File.mkdir_p(dir)
    File.write(Path.join(dir, "title.json"), Jason.encode!(%{language: ctx[:language]}))
    :ok
  end

  def remember_title(_id, _ctx), do: :ok

  @doc "The title's original language (`\"ko\"`) as remembered at the start, or nil."
  def original_language(id) do
    with {:ok, json} <- File.read(Direct.file(id, "title.json")),
         {:ok, %{"language" => lang}} when is_binary(lang) and lang != "" <- Jason.decode(json) do
      lang
    else
      _ -> nil
    end
  end
end
