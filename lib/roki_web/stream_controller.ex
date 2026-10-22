defmodule RokiWeb.StreamController do
  @moduledoc """
  Serves what laev's remuxer writes to disk — the HLS playlist, its segments, and the
  subtitle tracks pulled out of the release — to the player, and only to a signed-in user.

  `/stream/:id/:file`. `:id` is the remux's 16-hex content hash (`Laev.Remux.valid_id?/1`)
  and `:file` must match a short whitelist of the names ffmpeg produces, so neither can
  point outside the remux directory. A segment that is not on disk yet answers 404, which
  hls.js simply retries while ffmpeg catches up.
  """
  use RokiWeb, :controller

  # The plain playlist, the multi-audio master and its per-rendition playlists and segments
  # (ffmpeg names renditions s_0, s_Japanese …), single-audio segments, and subtitle tracks:
  # the ones in the release (sub0.vtt) and ones fetched from a provider (ext-fr.vtt).
  @allowed ~r/^(playlist\.m3u8|index\.m3u8|master\.m3u8|s_[A-Za-z0-9]+\.m3u8|seg\d{5}\.ts|s_[A-Za-z0-9]+_\d{5}\.ts|sub\d+\.vtt|ext-[a-z]{2,3}(?:-\d)?\.vtt)$/

  def file(conn, %{"id" => id, "file" => file}) do
    cond do
      is_nil(conn.assigns[:phoenix_kit_current_user]) ->
        send_resp(conn, 401, "sign in to watch")

      not (Laev.Remux.valid_id?(id) and file =~ @allowed) ->
        send_resp(conn, 400, "bad request")

      true ->
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
