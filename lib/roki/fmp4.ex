defmodule Roki.Fmp4 do
  @moduledoc """
  Reads the shape of a fragmented MP4 as ffmpeg writes it: the header (`ftyp` + `moov`) and
  then `moof` + `mdat` pairs, one per fragment. A file still being written is read as far as
  it is complete, so a playlist can be made of it while it grows.

  Only box sizes, the video track's sample durations and each fragment's start time are read;
  nothing is decoded.
  """
  import Bitwise

  @doc """
  `%{init: bytes, timescale: n, start: seconds, fragments: [%{offset:, size:, duration:, time:}]}`
  for the complete fragments of the file (`duration` and `time` in seconds; `start` is the
  first fragment's time — zero for a file written from the beginning, the position in the
  film for one begun part-way through), or `nil` when the header is not there yet.
  """
  def scan(path) do
    with {:ok, %{size: size}} <- File.stat(path),
         {:ok, f} <- File.open(path, [:read, :binary, :raw]) do
      try do
        case boxes(f, 0, size, []) do
          [{"ftyp", _, ftyp_size}, {"moov", moov_off, moov_size} | rest] ->
            moov = read(f, moov_off + 8, moov_size - 8)
            {track, timescale, default_duration} = video_track(moov)

            fragments =
              rest
              |> Enum.chunk_every(2, 1, :discard)
              |> Enum.flat_map(fn
                [{"moof", off, moof_size}, {"mdat", mdat_off, mdat_size}]
                when mdat_off == off + moof_size ->
                  moof = read(f, off + 8, moof_size - 8)
                  {duration, time} = fragment_info(moof, track, default_duration)

                  [
                    %{
                      offset: off,
                      size: moof_size + mdat_size,
                      duration: duration / timescale,
                      time: time / timescale
                    }
                  ]

                _ ->
                  []
              end)

            start =
              case fragments do
                [first | _] -> first.time
                [] -> 0
              end

            %{init: ftyp_size + moov_size, timescale: timescale, start: start, fragments: fragments}

          _ ->
            nil
        end
      after
        File.close(f)
      end
    else
      _ -> nil
    end
  rescue
    _ -> nil
  end

  # Top-level boxes that are entirely on disk, as `{type, offset, size}`.
  defp boxes(f, pos, size, acc) when pos + 8 <= size do
    case read(f, pos, 16) do
      <<1::32, type::binary-size(4), large::64, _::binary>> when large > 0 ->
        box(f, pos, size, type, large, acc)

      <<n::32, type::binary-size(4), _::binary>> when n >= 8 ->
        box(f, pos, size, type, n, acc)

      _ ->
        Enum.reverse(acc)
    end
  end

  defp boxes(_f, _pos, _size, acc), do: Enum.reverse(acc)

  defp box(f, pos, size, type, n, acc) do
    if pos + n <= size,
      do: boxes(f, pos + n, size, [{type, pos, n} | acc]),
      else: Enum.reverse(acc)
  end

  defp read(f, pos, len) do
    case :file.pread(f, pos, len) do
      {:ok, data} -> data
      _ -> <<>>
    end
  end

  # Children of a box's payload, as `{type, payload}`.
  defp children(<<n::32, type::binary-size(4), rest::binary>>)
       when n >= 8 and byte_size(rest) >= n - 8 do
    <<payload::binary-size(n - 8), more::binary>> = rest
    [{type, payload} | children(more)]
  end

  defp children(_), do: []

  defp child(nil, _type), do: nil

  defp child(payload, type),
    do: Enum.find_value(children(payload), fn {t, p} -> if t == type, do: p end)

  # The video track's id, its timescale, and the default sample duration from `trex`.
  defp video_track(moov) do
    traks = for {"trak", p} <- children(moov), do: p

    trak =
      Enum.find(traks, List.first(traks), fn p ->
        case p |> child("mdia") |> child("hdlr") do
          <<_::64, "vide", _::binary>> -> true
          _ -> false
        end
      end)

    track_id =
      case child(trak, "tkhd") do
        <<0, _::24, _::64, id::32, _::binary>> -> id
        <<1, _::24, _::128, id::32, _::binary>> -> id
        _ -> 1
      end

    timescale =
      case trak |> child("mdia") |> child("mdhd") do
        <<0, _::24, _::64, ts::32, _::binary>> -> ts
        <<1, _::24, _::128, ts::32, _::binary>> -> ts
        _ -> 1
      end

    default =
      case child(moov, "mvex") do
        nil ->
          0

        mvex ->
          Enum.find_value(children(mvex), 0, fn
            {"trex", <<_::32, ^track_id::32, _::32, d::32, _::binary>>} -> d
            _ -> nil
          end)
      end

    {track_id, max(timescale, 1), default}
  end

  # The sum of the track's samples' durations in one fragment, and the fragment's decode time
  # (`tfdt`), both in the track's timescale.
  defp fragment_info(moof, track_id, default) do
    Enum.find_value(children(moof), {0, 0}, fn
      {"traf", traf} ->
        case child(traf, "tfhd") do
          <<_::8, flags::24, ^track_id::32, rest::binary>> ->
            per_sample = tfhd_default(flags, rest) || default

            duration =
              children(traf)
              |> Enum.filter(&match?({"trun", _}, &1))
              |> Enum.map(fn {_, trun} -> trun_duration(trun, per_sample) end)
              |> Enum.sum()

            time =
              case child(traf, "tfdt") do
                <<0, _::24, t::32, _::binary>> -> t
                <<1, _::24, t::64, _::binary>> -> t
                _ -> 0
              end

            {duration, time}

          _ ->
            nil
        end

      _ ->
        nil
    end)
  end

  # `tfhd`'s default sample duration, when the flags say it is there.
  defp tfhd_default(flags, rest) do
    skip = if((flags &&& 0x1) != 0, do: 8, else: 0) + if((flags &&& 0x2) != 0, do: 4, else: 0)

    if (flags &&& 0x8) != 0 do
      case rest do
        <<_::binary-size(skip), d::32, _::binary>> -> d
        _ -> nil
      end
    end
  end

  defp trun_duration(<<_::8, flags::24, count::32, rest::binary>>, per_sample) do
    skip = if((flags &&& 0x1) != 0, do: 4, else: 0) + if((flags &&& 0x4) != 0, do: 4, else: 0)

    if (flags &&& 0x100) != 0 and byte_size(rest) >= skip do
      <<_::binary-size(skip), samples::binary>> = rest

      stride =
        4 + if((flags &&& 0x200) != 0, do: 4, else: 0) +
          if((flags &&& 0x400) != 0, do: 4, else: 0) +
          if((flags &&& 0x800) != 0, do: 4, else: 0)

      samples
      |> binary_part(0, min(byte_size(samples), stride * count))
      |> sum_durations(stride, 0)
    else
      count * per_sample
    end
  end

  defp trun_duration(_, _), do: 0

  defp sum_durations(<<d::32, rest::binary>>, stride, acc) when byte_size(rest) >= stride - 4 do
    <<_::binary-size(stride - 4), more::binary>> = rest
    sum_durations(more, stride, acc + d)
  end

  defp sum_durations(_, _stride, acc), do: acc
end
