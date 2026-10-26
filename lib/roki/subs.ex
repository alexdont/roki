defmodule Roki.Subs do
  @moduledoc """
  The subtitle files beside a conversion (the release's own, `subN.vtt`, and ones fetched
  from a provider, `ext-….vtt`) as HLS subtitle renditions, so a player that draws its own
  subtitles — the iPhone's full-screen player above all — lists them in its own menu.

  HLS wants subtitles cut like the video: a media playlist with one WebVTT piece per video
  segment, each carrying the cues of that stretch and a timestamp map onto the stream's
  clock. The pieces are cut from the whole file on request, so a file ffmpeg is still
  writing serves what it has, and nothing is stored twice.

  A direct conversion begun part-way through the film (a *part*, see `Roki.Direct`) has its
  own copy of the release's subtitles (`sub0-1800.vtt`), on the film's clock like its video;
  fetched files are the whole film's and serve every part.
  """

  @doc """
  The subtitle tracks of conversion `id` for `part`: `[%{file: "sub0", lang: "fre", name:
  "French"}]`, the release's own first, then fetched ones (named after their source).
  """
  def tracks(id, part \\ 0) do
    dir = Laev.Remux.dir(id)

    embedded =
      case File.read(Path.join(dir, "subs.json")) do
        {:ok, json} ->
          case Jason.decode(json) do
            {:ok, list} when is_list(list) ->
              for %{"file" => file} = s <- list, present?(dir, cue_file(file, part)),
                  do: %{file: file, lang: s["lang"] || "", name: name(s["lang"], "")}

            _ ->
              []
          end

        _ ->
          []
      end

    fetched =
      case File.ls(dir) do
        {:ok, names} ->
          names
          |> Enum.filter(&Regex.match?(~r/^ext-[a-z]{2,3}(?:-(?:\d|os\d{1,10}))?\.vtt$/, &1))
          |> Enum.sort()
          |> Enum.map(fn vtt ->
            file = String.replace_suffix(vtt, ".vtt", "")
            [_, lang] = Regex.run(~r/^ext-([a-z]{2,3})/, file)
            %{file: file, lang: lang, name: name(lang, if(file =~ "-os", do: " (OpenSubtitles)", else: " (fetched)"))}
          end)

        _ ->
          []
      end

    unique(embedded ++ fetched)
  end

  # The WebVTT file a track's cues are in: the release's own are written per part.
  defp cue_file("sub" <> _ = file, part), do: Roki.Direct.part_name(file, ".vtt", part)
  defp cue_file(file, _part), do: file <> ".vtt"

  defp present?(dir, name) do
    case File.stat(Path.join(dir, name)) do
      {:ok, %{size: n}} -> n > 0
      _ -> false
    end
  end

  defp name(lang, suffix) do
    case String.trim(lang || "") do
      "" -> "Subtitles" <> suffix
      l -> Roki.Watch.language(l) <> suffix
    end
  end

  defp unique(tracks) do
    tracks
    |> Enum.group_by(& &1.name)
    |> Enum.flat_map(fn
      {_name, [one]} -> [one]
      {name, same} -> Enum.with_index(same, 1) |> Enum.map(fn {t, k} -> %{t | name: "#{name} #{k}"} end)
    end)
    |> Enum.sort_by(& &1.file)
  end

  @doc "The `#EXT-X-MEDIA` lines for `tracks` (of `part`); none shown unless picked."
  def renditions(tracks, part \\ 0) do
    q = Roki.Direct.part_query(part)

    Enum.map(tracks, fn t ->
      lang = if t.lang != "", do: ~s(,LANGUAGE="#{Roki.Watch.short_code(t.lang)}"), else: ""
      ~s(#EXT-X-MEDIA:TYPE=SUBTITLES,GROUP-ID="subs",NAME="#{t.name}"#{lang},DEFAULT=NO,AUTOSELECT=NO,URI="#{t.file}.m3u8#{q}")
    end)
  end

  @doc """
  The subtitle media playlist of `file` (`"sub0"`) for `part`, cut like the stream's own
  segments: one piece `file.K.vtt` per segment. `nil` when the stream has no segments yet.
  """
  def playlist(id, file, part \\ 0) do
    case timeline(id, part) do
      %{segments: [_ | _] = segments, done?: done?, target: target} ->
        q = Roki.Direct.part_query(part)

        head = [
          "#EXTM3U",
          "#EXT-X-VERSION:7",
          "#EXT-X-TARGETDURATION:#{target}",
          "#EXT-X-MEDIA-SEQUENCE:0",
          "#EXT-X-PLAYLIST-TYPE:EVENT"
        ]

        body =
          segments
          |> Enum.with_index()
          |> Enum.flat_map(fn {{_start, dur}, k} ->
            ["#EXTINF:#{:erlang.float_to_binary(dur * 1.0, decimals: 3)},", "#{file}.#{k}.vtt#{q}"]
          end)

        tail = if done?, do: ["#EXT-X-ENDLIST"], else: []
        Enum.join(head ++ body ++ tail, "\n") <> "\n"

      _ ->
        nil
    end
  end

  @doc "Piece `k` of `file` for `part`: the cues within that segment's stretch, mapped onto the stream's clock."
  def segment(id, file, k, part \\ 0) do
    with %{segments: segments, offset: offset} <- timeline(id, part),
         {start, dur} <- Enum.at(segments, k),
         {:ok, text} <- File.read(Path.join(Laev.Remux.dir(id), cue_file(file, part))) do
      cues =
        text
        |> parse()
        |> Enum.filter(fn c -> c.to > start and c.from < start + dur end)
        |> Enum.map(fn c -> "#{stamp(c.from)} --> #{stamp(c.to)}#{c.settings}\n#{c.text}" end)

      # The map belongs to the header block: on the line after WEBVTT, before the first blank line.
      Enum.join(["WEBVTT\nX-TIMESTAMP-MAP=MPEGTS:#{offset},LOCAL:00:00:00.000" | cues], "\n\n") <> "\n"
    else
      _ -> nil
    end
  end

  # The stream's segments as `{start, duration}` in seconds of the film, whether it is complete,
  # its target duration, and where its clock starts in 90 kHz units: a direct conversion's MP4
  # carries the film's own times (a part begun later starts where it began); laev's MPEG-TS
  # segments start at ffmpeg's usual 1.4 s.
  defp timeline(id, part) do
    dir = Laev.Remux.dir(id)

    cond do
      Roki.Direct.direct?(id) ->
        case Roki.Fmp4.scan(Roki.Direct.media(id, part)) do
          %{start: start, fragments: fragments} ->
            durations = Enum.map(fragments, & &1.duration)
            done? = File.exists?(Path.join(dir, Roki.Direct.part_name("done", "", part)))
            %{segments: starts(durations, start), done?: done?, target: target(durations), offset: 0}

          _ ->
            nil
        end

      true ->
        media = if File.exists?(Path.join(dir, "master.m3u8")), do: "s_0.m3u8", else: "index.m3u8"

        case File.read(Path.join(dir, media)) do
          {:ok, content} ->
            durations =
              Regex.scan(~r/^#EXTINF:([\d.]+)/m, content) |> Enum.map(fn [_, d] -> String.to_float(pad(d)) end)

            %{
              segments: starts(durations, 0.0),
              done?: content =~ "#EXT-X-ENDLIST",
              target: target(durations),
              offset: 126_000
            }

          _ ->
            nil
        end
    end
  end

  defp pad(d), do: if(d =~ ".", do: d, else: d <> ".0")

  defp starts(durations, from) do
    {segments, _} =
      Enum.map_reduce(durations, from * 1.0, fn d, at -> {{at, d}, at + d} end)

    segments
  end

  defp target(durations), do: max(ceil(Enum.max(durations, fn -> 10 end)), 10)

  @doc "The cues of a WebVTT text: `[%{from:, to:, settings:, text:}]`, times in seconds."
  def parse(text) do
    text
    |> String.replace("\r\n", "\n")
    |> String.split(~r/\n{2,}/)
    |> Enum.flat_map(fn block ->
      lines = String.split(block, "\n", trim: true)

      case Enum.split_while(lines, &(not String.contains?(&1, "-->"))) do
        {_id, [timing | body]} ->
          case Regex.run(~r/^\s*([\d:.]+)\s*-->\s*([\d:.]+)(.*)$/, timing) do
            [_, from, to, settings] ->
              [%{from: seconds(from), to: seconds(to), settings: settings, text: Enum.join(body, "\n")}]

            _ ->
              []
          end

        _ ->
          []
      end
    end)
  end

  defp seconds(stamp) do
    case String.split(stamp, ":") do
      [h, m, s] -> String.to_integer(h) * 3600 + String.to_integer(m) * 60 + String.to_float(pad(s))
      [m, s] -> String.to_integer(m) * 60 + String.to_float(pad(s))
      _ -> 0.0
    end
  end

  defp stamp(t) do
    ms = round(t * 1000)
    h = div(ms, 3_600_000)
    m = div(rem(ms, 3_600_000), 60_000)
    s = div(rem(ms, 60_000), 1000)
    f = rem(ms, 1000)
    :io_lib.format("~2..0B:~2..0B:~2..0B.~3..0B", [h, m, s, f]) |> IO.iodata_to_binary()
  end
end
