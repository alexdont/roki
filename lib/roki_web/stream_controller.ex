defmodule RokiWeb.StreamController do
  @moduledoc """
  Serves what laev's remuxer writes to disk — the HLS playlist, its segments, and the
  subtitle tracks pulled out of the release — to the player, and only to a signed-in user.

  `/stream/:id/:file`. `:id` is the remux's 16-hex content hash (`Laev.Remux.valid_id?/1`)
  and `:file` must match a short whitelist of the names ffmpeg produces, so neither can
  point outside the remux directory. A segment that is not on disk yet answers 404, which
  hls.js simply retries while ffmpeg catches up.

  `?from=1800` names the part of a direct conversion (one begun 1800 s in, see
  `Roki.Direct`) a playlist or subtitle piece is made for; the part's own files carry it in
  their names (`media-1800.mp4`).

  `/stream/t/:token/:id/:file` is the same under a signed token (`RokiWeb.StreamToken`): the
  address the player loads, so that an AirPlay receiver — which fetches the playlist and all
  under it by itself, with no cookie — gets the same files, as the account the token names.
  """
  use RokiWeb, :controller

  # The plain playlist, the multi-audio master and its per-rendition playlists and segments
  # (ffmpeg names renditions s_0, s_Japanese …), single-audio segments, and subtitle tracks:
  # the ones in the release (sub0.vtt) and ones fetched from a provider (ext-fr.vtt). A direct
  # conversion's files, with the part in the name (media-1800.mp4, audio0-1800.mp4, sub0-1800.vtt).
  @allowed ~r/^(playlist\.m3u8|media(?:-\d+)?\.mp4|video\.m3u8|audio\d\.m3u8|audio\d(?:-\d+)?\.mp4|(?:sub\d+|ext-[a-z]{2,3}(?:-(?:\d|os\d{1,10}))?)(?:\.m3u8|\.\d+\.vtt)|index\.m3u8|master\.m3u8|s_[A-Za-z0-9]+\.m3u8|seg\d{5}\.ts|s_[A-Za-z0-9]+_\d{5}\.ts|sub\d+(?:-\d+)?\.vtt|ext-[a-z]{2,3}(?:-(?:\d|os\d{1,10}))?\.vtt)$/

  def file(conn, %{"id" => id, "file" => file} = params) do
    case conn.assigns[:phoenix_kit_current_user] do
      %{uuid: uuid} when is_binary(uuid) -> checked(conn, uuid, id, file, params)
      _ -> send_resp(conn, 401, "sign in to watch")
    end
  end

  def signed(conn, %{"token" => token, "id" => id, "file" => file} = params) do
    case RokiWeb.StreamToken.verify(token, id) do
      {:ok, uuid} -> checked(conn, uuid, id, file, params)
      :error -> send_resp(conn, 401, "this link has expired")
    end
  end

  defp checked(conn, uuid, id, file, params) do
    if Laev.Remux.valid_id?(id) and file =~ @allowed do
      Laev.Remux.touch(id)
      Roki.Direct.touch(id)
      serve(assign(conn, :stream_uuid, uuid), id, part(params["from"]), file)
    else
      send_resp(conn, 400, "bad request")
    end
  end

  # The part asked for, in seconds: a whole number, else the one from the start.
  defp part(from) when is_binary(from) do
    case Integer.parse(from) do
      {n, ""} when n > 0 and n < 1_000_000 -> n
      _ -> 0
    end
  end

  defp part(_), do: 0

  # A conversion that copied the video (`Roki.Direct`) is one MP4 read by byte ranges, under a
  # playlist made from what is written so far; laev's are files on disk.
  defp serve(conn, id, part, "playlist.m3u8" = file) do
    cond do
      Roki.Direct.direct?(id) ->
        playlist(conn, Roki.Direct.playlist(id, part, prefer(conn, id)))

      Laev.Remux.entry_playlist(id) == "master.m3u8" ->
        case File.read(Path.join(Laev.Remux.dir(id), "master.m3u8")) do
          {:ok, content} ->
            playlist(
              conn,
              Roki.Direct.tidy_master(content, prefer(conn, id), Roki.Subs.tracks(id))
            )

          _ ->
            send_resp(conn, 404, "not ready")
        end

      # laev's plain playlist: under a master when there are subtitles to list, else as it is.
      File.exists?(Path.join(Laev.Remux.dir(id), "index.m3u8")) and Roki.Subs.tracks(id) != [] ->
        playlist(conn, Roki.Direct.wrap_media("index.m3u8", Roki.Subs.tracks(id)))

      true ->
        serve_file(conn, id, file)
    end
  end

  # A subtitle track as HLS renditions: its playlist (`sub0.m3u8`) and its pieces (`sub0.12.vtt`).
  defp serve(conn, id, part, "sub" <> _ = file), do: subtitle_or_file(conn, id, part, file)
  defp serve(conn, id, part, "ext-" <> _ = file), do: subtitle_or_file(conn, id, part, file)

  # The media playlists behind a direct master: the video's, and one per audio track.
  defp serve(conn, id, part, "video.m3u8"), do: direct_playlist(conn, id, part, "media")

  defp serve(conn, id, part, "audio" <> _ = file) do
    if String.ends_with?(file, ".m3u8"),
      do: direct_playlist(conn, id, part, String.replace_suffix(file, ".m3u8", "")),
      else: direct_file(conn, id, file, "audio/mp4")
  end

  defp serve(conn, id, _part, "media" <> _ = file), do: direct_file(conn, id, file, "video/mp4")

  defp serve(conn, id, _part, file), do: serve_file(conn, id, file)

  defp playlist(conn, content) do
    conn
    |> put_resp_content_type(content_type("playlist.m3u8"))
    |> put_resp_header("cache-control", "no-store")
    |> send_resp(200, content)
  end

  # The audio to start with, in order: the account's language (laev's setting), then the title's
  # original language, when the release has either.
  defp prefer(conn, id), do: [account_language(conn), Roki.Direct.original_language(id)]

  defp account_language(conn) do
    case conn.assigns[:stream_uuid] do
      uuid when is_binary(uuid) -> Roki.Laev.run(uuid, fn -> Laev.Config.lang() end)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # The whole file (`sub0.vtt`, `sub0-1800.vtt`, what the page draws from) is served as it is;
  # its playlist and pieces (`sub0.m3u8`, `sub0.12.vtt`) are made on request.
  defp subtitle_or_file(conn, id, part, file) do
    if String.ends_with?(file, ".vtt") and not Regex.match?(~r/\.\d+\.vtt$/, file),
      do: serve_file(conn, id, file),
      else: subtitle(conn, id, part, file)
  end

  defp subtitle(conn, id, part, file) do
    content =
      cond do
        String.ends_with?(file, ".m3u8") ->
          Roki.Subs.playlist(id, String.replace_suffix(file, ".m3u8", ""), part)

        true ->
          [_, base, k] = Regex.run(~r/^(.+)\.(\d+)\.vtt$/, file)
          Roki.Subs.segment(id, base, String.to_integer(k), part)
      end

    if content do
      conn
      |> put_resp_content_type(content_type(file))
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, content)
    else
      send_resp(conn, 404, "not ready")
    end
  end

  defp direct_playlist(conn, id, part, base) do
    if Roki.Direct.direct?(id) do
      conn
      |> put_resp_content_type(content_type(base <> ".m3u8"))
      |> put_resp_header("cache-control", "no-store")
      |> send_resp(200, Roki.Direct.media_playlist(id, part, base))
    else
      send_resp(conn, 404, "not ready")
    end
  end

  defp direct_file(conn, id, name, type) do
    path = Roki.Direct.file(id, name)

    if File.regular?(path),
      do: RokiWeb.RangeFile.send(conn, path, type),
      else: send_resp(conn, 404, "not ready")
  end

  defp serve_file(conn, id, file) do
    path = Path.join(Laev.Remux.dir(id), resolve(id, file))

    if File.regular?(path) do
      conn
      |> put_resp_content_type(content_type(file))
      |> put_resp_header("cache-control", cache_control(file))
      |> send_file(200, path)
    else
      send_resp(conn, 404, "not ready")
    end
  end

  # `playlist.m3u8` is what the page asks for; which file that is (a single playlist, or the
  # master of a multi-audio release) is only known once ffmpeg has looked at the file.
  defp resolve(id, "playlist.m3u8"), do: Laev.Remux.entry_playlist(id)
  defp resolve(_id, file), do: file

  defp content_type(file) do
    cond do
      String.ends_with?(file, ".m3u8") -> "application/vnd.apple.mpegurl"
      String.ends_with?(file, ".vtt") -> "text/vtt"
      true -> "video/mp2t"
    end
  end

  # A playlist grows while ffmpeg works, so it is never cached; a segment never changes.
  defp cache_control(file),
    do: if(String.ends_with?(file, ".m3u8"), do: "no-store", else: "private, max-age=3600")
end
