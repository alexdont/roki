defmodule Roki.ImdbDates do
  @moduledoc """
  The dates a person rated things, from their IMDb ratings export.

  TMDB keeps no date a title was rated that this site can read, so a catalogue brought across
  from IMDb arrives undated (see `Roki.Profile`). IMDb's own export has the "Date Rated" column.
  Each row is matched to its TMDB title by IMDb id and, when that title is on the person's
  watched list with no date of its own, dated that day. A date they set by hand is never
  replaced, and episodes are left out: a show is dated as a whole.
  """

  alias Roki.Profile

  @kinds [
    "Movie",
    "TV Series",
    "TV Mini Series",
    "TV Movie",
    "TV Special",
    "TV Short",
    "Video",
    "Short"
  ]

  @doc """
  The titles in an export: `[%{const: "tt…", date: ~D[…]}]`. `{:error, :not_imdb}` when the
  text has no `Const` and `Date Rated` columns.
  """
  def parse(csv) when is_binary(csv) do
    case csv |> String.trim_leading("﻿") |> NimbleCSV.RFC4180.parse_string(skip_headers: false) do
      [header | rows] ->
        with c when is_integer(c) <- Enum.find_index(header, &(&1 == "Const")),
             d when is_integer(d) <- Enum.find_index(header, &(&1 == "Date Rated")) do
          k = Enum.find_index(header, &(&1 == "Title Type"))

          titles =
            for row <- rows,
                title?(row, k),
                {:ok, date} <- [Date.from_iso8601(Enum.at(row, d, ""))],
                const = Enum.at(row, c),
                String.starts_with?(const, "tt"),
                do: %{const: const, date: date}

          {:ok, titles}
        else
          _ -> {:error, :not_imdb}
        end

      _ ->
        {:error, :not_imdb}
    end
  rescue
    NimbleCSV.ParseError -> {:error, :not_imdb}
  end

  defp title?(_row, nil), do: true
  defp title?(row, k), do: Enum.at(row, k) in @kinds

  @doc """
  Date this account's undated watched titles from an export. `resolve` turns an IMDb id into
  `{"movie" | "tv", tmdb_id}` or nil; by default TMDB is asked through the account's laev.

  `{:ok, %{dated: n, kept: n, unlisted: n, unresolved: n}}` — `kept` already had a date,
  `unlisted` are not on the watched list, `unresolved` TMDB could not place.
  """
  def import(uuid, csv, resolve \\ nil) do
    resolve = resolve || (&tmdb_key(uuid, &1))

    with {:ok, rows} <- parse(csv) do
      rows = Enum.uniq_by(rows, & &1.const)

      resolved =
        rows
        |> Task.async_stream(&{&1, resolve.(&1.const)}, max_concurrency: 8, timeout: 60_000)
        |> Enum.map(fn {:ok, r} -> r end)

      watched =
        keys(
          uuid,
          "select type, id from roki_watched where user_uuid = $1 and status = 'finished'"
        )

      dated = keys(uuid, "select type, id from roki_watch_dates where user_uuid = $1")

      {todo, counts} =
        Enum.reduce(resolved, {[], %{dated: 0, kept: 0, unlisted: 0, unresolved: 0}}, fn
          {_row, nil}, {todo, c} ->
            {todo, Map.update!(c, :unresolved, &(&1 + 1))}

          {row, key}, {todo, c} ->
            cond do
              not MapSet.member?(watched, key) -> {todo, Map.update!(c, :unlisted, &(&1 + 1))}
              MapSet.member?(dated, key) -> {todo, Map.update!(c, :kept, &(&1 + 1))}
              true -> {[{key, row.date} | todo], c}
            end
        end)

      todo
      |> Enum.group_by(&elem(&1, 1), fn {{type, id}, _} -> "#{type}:#{id}" end)
      |> Enum.each(fn {date, keys} -> Profile.set_watched_at(uuid, keys, date) end)

      {:ok, %{counts | dated: length(todo)}}
    end
  end

  defp keys(uuid, sql) do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    Roki.Repo.query!(sql, [bin]).rows |> MapSet.new(fn [t, i] -> {t, i} end)
  end

  defp tmdb_key(uuid, const) do
    case Roki.Laev.run(uuid, fn -> Laev.Tmdb.find_imdb(const) end) do
      {:ok, %{} = m} -> {m["media_type"] || m[:media_type] || m[:type], m["id"] || m[:id]}
      _ -> nil
    end
  end
end
