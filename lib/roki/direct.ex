defmodule Roki.Direct do
  @moduledoc """
  A conversion that leaves the video alone.

  A browser that can decode the release's video itself (HEVC on anything Apple makes and on a
  desktop with a hardware decoder, AV1 on most) only needs the container changed and the audio
  put into AAC: ffmpeg copies the video into one fragmented MP4 that grows while it plays, and
  the playlist served for it names byte ranges of that file. That costs the server a fraction
  of a core instead of the five a re-encode takes, and it is the only form of HEVC Safari
  plays through HLS: Safari refuses the segments ffmpeg's own HLS muxer makes of the same
  video (tested 2026-10-26 on iOS 18.7 and Safari 26), and plays the MP4 muxer's fragments.

  The output lives in laev's remux directory under an id of the same shape, so the stream
  route, the subtitle files written next to it, and laev's housekeeping all apply unchanged.

  A release with one audio track becomes one file, `media.mp4`, under `playlist.m3u8`. One
  with several becomes a video-only `media.mp4` and one `audioN.mp4` per track, and
  `playlist.m3u8` is then a master playlist naming each track as a rendition the player can
  switch to (`video.m3u8`, `audioN.m3u8` are the media playlists), as laev does with TS.
  """
  use GenServer
  require Logger

  @registry Roki.Direct.Registry
  @supervisor Roki.Direct.Supervisor
  # Nobody asking for the stream this long ends the conversion; what is written stays as a cache.
  @idle_ms 10 * 60 * 1000

  @doc "Whether this device can decode the release's video (`caps` from the browser), by its name."
  def wanted?(source, caps), do: decodable?(codec_of(source), caps)

  @doc """
  Whether a codec, as a release name or ffprobe says it (`"hevc"`, `"x265"`, `"av1"`, …),
  is one the browser that sent `caps` decodes itself — never H.264, which laev copies already.
  """
  def decodable?(codec, caps) when is_binary(codec) and is_map(caps) do
    case String.downcase(codec) do
      c when c in ["hevc", "h265", "x265"] -> Map.get(caps, :hevc) == true
      "av1" -> Map.get(caps, :av1) == true
      "vp9" -> Map.get(caps, :vp9) == true
      _ -> false
    end
  end

  def decodable?(_codec, _caps), do: false

  defp codec_of({source, _stream}), do: codec_of(source)
  defp codec_of(%{codec: codec}), do: codec
  defp codec_of(_), do: nil

  @doc """
  The browser's decoding abilities as the page reported them on connecting
  (`%{"hevc" => true, …}`), as a map of atoms. Anything missing is "no". `uhd` is whether
  it decodes one of those codecs at 4K.
  """
  def caps(params) when is_map(params) do
    for key <- [:hevc, :av1, :vp9, :uhd], into: %{} do
      {key, Map.get(params, Atom.to_string(key)) == true}
    end
  end

  def caps(_), do: %{}

  @doc """
  Start converting (or join the conversion of) `stream` for a browser with `caps`: `{:ok, id}`
  when its video is one that browser decodes, `:skip` when it is not (laev's path then applies),
  `{:error, :unreachable}` when the file could not be read.
  """
  def start(stream, caps) do
    cond do
      not is_binary(stream[:url]) ->
        :skip

      not Enum.any?(caps || %{}, fn {_, v} -> v == true end) ->
        :skip

      true ->
        case probe(stream.url) do
          [] ->
            {:error, :unreachable}

          streams ->
            if decodable?(codec_in(streams, "video"), caps),
              do: launch(id_for(stream), stream.url, streams),
              else: :skip
        end
    end
  end

  defp launch(id, url, streams) do
    Laev.Remux.sweep()

    cond do
      running?(id) ->
        {:ok, id}

      done?(id) ->
        File.touch(dir(id))
        {:ok, id}

      true ->
        File.rm_rf(dir(id))
        spec = {__MODULE__, id: id, url: url, streams: streams, dir: dir(id)}

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, _} -> {:ok, id}
          {:error, {:already_started, _}} -> {:ok, id}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  defp probe(url) do
    task = Task.async(fn -> Laev.Remux.Worker.probe_streams(url) end)

    case Task.yield(task, 30_000) || Task.shutdown(task, :brutal_kill) do
      {:ok, streams} when is_list(streams) -> streams
      _ -> []
    end
  end

  defp codec_in(streams, kind),
    do: Enum.find_value(streams, "", fn s -> if s.kind == kind, do: s.codec end)

  # Keyed like laev's remux (name and size), under a different hash, so the two never share a
  # directory: laev's holds TS segments, this one an MP4. (v2: HEVC with its parameter sets.)
  defp id_for(stream) do
    :sha256
    |> :crypto.hash("direct:v4:#{stream[:filename]}-#{stream[:filesize]}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc "Where this conversion's files are (laev's remux directory, same id shape)."
  def dir(id), do: Laev.Remux.dir(id)

  @doc "Whether this id is one of these conversions (an MP4, not TS segments)."
  def direct?(id), do: File.exists?(media(id))

  def media(id), do: file(id, "media.mp4")

  @doc "A file of this conversion by name (`media.mp4`, `audio1.mp4`)."
  def file(id, name), do: Path.join(dir(id), name)

  @doc """
  The audio tracks of a conversion, as written at its start: `[%{file: "audio0", lang: "kor",
  name: "Korean"}]`. One entry (or none) means the audio is inside `media.mp4`.
  """
  def tracks(id) do
    with {:ok, json} <- File.read(file(id, "audio.json")),
         {:ok, list} when is_list(list) <- Jason.decode(json, keys: :atoms) do
      list
    else
      _ -> []
    end
  end

  defp multi?(id), do: length(tracks(id)) > 1

  defp running?(id), do: Registry.lookup(@registry, id) != []
  defp done?(id), do: File.exists?(Path.join(dir(id), "done"))

  @doc "Ids converting right now."
  def running, do: Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])

  @doc "The stream is being watched: keep converting."
  def touch(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> GenServer.cast(pid, :touch)
      [] -> :ok
    end
  end

  @doc "End the conversion (what is written stays)."
  def stop(id) when is_binary(id) do
    case Registry.lookup(@registry, id) do
      [{pid, _}] -> DynamicSupervisor.terminate_child(@supervisor, pid)
      [] -> :ok
    end
  end

  def stop(_), do: :ok

  @doc "Enough is written to start playing: two fragments of every file, or all of it."
  def ready?(id) do
    done?(id) or
      (enough?(media(id)) and
         (not multi?(id) or Enum.all?(tracks(id), &enough?(file(id, &1.file <> ".mp4")))))
  end

  defp enough?(path) do
    case Roki.Fmp4.scan(path) do
      %{fragments: [_, _ | _]} -> true
      _ -> false
    end
  end

  @doc """
  What the player loads: the media playlist of `media.mp4` when the audio is in it, else a
  master playlist with the video and one rendition per audio track, the one in `prefer`
  (the account's language, as `"ko"`) the default when there is one.
  """
  def playlist(id, prefer \\ nil) do
    if multi?(id),
      do: master_playlist(tracks(id), bandwidth(id), prefer),
      else: media_playlist(id, "media.mp4")
  end

  @doc """
  The master playlist of a multi-audio conversion: every track as a switchable rendition of
  one group. The default is the first track in the preferred language, else the first track
  (the player remembers the one picked and switches to it). Without a CODECS attribute on
  purpose — hls.js on Firefox stops at the HEVC string.
  """
  def master_playlist(tracks, bandwidth, prefer \\ nil) do
    chosen = default_track(tracks, prefer)

    renditions =
      tracks
      |> Enum.with_index()
      |> Enum.map(fn {t, i} ->
        lang = if t.lang != "", do: ~s(,LANGUAGE="#{Roki.Watch.short_code(t.lang)}"), else: ""
        default = if i == chosen, do: "YES", else: "NO"

        ~s(#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="#{t.name}"#{lang},DEFAULT=#{default},AUTOSELECT=YES,URI="#{t.file}.m3u8")
      end)

    Enum.join(
      ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"] ++
        renditions ++
        [~s(#EXT-X-STREAM-INF:BANDWIDTH=#{bandwidth},AUDIO="aud"), "video.m3u8"],
      "\n"
    ) <> "\n"
  end

  # The index of the first track in the preferred language, else 0.
  defp default_track(tracks, prefer) do
    with p when is_binary(p) and p != "" <- prefer,
         i when is_integer(i) <-
           Enum.find_index(tracks, &(&1.lang != "" and Roki.Watch.short_code(&1.lang) == p)) do
      i
    else
      _ -> 0
    end
  end

  @doc """
  laev's master playlist for a multi-audio TS conversion, made fit for the player: ffmpeg
  names every rendition `audio_N`, and tracks of one language all point at one rendition
  file (laev names the variants by language, so five Russian dubs become one `s_Rus`), so
  the list is cut down to one entry per file, named by its language, with the preferred
  language the default.
  """
  def tidy_master(content, prefer \\ nil) do
    lines = String.split(content, "\n")
    media = Enum.filter(lines, &String.starts_with?(&1, "#EXT-X-MEDIA:TYPE=AUDIO"))

    tracks =
      media
      |> Enum.map(fn line -> %{uri: attr(line, "URI"), lang: attr(line, "LANGUAGE") || ""} end)
      |> Enum.uniq_by(& &1.uri)
      |> Enum.with_index()
      |> Enum.map(fn {t, n} -> Map.merge(t, %{index: n, name: track_name(t.lang, n), file: t.uri}) end)
      |> unique_names()

    if tracks == [] do
      content
    else
      chosen = default_track(tracks, prefer)

      renditions =
        tracks
        |> Enum.with_index()
        |> Enum.map(fn {t, i} ->
          lang = if t.lang != "", do: ~s(,LANGUAGE="#{Roki.Watch.short_code(t.lang)}"), else: ""
          default = if i == chosen, do: "YES", else: "NO"
          ~s(#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_aud",NAME="#{t.name}"#{lang},DEFAULT=#{default},AUTOSELECT=YES,URI="#{t.uri}")
        end)

      {before, after_media} = Enum.split_while(lines, &(not String.starts_with?(&1, "#EXT-X-MEDIA:TYPE=AUDIO")))
      rest = Enum.reject(after_media, &String.starts_with?(&1, "#EXT-X-MEDIA:TYPE=AUDIO"))
      Enum.join(before ++ renditions ++ rest, "\n")
    end
  end

  defp attr(line, name) do
    case Regex.run(~r/(?:^|,)#{name}="([^"]*)"/, line) do
      [_, v] -> v
      _ -> nil
    end
  end

  # The video's rate so far, plus the audio, for the master playlist's required figure.
  defp bandwidth(id) do
    case Roki.Fmp4.scan(media(id)) do
      %{fragments: [_ | _] = fs} ->
        bytes = Enum.sum(Enum.map(fs, & &1.size))
        seconds = Enum.sum(Enum.map(fs, & &1.duration))
        if seconds > 0, do: trunc(bytes * 8 / seconds) + 256_000, else: 10_000_000

      _ ->
        10_000_000
    end
  end

  @doc """
  The HLS media playlist of what is written of one file so far: one byte range per fragment,
  ended once ffmpeg has finished.
  """
  def media_playlist(id, name) do
    case Roki.Fmp4.scan(file(id, name)) do
      %{init: init, fragments: fragments} ->
        # Fragments end at keyframes, so their length is the release's own; the target is kept
        # high enough that it seldom has to change once the player has read it.
        longest = fragments |> Enum.map(& &1.duration) |> Enum.max(fn -> 10 end)

        head = [
          "#EXTM3U",
          "#EXT-X-VERSION:7",
          "#EXT-X-TARGETDURATION:#{max(ceil(longest), 10)}",
          "#EXT-X-MEDIA-SEQUENCE:0",
          "#EXT-X-PLAYLIST-TYPE:EVENT",
          "#EXT-X-INDEPENDENT-SEGMENTS",
          ~s(#EXT-X-MAP:URI="#{name}",BYTERANGE="#{init}@0")
        ]

        body =
          Enum.flat_map(fragments, fn f ->
            [
              "#EXTINF:#{:erlang.float_to_binary(f.duration * 1.0, decimals: 3)},",
              "#EXT-X-BYTERANGE:#{f.size}@#{f.offset}",
              name
            ]
          end)

        tail = if done?(id), do: ["#EXT-X-ENDLIST"], else: []
        Enum.join(head ++ body ++ tail, "\n") <> "\n"

      nil ->
        "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:EVENT\n"
    end
  end

  # ── the worker ────────────────────────────────────────────────────

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, id}})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    dir = Keyword.fetch!(opts, :dir)
    File.mkdir_p!(dir)
    streams = Keyword.fetch!(opts, :streams)
    subs = subtitle_tracks(streams)
    audios = audio_tracks(streams)
    File.write(Path.join(dir, "subs.json"), Jason.encode!(subs))
    File.write(Path.join(dir, "audio.json"), Jason.encode!(audios))

    # One shell runs the pipeline (see `command/5`); its children are ended with it.
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", command(Keyword.fetch!(opts, :url), dir, streams, audios, subs)]
      ])

    Process.send_after(self(), :idle_check, 60_000)

    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       dir: dir,
       port: port,
       last_error: "",
       touched: System.monotonic_time(:millisecond)
     }}
  end

  @impl true
  def handle_cast(:touch, state),
    do: {:noreply, %{state | touched: System.monotonic_time(:millisecond)}}

  @impl true
  def handle_info({port, {:exit_status, 0}}, %{port: port} = state) do
    File.write(Path.join(state.dir, "done"), "")
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning("direct #{state.id} ffmpeg exited #{status}: #{state.last_error}")
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({port, {:data, data}}, %{port: port} = state) do
    last = data |> String.split("\n", trim: true) |> List.last()
    {:noreply, %{state | last_error: last || state.last_error}}
  end

  def handle_info(:idle_check, state) do
    if System.monotonic_time(:millisecond) - state.touched > @idle_ms do
      {:stop, :normal, state}
    else
      Process.send_after(self(), :idle_check, 60_000)
      {:noreply, state}
    end
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) when is_port(port) do
    case Port.info(port, :os_pid) do
      {:os_pid, os_pid} ->
        System.cmd("pkill", ["-TERM", "-P", Integer.to_string(os_pid)])
        System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])

      _ ->
        :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Video copied as it is; audio copied when it is AAC already, else AAC stereo (what laev
  # does: a browser plays stereo regardless, and TrueHD 7.1 cannot be put in AAC as it is).
  # Fragments at keyframes, at least two seconds long, in the MP4 muxer's own form. One audio
  # track goes into `media.mp4` with the video; several each get their own `audioN.mp4`, so the
  # player can switch between them as HLS renditions.
  #
  # HEVC goes through MPEG-TS on the way: a release often keeps the parameter sets inside the
  # video rather than in the container, and an MP4 written straight from it has an empty `hvcC`
  # that nothing decodes. Read back from TS, ffmpeg's parser puts them where `hvc1` needs them.
  #
  # `delay_moov` holds the header back until the first fragment: the AAC decoder configuration
  # comes out of the TS stream with its first packet, and a header written before that has none,
  # which Safari refuses to decode (ffmpeg plays it anyway, so a local check does not show it).
  defp command(url, dir, streams, audios, subs) do
    video = codec_in(streams, "video")
    multi? = length(audios) > 1

    sub_outputs =
      Enum.flat_map(subs, fn s ->
        ["-map", "0:#{s.index}", "-c:s", "webvtt", "-f", "webvtt", Path.join(dir, "#{s.file}.vtt")]
      end)

    read = ~w(ffmpeg -nostdin -loglevel error -rw_timeout 20000000 -i) ++ [url]
    # The input's audio streams, in order, as `0:a:N`; `audios` lists them in that order.
    audio_maps = Enum.flat_map(0..(length(audios) - 1)//1, &["-map", "0:a:#{&1}"])
    mp4 = ~w(-movflags frag_keyframe+empty_moov+default_base_moof+delay_moov -min_frag_duration 2000000 -f mp4)

    # What makes each audio stream AAC (the Nth output audio stream, or all of them).
    to_aac = fn {a, _n}, spec ->
      if a.codec == "aac",
        do: ["-c:a#{spec}", "copy"],
        else: ["-c:a#{spec}", "aac", "-b:a#{spec}", "192k", "-ac#{spec}", "2"]
    end

    if video in ["hevc", "h265"] do
      # The TS carries the video and every audio track; the second ffmpeg splits them out.
      first =
        read ++ ~w(-map 0:v:0) ++ audio_maps ++ ~w(-sn -c:v copy) ++
          Enum.flat_map(Enum.with_index(audios), &to_aac.(&1, ":#{elem(&1, 1)}")) ++
          ~w(-f mpegts -) ++ sub_outputs

      second =
        ~w(ffmpeg -nostdin -loglevel error -f mpegts -i -) ++
          if multi? do
            ~w(-map 0:v:0 -c:v copy -tag:v hvc1) ++ mp4 ++ [Path.join(dir, "media.mp4")] ++
              Enum.flat_map(audios |> Enum.with_index(), fn {a, n} ->
                ~w(-map 0:a:#{n} -c:a copy -bsf:a aac_adtstoasc) ++ mp4 ++ [Path.join(dir, "#{a.file}.mp4")]
              end)
          else
            ~w(-map 0:v:0) ++
              if(audios != [], do: ~w(-map 0:a:0 -bsf:a aac_adtstoasc), else: []) ++
              ~w(-c copy -tag:v hvc1) ++ mp4 ++ [Path.join(dir, "media.mp4")]
          end

      shell(first) <> " | " <> shell(second)
    else
      if multi? do
        shell(
          read ++ ~w(-map 0:v:0 -sn -c:v copy) ++ mp4 ++ [Path.join(dir, "media.mp4")] ++
            Enum.flat_map(Enum.with_index(audios), fn {a, n} = pair ->
              ~w(-map 0:a:#{n}) ++ to_aac.(pair, "") ++ mp4 ++ [Path.join(dir, "#{a.file}.mp4")]
            end) ++ sub_outputs
        )
      else
        audio_args = if audios == [], do: [], else: to_aac.({hd(audios), 0}, "")

        shell(
          read ++ ~w(-map 0:v:0) ++ Enum.take(audio_maps, 2) ++ ~w(-sn -c:v copy) ++ audio_args ++
            mp4 ++ [Path.join(dir, "media.mp4")] ++ sub_outputs
        )
      end
    end
  end

  defp shell(args),
    do: Enum.map_join(args, " ", &("'" <> String.replace(&1, "'", "'\\''") <> "'"))

  @image_subs ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"]

  # The audio tracks in the file's order, named for the player's menu (`audio.json`).
  defp audio_tracks(streams) do
    streams
    |> Enum.filter(&(&1.kind == "audio"))
    |> Enum.with_index()
    |> Enum.map(fn {s, n} ->
      %{index: s.index, codec: s.codec, lang: String.trim(s.lang || ""), file: "audio#{n}", name: track_name(s.lang, n)}
    end)
    |> unique_names()
  end

  defp track_name(lang, n) do
    case String.trim(lang || "") do
      "" -> "Track #{n + 1}"
      l -> Roki.Watch.language(l)
    end
  end

  # Two tracks of one language (commentary, a second mix) are told apart by number.
  defp unique_names(tracks) do
    tracks
    |> Enum.group_by(& &1.name)
    |> Enum.flat_map(fn
      {_name, [one]} -> [one]
      {name, same} -> Enum.with_index(same, 1) |> Enum.map(fn {t, k} -> %{t | name: "#{name} #{k}"} end)
    end)
    |> Enum.sort_by(& &1.index)
  end

  # The same manifest laev's worker writes, so the subtitle list is read the same way.
  defp subtitle_tracks(streams) do
    streams
    |> Enum.filter(&(&1.kind == "subtitle" and &1.codec not in @image_subs))
    |> Enum.with_index()
    |> Enum.map(fn {s, n} -> %{index: s.index, lang: s.lang, file: "sub#{n}"} end)
  end
end
