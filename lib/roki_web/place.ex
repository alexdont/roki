defmodule RokiWeb.Place do
  @moduledoc """
  Where a reader was on a "Load more" list when they left it: the browser sends it with the join
  (`place`: pages loaded and scroll position) only when they came back with the back button, and
  the page then loads all of those pages at once instead of one at a time.
  """

  @max_pages 10

  @doc "`%{pages: n, y: px}` from the join params, or nil."
  def from_params(socket) do
    params =
      if Phoenix.LiveView.connected?(socket),
        do: Phoenix.LiveView.get_connect_params(socket),
        else: nil

    case params && params["place"] do
      %{"pages" => pages, "y" => y} when is_number(pages) and is_number(y) and y >= 0 ->
        %{pages: pages |> round() |> max(1) |> min(@max_pages), y: round(y)}

      _ ->
        nil
    end
  end

  @doc "The loaded pages `1..last`, fetched concurrently and joined in order. `fun` takes a page number."
  def pages(last, fun) when last > 1 do
    1..last
    |> Task.async_stream(fun, max_concurrency: 4, timeout: 30_000, ordered: true)
    |> Enum.map(fn
      {:ok, result} -> result
      {:exit, reason} -> {:error, reason}
    end)
  end
end
