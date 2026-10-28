defmodule Roki.Direct do
  @moduledoc """
  A conversion that leaves the video alone.

  A browser that can decode the release's video itself (H.264 everywhere, HEVC on anything
  Apple makes and on a desktop with a hardware decoder, AV1 on most) only needs the container
  changed and the audio put into AAC: ffmpeg copies the video into one fragmented MP4 that
  grows while it plays, and the playlist served for it names byte ranges of that file. That
  costs the server a fraction of a core instead of the five a re-encode takes, and it is the
  only form of HEVC Safari plays through HLS: Safari refuses the segments ffmpeg's own HLS
  muxer makes of the same video (tested 2026-10-26 on iOS 18.7 and Safari 26), and plays the
  MP4 muxer's fragments.

  The output lives in laev's remux directory under an id of the same shape, so the stream
  route, the subtitle files written next to it, and laev's housekeeping all apply unchanged.

  A release with one audio track becomes one file, `media.mp4`, under `playlist.m3u8`. One
  with several becomes a video-only `media.mp4` and one `audioN.mp4` per track, and
  `playlist.m3u8` is then a master playlist naming each track as a rendition the player can
  switch to (`video.m3u8`, `audioN.m3u8` are the media playlists), as laev does with TS.

  ## Parts

  Coming back to a film half-way through should not mean converting the half already seen:
  a conversion can begin at a position in the file (a *part*, named by that position:
  `media-1800.mp4`), and keeps the file's own clock, so its fragments carry the real times and
  a subtitle written for the whole film still fits. The playlist of a part lists only what the
  part has; the page knows where it starts (`start_at/2`) and asks for another part when the
  viewer seeks before it. A part from the beginning keeps the plain names.
  """
  use GenServer
  require Logger

  @registry Roki.Direct.Registry
  @supervisor Roki.Direct.Supervisor
  # Nobody asking for the stream this long ends the conversion; what is written stays as a cache.
  @idle_ms 10 * 60 * 1000
  # Closer to the beginning than this, a part is not worth it: the conversion runs far ahead of
  # playing, and the head is a few seconds' work.
  @min_part 60

  @doc "Whether this device can decode the release's video (`caps` from the browser), by its name."
  def wanted?(source, caps), do: decodable?(codec_of(source), caps)

  @doc """
  Whether a codec, as a release name or ffprobe says it (`"hevc"`, `"x265"`, `"av1"`, …),
  is one the browser that sent `caps` decodes itself. H.264 is, everywhere.
  """
  def decodable?(codec, caps) when is_binary(codec) and is_map(caps) do
    case String.downcase(codec) do
      c when c in ["h264", "x264", "avc", "avc1"] -> true
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
    for key <- [:hevc, :av1, :vp9, :uhd, :local], into: %{} do
      {key, Map.get(params, Atom.to_string(key)) == true}
    end
  end

  def caps(_), do: %{}

  @doc """
  Start converting (or join the conversion of) `stream` for a browser with `caps`, from
  `from` seconds in: `{:ok, id, part}` when its video is one that browser decodes — `part` is
  where the conversion serving it begins (0 for the whole file, which is reused when it is
  there already) —, `:skip` when it is not (laev's path then applies), `{:error, :unreachable}`
  when the file could not be read.
  """
  def start(stream, caps, from \\ 0) do
    if is_binary(stream[:url]) do
      id = id_for(stream)

      case streams(id, stream.url) do
        [] ->
          {:error, :unreachable}

        streams ->
          if decodable?(codec_in(streams, "video"), caps),
            do: launch(id, stream.url, streams, from),
            else: :skip
      end
    else
      :skip
    end
  end

  defp launch(id, url, streams, from) do
    Laev.Remux.sweep()
    part = part_for(id, from)

    cond do
      running?(id, part) ->
        {:ok, id, part}

      usable?(id, part) ->
        File.touch(dir(id))
        {:ok, id, part}

      true ->
        clear_part(id, part)
        spec = {__MODULE__, id: id, url: url, streams: streams, dir: dir(id), part: part}

        case DynamicSupervisor.start_child(@supervisor, spec) do
          {:ok, _} -> {:ok, id, part}
          {:error, {:already_started, _}} -> {:ok, id, part}
          {:error, reason} -> {:error, reason}
        end
    end
  end

  # The streams of the file, read once and kept beside the conversion: every part needs them,
  # and the probe costs a second or two over the network.
  defp streams(id, url) do
    case read_json(file(id, "streams.json")) do
      [_ | _] = streams ->
        Enum.map(streams, &%{index: &1.index, kind: &1.kind, codec: &1.codec, lang: &1.lang})

      _ ->
        case probe(url) do
          [] ->
            []

          streams ->
            File.mkdir_p(dir(id))
            File.write(file(id, "streams.json"), Jason.encode!(streams))
            streams
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
    |> :crypto.hash("direct:v5:#{stream[:filename]}-#{stream[:filesize]}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc "Where this conversion's files are (laev's remux directory, same id shape)."
  def dir(id), do: Laev.Remux.dir(id)

  @doc "Whether this id is one of these conversions (an MP4, not TS segments)."
  def direct?(id), do: File.exists?(file(id, "audio.json"))

  @doc "The video file of a part: `media.mp4`, or `media-1800.mp4` for a part begun at 1800 s."
  def media(id, part \\ 0), do: file(id, part_name("media", ".mp4", part))

  @doc "A file of this conversion by name (`media.mp4`, `audio1.mp4`)."
  def file(id, name), do: Path.join(dir(id), name)

  @doc "The name of a part's file: `media.mp4` for the part from the start, `media-1800.mp4` otherwise."
  def part_name(base, ext, 0), do: base <> ext
  def part_name(base, ext, part), do: "#{base}-#{part}#{ext}"

  @doc "What a playlist appends to the name of something made for a part: `?from=1800`, or nothing."
  def part_query(0), do: ""
  def part_query(part), do: "?from=#{part}"

  @doc """
  The audio tracks of a conversion, as written at its start: `[%{file: "audio0", lang: "kor",
  name: "Korean"}]`. One entry (or none) means the audio is inside `media.mp4`.
  """
  def tracks(id) do
    case read_json(file(id, "audio.json")) do
      list when is_list(list) -> list
      _ -> []
    end
  end

  defp read_json(path) do
    with {:ok, json} <- File.read(path),
         {:ok, data} <- Jason.decode(json, keys: :atoms) do
      data
    else
      _ -> nil
    end
  end

  defp multi?(id), do: length(tracks(id)) > 1

  @doc """
  Keep what the playlist needs to know of the title beside a conversion (laev's or this one's):
  its original language, the audio to start with when the account's language is not there.
  """
  def remember_title(id, ctx) when is_binary(id) do
    dir = dir(id)
    File.mkdir_p(dir)
    File.write(Path.join(dir, "title.json"), Jason.encode!(%{language: ctx[:language]}))
    :ok
  end

  def remember_title(_id, _ctx), do: :ok

  @doc "The title's original language (`\"ko\"`) as remembered at the start, or nil."
  def original_language(id) do
    with {:ok, json} <- File.read(file(id, "title.json")),
         {:ok, %{"language" => lang}} when is_binary(lang) and lang != "" <- Jason.decode(json) do
      lang
    else
      _ -> nil
    end
  end

  defp running?(id, part), do: Registry.lookup(@registry, {id, part}) != []
  defp done?(id, part), do: File.exists?(file(id, part_name("done", "", part)))

  @doc "Ids converting right now."
  def running do
    @registry
    |> Registry.select([{{{:"$1", :_}, :_, :_}, [], [:"$1"]}])
    |> Enum.uniq()
  end

  defp workers(id), do: Registry.select(@registry, [{{{id, :_}, :"$1", :_}, [], [:"$1"]}])

  @doc "The stream is being watched: keep converting."
  def touch(id) do
    Enum.each(workers(id), &GenServer.cast(&1, :touch))
  end

  @doc "End the conversion, every part of it (what is written stays)."
  def stop(id) when is_binary(id) do
    Enum.each(workers(id), &DynamicSupervisor.terminate_child(@supervisor, &1))
  end

  def stop(_), do: :ok

  # ── parts ─────────────────────────────────────────────────────────

  # The part to serve a play from `from` seconds in: an existing one that has that place
  # already (the earliest, for the most room to seek back in), else a new one from there.
  defp part_for(_id, from) when not is_integer(from) or from < @min_part, do: 0

  defp part_for(id, from) do
    id
    |> parts()
    |> Enum.filter(&(&1 <= from and covers?(id, &1, from)))
    |> Enum.min(fn -> from end)
  end

  @doc "The starts of the parts on disk, in seconds, earliest first."
  def parts(id) do
    case File.ls(dir(id)) do
      {:ok, names} ->
        names
        |> Enum.flat_map(fn
          "media.mp4" ->
            [0]

          "media-" <> rest ->
            case Integer.parse(rest) do
              {n, ".mp4"} -> [n]
              _ -> []
            end

          _ ->
            []
        end)
        |> Enum.sort()

      _ ->
        []
    end
  end

  # A finished part reaches the end; one still running must be past the place, with room.
  defp covers?(id, part, from) do
    cond do
      usable?(id, part) -> true
      running?(id, part) -> reach(id, part) >= from + 10
      true -> false
    end
  end

  # A finished part is reused — unless it was written before audio files were cut into
  # fragments (one fragment for the whole track, which no player gets through: the iPhone
  # asks for the 60 MB again and again and shows nothing). That one is written again.
  defp usable?(id, part), do: done?(id, part) and not stale_audio?(id, part)

  defp stale_audio?(id, part) do
    multi?(id) and
      Enum.any?(tracks(id), fn t ->
        case Roki.Fmp4.scan(file(id, part_name(t.file, ".mp4", part))) do
          %{fragments: [%{duration: d}]} -> d > 10
          _ -> false
        end
      end)
  end

  # How far into the file a part has been written, in seconds.
  defp reach(id, part) do
    case Roki.Fmp4.scan(media(id, part)) do
      %{start: start, fragments: fragments} ->
        start + Enum.sum(Enum.map(fragments, & &1.duration))

      _ ->
        0
    end
  end

  @doc "Where a part begins, in seconds of the file: the first fragment's time (0 for the whole file)."
  def start_at(_id, 0), do: 0

  def start_at(id, part) do
    case Roki.Fmp4.scan(media(id, part)) do
      %{start: start} -> start
      _ -> part
    end
  end

  # A part begun before and left unfinished is written afresh; the rest of the directory (other
  # parts, fetched subtitles, what the title is) stays.
  defp clear_part(id, part) do
    case File.ls(dir(id)) do
      {:ok, names} ->
        for name <- names, part_of(name) == part, do: File.rm_rf(file(id, name))

      _ ->
        :ok
    end
  end

  # The part a file belongs to, by its name: `media-1800.mp4` → 1800, `audio0.mp4` → 0, else nil.
  defp part_of(name) do
    case Regex.run(~r/^(?:media|audio\d+|sub\d+|done)(?:-(\d+))?(?:\.mp4|\.vtt)?$/, name) do
      [_] -> 0
      [_, n] -> String.to_integer(n)
      _ -> nil
    end
  end

  @doc "Enough of a part is written to start playing: two fragments of every file, or all of it."
  def ready?(id, part \\ 0) do
    done?(id, part) or
      (enough?(media(id, part)) and
         (not multi?(id) or
            Enum.all?(tracks(id), &enough?(file(id, part_name(&1.file, ".mp4", part))))))
  end

  defp enough?(path) do
    case Roki.Fmp4.scan(path) do
      %{fragments: [_, _ | _]} -> true
      _ -> false
    end
  end

  # ── playlists ─────────────────────────────────────────────────────

  @doc """
  What the player loads for a part: the media playlist of `media.mp4` when the audio is in it,
  else a master playlist with the video and one rendition per audio track, the first of
  `prefer` (languages in order of preference, as `["en", "ko"]`) the release has as the default.
  """
  def playlist(id, part \\ 0, prefer \\ nil) do
    subs = Roki.Subs.tracks(id, part)

    cond do
      multi?(id) -> master_playlist(tracks(id), bandwidth(id, part), prefer, subs, part)
      subs != [] -> master_playlist([], bandwidth(id, part), prefer, subs, part)
      true -> media_playlist(id, part, "media")
    end
  end

  @doc """
  The master playlist of a multi-audio conversion: every track as a switchable rendition of
  one group. The default is the first track in the first preferred language the release has,
  else the first track (the player remembers the one picked and switches to it). Without a
  CODECS attribute on purpose — hls.js on Firefox stops at the HEVC string. The playlists
  named are those of `part`.
  """
  def master_playlist(tracks, bandwidth, prefer \\ nil, subs \\ [], part \\ 0) do
    chosen = default_track(tracks, prefer)
    q = part_query(part)

    renditions =
      tracks
      |> Enum.with_index()
      |> Enum.map(fn {t, i} ->
        lang = if t.lang != "", do: ~s(,LANGUAGE="#{Roki.Watch.short_code(t.lang)}"), else: ""
        default = if i == chosen, do: "YES", else: "NO"

        ~s(#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="#{t.name}"#{lang},DEFAULT=#{default},AUTOSELECT=YES,URI="#{t.file}.m3u8#{q}")
      end)

    audio = if tracks == [], do: "", else: ~s(,AUDIO="aud")
    subtitles = if subs == [], do: "", else: ~s(,SUBTITLES="subs")

    Enum.join(
      ["#EXTM3U", "#EXT-X-VERSION:7", "#EXT-X-INDEPENDENT-SEGMENTS"] ++
        renditions ++
        Roki.Subs.renditions(subs, part) ++
        [~s(#EXT-X-STREAM-INF:BANDWIDTH=#{bandwidth}#{audio}#{subtitles}), "video.m3u8#{q}"],
      "\n"
    ) <> "\n"
  end

  # The index of the first track in the first preferred language the release has, else 0.
  defp default_track(tracks, prefer) do
    prefer
    |> List.wrap()
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.find_value(0, fn p ->
      Enum.find_index(tracks, &(&1.lang != "" and Roki.Watch.short_code(&1.lang) == p))
    end)
  end

  @doc """
  laev's master playlist for a multi-audio TS conversion, made fit for the player: ffmpeg
  names every rendition `audio_N`, and tracks of one language all point at one rendition
  file (laev names the variants by language, so five Russian dubs become one `s_Rus`), so
  the list is cut down to one entry per file, named by its language, with the preferred
  language the default.
  """
  def tidy_master(content, prefer \\ nil, subs \\ []) do
    lines = String.split(content, "\n")
    media = Enum.filter(lines, &String.starts_with?(&1, "#EXT-X-MEDIA:TYPE=AUDIO"))

    tracks =
      media
      |> Enum.map(fn line -> %{uri: attr(line, "URI"), lang: attr(line, "LANGUAGE") || ""} end)
      |> Enum.uniq_by(& &1.uri)
      |> Enum.with_index()
      |> Enum.map(fn {t, n} ->
        Map.merge(t, %{index: n, name: track_name(t.lang, n), file: t.uri})
      end)
      |> unique_names()

    if tracks == [] do
      with_subtitles(content, subs)
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

      {before, after_media} =
        Enum.split_while(lines, &(not String.starts_with?(&1, "#EXT-X-MEDIA:TYPE=AUDIO")))

      rest = Enum.reject(after_media, &String.starts_with?(&1, "#EXT-X-MEDIA:TYPE=AUDIO"))
      with_subtitles(Enum.join(before ++ renditions ++ rest, "\n"), subs)
    end
  end

  @doc """
  A master playlist with subtitle renditions added: their `#EXT-X-MEDIA` lines before the
  variant, which gets `SUBTITLES="subs"`. Nothing changes without tracks.
  """
  def with_subtitles(master, []), do: master

  def with_subtitles(master, subs) do
    master
    |> String.split("\n")
    |> Enum.flat_map(fn line ->
      if String.starts_with?(line, "#EXT-X-STREAM-INF:") do
        Roki.Subs.renditions(subs) ++ [line <> ~s(,SUBTITLES="subs")]
      else
        [line]
      end
    end)
    |> Enum.join("\n")
  end

  @doc "laev's single-audio media playlist under a master, so subtitle renditions can ride along."
  def wrap_media(media_name, subs),
    do:
      with_subtitles(
        "#EXTM3U\n#EXT-X-VERSION:6\n#EXT-X-STREAM-INF:BANDWIDTH=8000000\n#{media_name}\n",
        subs
      )

  defp attr(line, name) do
    case Regex.run(~r/(?:^|,)#{name}="([^"]*)"/, line) do
      [_, v] -> v
      _ -> nil
    end
  end

  # The video's rate so far, plus the audio, for the master playlist's required figure.
  defp bandwidth(id, part) do
    case Roki.Fmp4.scan(media(id, part)) do
      %{fragments: [_ | _] = fs} ->
        bytes = Enum.sum(Enum.map(fs, & &1.size))
        seconds = Enum.sum(Enum.map(fs, & &1.duration))
        if seconds > 0, do: trunc(bytes * 8 / seconds) + 256_000, else: 10_000_000

      _ ->
        10_000_000
    end
  end

  @doc """
  The HLS media playlist of what is written of one file of a part so far (`base` is `"media"`
  or `"audio1"`): one byte range per fragment, ended once ffmpeg has finished. It counts from
  the part's start: what the fragments carry says where that is in the file.
  """
  def media_playlist(id, part, base) do
    name = part_name(base, ".mp4", part)

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

        tail = if done?(id, part), do: ["#EXT-X-ENDLIST"], else: []
        Enum.join(head ++ body ++ tail, "\n") <> "\n"

      nil ->
        "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:10\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:EVENT\n"
    end
  end

  # ── the worker ────────────────────────────────────────────────────

  def start_link(opts) do
    id = Keyword.fetch!(opts, :id)
    part = Keyword.get(opts, :part, 0)
    GenServer.start_link(__MODULE__, opts, name: {:via, Registry, {@registry, {id, part}}})
  end

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    dir = Keyword.fetch!(opts, :dir)
    part = Keyword.get(opts, :part, 0)
    File.mkdir_p!(dir)
    streams = Keyword.fetch!(opts, :streams)
    subs = subtitle_tracks(streams)
    audios = audio_tracks(streams)
    File.write(Path.join(dir, "subs.json"), Jason.encode!(subs))
    File.write(Path.join(dir, "audio.json"), Jason.encode!(audios))

    # One shell runs the pipeline (see `command/6`); its children are ended with it.
    port =
      Port.open({:spawn_executable, System.find_executable("sh")}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: ["-c", command(Keyword.fetch!(opts, :url), dir, streams, audios, subs, part)]
      ])

    Process.send_after(self(), :idle_check, 60_000)

    {:ok,
     %{
       id: Keyword.fetch!(opts, :id),
       part: part,
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
    File.write(Path.join(state.dir, part_name("done", "", state.part)), "")
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    Logger.warning(
      "direct #{state.id} (from #{state.part}) ffmpeg exited #{status}: #{state.last_error}"
    )

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
  #
  # A part begun later in the file (`-ss`, which lands on the keyframe before) keeps the file's
  # own clock: `-copyts` leaves the times as they are and `frag_discont` makes the first
  # fragment carry them, so the video, each audio file and the subtitles all agree on where
  # they are — without it the MP4 muxer counts each file from its own first packet, and audio
  # that begins a second after the keyframe comes out a second early. The TS stage would add
  # its usual 1.4 s to everything; `-muxdelay 0` stops it.
  @doc false
  def command(url, dir, streams, audios, subs, part) do
    video = codec_in(streams, "video")
    multi? = length(audios) > 1
    out = fn base, ext -> Path.join(dir, part_name(base, ext, part)) end

    sub_outputs =
      Enum.flat_map(subs, fn s ->
        [
          "-map",
          "0:#{s.index}",
          "-c:s",
          "webvtt",
          "-flush_packets",
          "1",
          "-f",
          "webvtt",
          out.(s.file, ".vtt")
        ]
      end)

    {seek, copyts, discont, ts_delay} =
      if part > 0,
        do:
          {["-ss", Integer.to_string(part)], ["-copyts"], "+frag_discont",
           ~w(-muxdelay 0 -muxpreload 0)},
        else: {[], [], "", []}

    read =
      ~w(ffmpeg -nostdin -loglevel error -rw_timeout 20000000) ++ seek ++ ["-i", url] ++ copyts

    # The input's audio streams, in order, as `0:a:N`; `audios` lists them in that order.
    audio_maps = Enum.flat_map(0..(length(audios) - 1)//1, &["-map", "0:a:#{&1}"])

    mp4 =
      ["-movflags", "frag_keyframe+empty_moov+default_base_moof+delay_moov" <> discont] ++
        ~w(-min_frag_duration 2000000 -f mp4)

    # A file of audio alone has no keyframes to cut at: cut it every two seconds, or the muxer
    # writes the whole track as one fragment at the end, and nothing of it plays until then.
    audio_mp4 = ~w(-frag_duration 2000000) ++ mp4

    # `-ac` takes the same stream specifier, but `-ac:1` means output stream 1 *of any kind*: with the
    # video mapped first, `-ac:0` landed on the video and the audio stayed 5.1, which AAC then
    # writes with an in-band channel layout that browsers cannot decode (a black screen).
    ac_spec = fn
      "" -> ""
      ":" <> n -> ":a:" <> n
    end

    # What makes each audio stream AAC (the Nth output audio stream, or all of them).
    to_aac = fn {a, _n}, spec ->
      if a.codec == "aac",
        do: ["-c:a#{spec}", "copy"],
        else: ["-c:a#{spec}", "aac", "-b:a#{spec}", "192k", "-ac#{ac_spec.(spec)}", "2"]
    end

    if video in ["hevc", "h265"] do
      # The TS carries the video and every audio track; the second ffmpeg splits them out.
      first =
        read ++
          ~w(-map 0:v:0) ++
          audio_maps ++
          ~w(-sn -c:v copy) ++
          Enum.flat_map(Enum.with_index(audios), &to_aac.(&1, ":#{elem(&1, 1)}")) ++
          ts_delay ++ ~w(-f mpegts -) ++ sub_outputs

      second =
        ~w(ffmpeg -nostdin -loglevel error -f mpegts -i -) ++
          copyts ++
          if multi? do
            ~w(-map 0:v:0 -c:v copy -tag:v hvc1) ++
              mp4 ++
              [out.("media", ".mp4")] ++
              Enum.flat_map(audios |> Enum.with_index(), fn {a, n} ->
                ~w(-map 0:a:#{n} -c:a copy -bsf:a aac_adtstoasc) ++
                  audio_mp4 ++ [out.(a.file, ".mp4")]
              end)
          else
            ~w(-map 0:v:0) ++
              if(audios != [], do: ~w(-map 0:a:0 -bsf:a aac_adtstoasc), else: []) ++
              ~w(-c copy -tag:v hvc1) ++ mp4 ++ [out.("media", ".mp4")]
          end

      shell(first) <> " | " <> shell(second)
    else
      if multi? do
        shell(
          read ++
            ~w(-map 0:v:0 -sn -c:v copy) ++
            mp4 ++
            [out.("media", ".mp4")] ++
            Enum.flat_map(Enum.with_index(audios), fn {a, n} = pair ->
              ~w(-map 0:a:#{n}) ++ to_aac.(pair, "") ++ audio_mp4 ++ [out.(a.file, ".mp4")]
            end) ++ sub_outputs
        )
      else
        audio_args = if audios == [], do: [], else: to_aac.({hd(audios), 0}, "")

        shell(
          read ++
            ~w(-map 0:v:0) ++
            Enum.take(audio_maps, 2) ++
            ~w(-sn -c:v copy) ++
            audio_args ++
            mp4 ++ [out.("media", ".mp4")] ++ sub_outputs
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
      %{
        index: s.index,
        codec: s.codec,
        lang: String.trim(s.lang || ""),
        file: "audio#{n}",
        name: track_name(s.lang, n)
      }
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
      {_name, [one]} ->
        [one]

      {name, same} ->
        Enum.with_index(same, 1) |> Enum.map(fn {t, k} -> %{t | name: "#{name} #{k}"} end)
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
