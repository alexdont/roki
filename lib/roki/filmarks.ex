defmodule Roki.Filmarks do
  @moduledoc """
  A title's score on Filmarks, the Japanese film, drama and anime site (out of 5).

  Filmarks has no API, so this reads its search page: the title is searched under the name TMDB
  gives it in Japanese, and the result that matches in year and name is taken. A title that does
  not match confidently has no score here, which is better than the wrong one. Shows are kept by
  Filmarks one season at a time; the first season's score stands for the show.

  Gentle by design: each title is looked up once a week, at most a few lookups a minute for the
  whole site, and the request says who is asking. Nothing here may break a page: any failure is
  "no score".
  """

  alias Roki.TTLCache

  @ttl_s 7 * 24 * 3600
  @base "https://filmarks.com"
  @ua "roki.ee/1.0 (title pages; https://roki.ee)"

  @doc """
  `%{score: 4.3, text: "4.3/5", url: ..., name: ...}` or nil. `type` is `"movie"` or `"tv"`;
  `anime?` picks Filmarks' anime listing for a show over its drama one. Call from a task: it asks
  TMDB and Filmarks.
  """
  def score(type, id, anime?, uuid) when type in ["movie", "tv"] and is_integer(id) do
    case TTLCache.fetch({:filmarks, type, id}, @ttl_s, fn -> lookup(type, id, anime?, uuid) end) do
      {:ok, found} -> found
      _ -> nil
    end
  end

  defp lookup(type, id, anime?, uuid) do
    with {:ok, %{name: name, year: year}} <- japanese(type, id, uuid),
         :ok <- allowed(),
         {:ok, html} <- search(listing(type, anime?), name) do
      {:ok, pick(parse(html), name, year)}
    else
      :none -> {:ok, nil}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp listing("movie", _), do: "movies"
  defp listing("tv", true), do: "animes"
  defp listing("tv", _), do: "dramas"

  # TMDB's Japanese name for it, and the year it came out.
  defp japanese(type, id, uuid) do
    case Roki.Laev.public(uuid, fn -> Roki.TmdbApi.get("/#{type}/#{id}", language: "ja-JP") end) do
      {:ok, body} ->
        name = body["title"] || body["name"] || body["original_title"] || body["original_name"]
        date = body["release_date"] || body["first_air_date"]

        if is_binary(name) and name != "" and is_binary(date) and byte_size(date) >= 4 do
          {:ok, %{name: name, year: String.to_integer(binary_part(date, 0, 4))}}
        else
          :none
        end

      _ ->
        :error
    end
  end

  defp allowed do
    case Roki.RateLimit.check(:filmarks, :site, 12, 60_000) do
      :ok -> :ok
      _ -> :error
    end
  end

  defp search(listing, name) do
    case Req.get("#{@base}/search/#{listing}",
           params: [q: name],
           headers: [{"user-agent", @ua}, {"accept-language", "ja,en;q=0.5"}],
           retry: false,
           receive_timeout: 8_000
         ) do
      {:ok, %{status: 200, body: html}} when is_binary(html) -> {:ok, html}
      _ -> :error
    end
  end

  @doc false
  # Every result on a search page: `%{name, href, year, score}` (score nil when it has none yet).
  def parse(html) do
    {:ok, doc} = Floki.parse_document(html)

    doc
    |> Floki.find(".js-cassette")
    |> Enum.map(fn c ->
      info = c |> Floki.find(".p-content-cassette__other-info") |> Floki.text()

      %{
        name: c |> Floki.find(".p-content-cassette__title") |> Floki.text() |> String.trim(),
        href: c |> Floki.find("a[href]") |> Floki.attribute("href") |> Enum.find(&detail?/1),
        year:
          case Regex.run(~r/(\d{4})年/u, info) do
            [_, y] -> String.to_integer(y)
            _ -> nil
          end,
        score: c |> Floki.find(".c-rating__score") |> Floki.text() |> to_score()
      }
    end)
    |> Enum.reject(&(&1.name == "" or is_nil(&1.href)))
  end

  defp detail?(href), do: Regex.match?(~r{^/(movies|animes|dramas)/\d+}, href)

  defp to_score(text) do
    case Float.parse(String.trim(text)) do
      {n, _} when n > 0 -> n
      _ -> nil
    end
  end

  @doc false
  # The result that is this title: out the same year (a year either side allowed, as release dates
  # differ between countries), named alike, and with a score. The plainest name wins.
  def pick(results, name, year) do
    wanted = squash(name)

    results
    |> Enum.filter(fn r ->
      r.score != nil and r.year != nil and abs(r.year - year) <= 1 and
        similar?(squash(r.name), wanted)
    end)
    |> Enum.sort_by(&{squash(&1.name) != wanted, abs(&1.year - year), String.length(&1.name)})
    |> List.first()
    |> case do
      nil ->
        nil

      r ->
        %{score: r.score, text: "#{r.score}/5", url: @base <> r.href, name: r.name}
    end
  end

  defp similar?(a, b), do: a == b or String.contains?(a, b) or String.contains?(b, a)

  # Names compared without spaces, marks or case.
  defp squash(name) do
    name |> String.downcase() |> String.replace(~r/[\s　\p{P}\p{S}]+/u, "")
  end
end
