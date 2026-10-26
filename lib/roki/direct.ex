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
  (`%{"hevc" => true, …}`), as a map of atoms. Anything missing is "no".
  """
  def caps(params) when is_map(params) do
    for key <- [:hevc, :av1, :vp9], into: %{} do
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
  # directory: laev's holds TS segments, this one an MP4.
  defp id_for(stream) do
    :sha256
    |> :crypto.hash("direct:#{stream[:filename]}-#{stream[:filesize]}")
    |> Base.encode16(case: :lower)
    |> binary_part(0, 16)
  end

  @doc "Where this conversion's files are (laev's remux directory, same id shape)."
  def dir(id), do: Laev.Remux.dir(id)

  @doc "Whether this id is one of these conversions (an MP4, not TS segments)."
  def direct?(id), do: File.exists?(media(id))

  def media(id), do: Path.join(dir(id), "media.mp4")

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

  @doc "Enough is written to start playing: two fragments, or all of it."
  def ready?(id) do
    done?(id) or
      case Roki.Fmp4.scan(media(id)) do
        %{fragments: [_, _ | _]} -> true
        _ -> false
      end
  end

  @doc """
  The HLS playlist of what is written so far: one byte range of `media.mp4` per fragment,
  ended once ffmpeg has finished.
  """
  def playlist(id) do
    case Roki.Fmp4.scan(media(id)) do
      %{init: init, fragments: fragments} ->
        longest = fragments |> Enum.map(& &1.duration) |> Enum.max(fn -> 4 end)

        head = [
          "#EXTM3U",
          "#EXT-X-VERSION:7",
          "#EXT-X-TARGETDURATION:#{max(ceil(longest), 4)}",
          "#EXT-X-MEDIA-SEQUENCE:0",
          "#EXT-X-PLAYLIST-TYPE:EVENT",
          "#EXT-X-INDEPENDENT-SEGMENTS",
          ~s(#EXT-X-MAP:URI="media.mp4",BYTERANGE="#{init}@0")
        ]

        body =
          Enum.flat_map(fragments, fn f ->
            [
              "#EXTINF:#{:erlang.float_to_binary(f.duration * 1.0, decimals: 3)},",
              "#EXT-X-BYTERANGE:#{f.size}@#{f.offset}",
              "media.mp4"
            ]
          end)

        tail = if done?(id), do: ["#EXT-X-ENDLIST"], else: []
        Enum.join(head ++ body ++ tail, "\n") <> "\n"

      nil ->
        "#EXTM3U\n#EXT-X-VERSION:7\n#EXT-X-TARGETDURATION:4\n#EXT-X-MEDIA-SEQUENCE:0\n#EXT-X-PLAYLIST-TYPE:EVENT\n"
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
    File.write(Path.join(dir, "subs.json"), Jason.encode!(subs))

    args = ffmpeg_args(Keyword.fetch!(opts, :url), dir, streams, subs)
    ffmpeg = System.find_executable("ffmpeg")

    port =
      Port.open({:spawn_executable, ffmpeg}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args
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
      {:os_pid, os_pid} -> System.cmd("kill", ["-TERM", Integer.to_string(os_pid)])
      _ -> :ok
    end

    :ok
  end

  def terminate(_reason, _state), do: :ok

  # Video copied as it is; audio copied when it is AAC already, else AAC stereo (what laev
  # does: a browser plays stereo regardless, and TrueHD 7.1 cannot be put in AAC as it is).
  # Fragments at keyframes, at least two seconds long, in the MP4 muxer's own form.
  defp ffmpeg_args(url, dir, streams, subs) do
    video = codec_in(streams, "video")
    audio = codec_in(streams, "audio")
    tag = if video in ["hevc", "h265"], do: ["-tag:v", "hvc1"], else: []

    audio_args =
      if audio == "aac",
        do: ["-c:a", "copy"],
        else: ["-c:a", "aac", "-b:a", "192k", "-ac", "2"]

    has_audio = Enum.any?(streams, &(&1.kind == "audio"))

    sub_outputs =
      Enum.flat_map(subs, fn s ->
        [
          "-map",
          "0:#{s.index}",
          "-c:s",
          "webvtt",
          "-f",
          "webvtt",
          Path.join(dir, "#{s.file}.vtt")
        ]
      end)

    ["-nostdin", "-loglevel", "error", "-rw_timeout", "20000000", "-i", url, "-map", "0:v:0"] ++
      if(has_audio, do: ["-map", "0:a:0"], else: []) ++
      ["-sn", "-c:v", "copy"] ++
      tag ++
      audio_args ++
      [
        "-movflags",
        "frag_keyframe+empty_moov+default_base_moof",
        "-min_frag_duration",
        "2000000",
        "-f",
        "mp4",
        Path.join(dir, "media.mp4")
      ] ++ sub_outputs
  end

  @image_subs ["hdmv_pgs_subtitle", "dvd_subtitle", "dvb_subtitle"]

  # The same manifest laev's worker writes, so the subtitle list is read the same way.
  defp subtitle_tracks(streams) do
    streams
    |> Enum.filter(&(&1.kind == "subtitle" and &1.codec not in @image_subs))
    |> Enum.with_index()
    |> Enum.map(fn {s, n} -> %{index: s.index, lang: s.lang, file: "sub#{n}"} end)
  end
end
