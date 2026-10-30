defmodule Roki.Reviews do
  @moduledoc """
  What others made of a title, for the Reviews sheet on its page: the scores of the services that
  rate (Rotten Tomatoes, Metacritic, Letterboxd, Trakt, IMDb, TMDB, Roger Ebert, MyAnimeList,
  and Filmarks from `Roki.Filmarks`) and
  a short account of how the critics received it.

  The scores come from MDBList, which answers for a TMDB id with every service's number in one
  call. The account is the opening of the title's Wikipedia article on its reception (CC BY-SA, so
  it is shown with where it is from): the article is found through Wikidata, which links a TMDB id
  to its Wikipedia page. Both are kept a day, and a title with nothing is kept as that, so a page
  of such titles is not a page of requests.
  """

  alias Roki.TTLCache

  @ttl_s 24 * 3600
  @ua "roki.ee/1.0 (title pages; https://roki.ee)"
  @sections [
    "Critical response",
    "Critical reception",
    "Reception",
    "Critical reaction",
    "Reviews"
  ]
  @max_chars 1800

  @doc "Is there a key to ask MDBList with?"
  def configured?, do: key() != nil

  defp key do
    case System.get_env("MDBLIST_API_KEY") do
      k when is_binary(k) and k != "" -> k
      _ -> from_file()
    end
  end

  # The key as it is kept on the data volume until the container has been recreated with it in
  # its environment.
  defp from_file do
    case File.read(Path.join(System.user_home!(), ".roki/mdblist_key")) do
      {:ok, k} -> if String.trim(k) != "", do: String.trim(k)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  @doc """
  The scores: `[%{source, label, who, text, votes, url}]`, best known first, empty when MDBList has none
  (or there is no key). `type` is `"movie"` or `"tv"`.
  """
  def scores(type, id, opts \\ []) when type in ["movie", "tv"] and is_integer(id) do
    # Filmarks is a slower, separate lookup: asked alongside, and left out if it is not back in time.
    filmarks =
      Task.async(fn ->
        Roki.Filmarks.score(type, id, Keyword.get(opts, :anime?, false), opts[:uuid])
      end)

    base =
      case TTLCache.fetch({:mdblist, type, id}, @ttl_s, fn -> fetch_scores(type, id) end) do
        {:ok, list} -> list
        _ -> []
      end

    extra =
      case Task.yield(filmarks, 12_000) || Task.shutdown(filmarks) do
        {:ok, %{score: score, url: url}} ->
          [
            %{
              source: "filmarks",
              order: 11,
              label: "Filmarks",
              who: "Members",
              text: "#{Float.round(score * 1.0, 1)}/5",
              votes: nil,
              url: url
            }
          ]

        _ ->
          []
      end

    Enum.sort_by(base ++ extra, & &1.order)
  end

  defp fetch_scores(type, id) do
    with k when is_binary(k) <- key(),
         {:ok, %{status: 200, body: %{"ratings" => ratings}}} <-
           Req.get(
             "https://api.mdblist.com/tmdb/#{if type == "movie", do: "movie", else: "show"}/#{id}",
             params: [apikey: k],
             retry: false,
             receive_timeout: 6_000
           ) do
      {:ok, ratings |> Enum.map(&tile/1) |> Enum.reject(&is_nil/1) |> Enum.sort_by(& &1.order)}
    else
      {:ok, %{status: 404}} -> {:ok, []}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # source → {order, name, who, how to write the number}
  @sources %{
    "tomatoes" => {1, "Rotten Tomatoes", "Critics", :percent},
    "popcorn" => {2, "Rotten Tomatoes", "Audience", :percent},
    "metacritic" => {3, "Metacritic", "Critics", :plain},
    "metacriticuser" => {4, "Metacritic", "Users", :plain},
    "imdb" => {5, "IMDb", "Members", {:out_of, 10}},
    "letterboxd" => {6, "Letterboxd", "Members", {:out_of, 5}},
    "trakt" => {7, "Trakt", "Members", :percent},
    "tmdb" => {8, "TMDB", "Members", :percent},
    "myanimelist" => {9, "MyAnimeList", "Members", {:out_of, 10}},
    "rogerebert" => {10, "Roger Ebert", "Critic", {:out_of, 4}}
  }

  defp tile(%{"source" => source, "value" => value} = r) when is_number(value) do
    with {order, label, who, how} <- @sources[source] do
      %{
        source: source,
        order: order,
        label: label,
        who: who,
        text: number(value, how),
        votes: if(is_integer(r["votes"]) and r["votes"] > 0, do: r["votes"]),
        url: nil
      }
    else
      _ -> nil
    end
  end

  defp tile(_), do: nil

  defp number(v, :percent), do: "#{round(v)}%"
  defp number(v, :plain), do: trim(v)
  defp number(v, {:out_of, n}), do: "#{trim(v)}/#{n}"

  defp trim(v) when is_float(v),
    do: :erlang.float_to_binary(v, decimals: 1) |> String.replace_suffix(".0", "")

  defp trim(v), do: to_string(v)

  @doc """
  How the critics received it: `%{paragraphs: [text], url: article_url, title: article_title}` or nil.
  """
  def critics(type, id) when type in ["movie", "tv"] and is_integer(id) do
    case TTLCache.fetch({:critics, type, id}, @ttl_s, fn -> fetch_critics(type, id) end) do
      {:ok, %{} = c} -> c
      _ -> nil
    end
  end

  defp fetch_critics(type, id) do
    prop = if type == "movie", do: "P4947", else: "P4983"

    with {:ok, page} <- wikipedia_page(prop, id),
         {:ok, paragraphs} <- reception(page) do
      {:ok,
       %{
         paragraphs: paragraphs,
         title: page,
         url: "https://en.wikipedia.org/wiki/" <> URI.encode(String.replace(page, " ", "_"))
       }}
    else
      :none -> {:ok, nil}
      _ -> :error
    end
  rescue
    _ -> :error
  end

  # The English Wikipedia page Wikidata links to the TMDB id.
  defp wikipedia_page(prop, id) do
    query =
      ~s|SELECT ?article WHERE { ?item wdt:#{prop} "#{id}". ?article schema:about ?item; schema:isPartOf <https://en.wikipedia.org/> } LIMIT 1|

    case Req.get("https://query.wikidata.org/sparql",
           params: [query: query, format: "json"],
           headers: [{"user-agent", @ua}, {"accept", "application/sparql-results+json"}],
           retry: false,
           receive_timeout: 8_000
         ) do
      {:ok,
       %{
         status: 200,
         body: %{"results" => %{"bindings" => [%{"article" => %{"value" => url}} | _]}}
       }} ->
        {:ok,
         url
         |> String.replace_prefix("https://en.wikipedia.org/wiki/", "")
         |> URI.decode()
         |> String.replace("_", " ")}

      {:ok, %{status: 200}} ->
        :none

      _ ->
        :error
    end
  end

  defp reception(page) do
    with {:ok, sections} <- wiki(action: "parse", page: page, prop: "sections"),
         %{"index" => index} <- pick_section(sections["parse"]["sections"] || []),
         {:ok, body} <- wiki(action: "parse", page: page, section: index, prop: "text"),
         html when is_binary(html) <- get_in(body, ["parse", "text", "*"]),
         [_ | _] = paragraphs <- paragraphs(html) do
      {:ok, paragraphs}
    else
      _ -> :none
    end
  end

  defp pick_section(sections) do
    Enum.find_value(@sections, fn name -> Enum.find(sections, &(&1["line"] == name)) end)
  end

  defp wiki(params) do
    case Req.get("https://en.wikipedia.org/w/api.php",
           params: [format: "json", redirects: 1] ++ params,
           headers: [{"user-agent", @ua}],
           retry: false,
           receive_timeout: 8_000
         ) do
      {:ok, %{status: 200, body: %{} = body}} -> {:ok, body}
      _ -> :error
    end
  end

  # The text of a section's paragraphs, with the footnote marks and the markup taken out, up to
  # a few screens' worth.
  @doc false
  def paragraphs(html) do
    {:ok, doc} = Floki.parse_fragment(html)

    doc
    |> Floki.filter_out("sup, style, table, .mw-editsection, .reference")
    |> Floki.find("p")
    |> Enum.map(fn p ->
      p
      |> Floki.text()
      |> String.replace(~r/\[\d+\]/, "")
      |> String.replace(~r/\s+/, " ")
      # A footnote taken out can leave two sentences touching.
      |> String.replace(~r/(?<=[a-z\)"”][.!?])(?=[A-Z])/u, " ")
      |> String.trim()
    end)
    |> Enum.reject(&(String.length(&1) < 40))
    |> take_chars(@max_chars)
  end

  defp take_chars(paragraphs, max) do
    {taken, _} =
      Enum.reduce_while(paragraphs, {[], 0}, fn p, {acc, n} ->
        cond do
          acc == [] -> {:cont, {[p], String.length(p)}}
          n + String.length(p) > max -> {:halt, {acc, n}}
          true -> {:cont, {acc ++ [p], n + String.length(p)}}
        end
      end)

    taken
  end
end
