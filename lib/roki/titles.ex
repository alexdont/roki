defmodule Roki.Titles do
  @moduledoc """
  The site's own copy of what TMDB says about a title, so a page is drawn from here and TMDB
  is asked once.

  Two depths. A *card* is what a list row needs — name, year, poster, a line of overview —
  and every list that passes through the site leaves its cards here (`remember/1`). The
  *whole* title is what the title page shows (`Roki.Watch.title/3`'s map), kept once a title
  page has read it (`put/1`). A film that is out or a show that has ended is final: it is
  never read from TMDB again. Anything else is read again when it is two weeks old, behind
  the page, which gets the copy it has.
  """

  alias Roki.Repo

  @fresh_s 14 * 24 * 3600
  @image "https://image.tmdb.org/t/p/"

  @doc """
  The whole title, when a title page has kept it: `{:ok, title, fresh?}` — `fresh?` false
  when it is old enough to read again — or `:none`.
  """
  def get(type, id) when is_binary(type) and is_integer(id) do
    case Repo.query!("select data, final, fetched_at from roki_titles where type = $1 and id = $2 and data is not null", [type, id]) do
      %{rows: [[data, final, fetched_at]]} ->
        fresh? = final or (fetched_at != nil and NaiveDateTime.diff(NaiveDateTime.utc_now(), fetched_at) < @fresh_s)
        # A raw query hands JSON back as text.
        data = if is_binary(data), do: Jason.decode!(data), else: data
        {:ok, atomize(data), fresh?}

      _ ->
        :none
    end
  end

  @doc "Keep a whole title (as `Roki.Watch.title/3` returns it)."
  def put(%{type: type, id: id} = title) when is_binary(type) and is_integer(id) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.query!(
      """
      insert into roki_titles (type, id, name, year, poster_path, overview, data, final, fetched_at, seen_at)
      values ($1, $2, $3, $4, $5, $6, $7::jsonb, $8, $9, $9)
      on conflict (type, id) do update
        set name = excluded.name, year = excluded.year, poster_path = excluded.poster_path,
            overview = excluded.overview, data = excluded.data, final = excluded.final,
            fetched_at = excluded.fetched_at, seen_at = excluded.seen_at
      """,
      [type, id, title[:title], title[:year], title[:poster_path], title[:overview], Jason.encode!(title), final?(title), now]
    )

    :ok
  end

  # A film that is out, a show that has ended: TMDB has nothing more to say that matters here.
  defp final?(%{type: "movie", status: "Released", date: date}) when is_binary(date), do: date < Date.to_iso8601(Date.utc_today())
  defp final?(%{type: "tv", status: status}) when status in ["Ended", "Canceled"], do: true
  defp final?(_title), do: false

  @doc """
  Keep the cards of a list of titles (`%{type:, id:, title:, poster:, year:, overview:}`,
  the poster as a URL or a path): what a row needs, without touching a whole title already
  kept. Nothing is read; a list is remembered as it goes by.
  """
  def remember(items) when is_list(items) do
    rows =
      for %{type: type, id: id} = i <- items,
          type in ["movie", "tv"] and is_integer(id),
          name = i[:title],
          is_binary(name) and name != "",
          do: {type, id, name, i[:year], poster_path(i[:poster_path] || i[:poster]), i[:overview]}

    # One row per title: a show listed once per season would be the same row twice in one
    # statement, which Postgres refuses.
    rows = Enum.uniq_by(rows, fn {type, id, _, _, _, _} -> {type, id} end)

    now = DateTime.utc_now() |> DateTime.truncate(:second)

    rows
    |> Enum.chunk_every(200)
    |> Enum.each(fn chunk ->
      {values, params} =
        chunk
        |> Enum.with_index()
        |> Enum.map_reduce([], fn {{type, id, name, year, path, overview}, i}, acc ->
          n = i * 6
          {"($#{n + 1}, $#{n + 2}, $#{n + 3}, $#{n + 4}, $#{n + 5}, $#{n + 6}, $#{length(chunk) * 6 + 1})",
           acc ++ [type, id, name, year, path, overview]}
        end)

      Repo.query!(
        """
        insert into roki_titles (type, id, name, year, poster_path, overview, seen_at) values #{Enum.join(values, ", ")}
        on conflict (type, id) do update
          set name = coalesce(roki_titles.name, excluded.name),
              year = coalesce(roki_titles.year, excluded.year),
              poster_path = coalesce(roki_titles.poster_path, excluded.poster_path),
              overview = coalesce(roki_titles.overview, excluded.overview),
              seen_at = excluded.seen_at
        """,
        params ++ [now]
      )
    end)

    :ok
  end

  def remember(_items), do: :ok

  @doc "The same, behind the page: a list is remembered without the page waiting for it."
  def remember_later(items) when is_list(items) and items != [] do
    Task.start(fn -> remember(items) end)
    :ok
  end

  def remember_later(_items), do: :ok

  @doc "The cards of some titles, by `{type, id}`: `%{{type, id} => %{title:, year:, poster:, overview:}}` (the poster at 342 px)."
  def cards(keys) when is_list(keys) do
    keys = Enum.uniq(keys)

    if keys == [] do
      %{}
    else
      {types, ids} = Enum.unzip(keys)

      %{rows: rows} =
        Repo.query!(
          "select type, id, name, year, poster_path, overview from roki_titles where (type, id) in (select unnest($1::text[]), unnest($2::int[]))",
          [types, ids]
        )

      Map.new(rows, fn [type, id, name, year, path, overview] ->
        {{type, id}, %{title: name, year: year, poster: poster_url(path, "w342"), poster_path: path, overview: overview}}
      end)
    end
  end

  @doc "The card of one title, or nil."
  def card(type, id), do: cards([{type, id}])[{type, id}]

  @doc "A TMDB image path (`/abc.jpg`) as a URL at `size`, or nil."
  def poster_url(nil, _size), do: nil
  def poster_url("", _size), do: nil
  def poster_url(path, size), do: @image <> size <> path

  # A TMDB image URL back to its path; a path stays one; anything else is nothing.
  defp poster_path(nil), do: nil
  defp poster_path("/" <> _ = path), do: path

  defp poster_path(@image <> rest) do
    case String.split(rest, "/", parts: 2) do
      [_size, file] -> "/" <> file
      _ -> nil
    end
  end

  defp poster_path(_), do: nil

  # The whole title comes back from JSON with string keys; its keys are the ones
  # `Roki.Watch.normalize/2` writes, every one an atom the code already has.
  defp atomize(%{} = map), do: Map.new(map, fn {k, v} -> {String.to_existing_atom(k), atomize(v)} end)
  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(other), do: other
end
