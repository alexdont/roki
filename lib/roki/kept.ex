defmodule Roki.Kept do
  @moduledoc """
  Answers kept from TMDB beside the titles, so a title page is drawn from here: a season's
  episodes, a title's recommendations, a film collection. One row per answer (`kind` and
  `key`), as JSON, with when it was read and whether anything could still change — a season
  whose episodes have all aired is final and never read again; the rest is read again when it
  is older than its kind allows, and the old answer still serves while that fails.
  """

  alias Roki.Repo

  @doc """
  The kept answer for `kind`/`key`, or `fun.()`'s (`{:ok, data}`) kept for next time:
  `fresh_s` is how long an answer serves before it is read again; `final?` says of a fresh
  answer whether it is never to be read again.
  """
  def fetch(kind, key, fresh_s, fun, final? \\ fn _ -> false end) do
    case get(kind, key, fresh_s) do
      {:ok, data, true} ->
        {:ok, data}

      {:ok, old, false} ->
        case fun.() do
          {:ok, data} = ok ->
            put(kind, key, data, final?.(data))
            ok

          _ ->
            {:ok, old}
        end

      :none ->
        with {:ok, data} = ok <- fun.() do
          put(kind, key, data, final?.(data))
          ok
        end
    end
  rescue
    _ -> fun.()
  end

  @doc "A kept answer: `{:ok, data, fresh?}` or `:none`. `fresh_s` says how old is still fresh."
  def get(kind, key, fresh_s \\ nil)

  def get(kind, key, fresh_s) do
    case Repo.query!("select data, final, fetched_at from roki_kept where kind = $1 and key = $2", [kind, key]) do
      %{rows: [[data, final, fetched_at]]} ->
        data = if is_binary(data), do: Jason.decode!(data), else: data
        age = NaiveDateTime.diff(NaiveDateTime.utc_now(), fetched_at)
        {:ok, atomize(data), final or (is_integer(fresh_s) and age < fresh_s)}

      _ ->
        :none
    end
  end

  @doc "How many seconds ago an answer was read, or nil when none is kept."
  def age(kind, key) do
    case Repo.query!("select fetched_at from roki_kept where kind = $1 and key = $2", [kind, key]) do
      %{rows: [[fetched_at]]} -> NaiveDateTime.diff(NaiveDateTime.utc_now(), fetched_at)
      _ -> nil
    end
  end

  @doc "Keep an answer."
  def put(kind, key, data, final? \\ false) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    Repo.query!(
      """
      insert into roki_kept (kind, key, data, final, fetched_at) values ($1, $2, $3::jsonb, $4, $5)
      on conflict (kind, key) do update set data = excluded.data, final = excluded.final, fetched_at = excluded.fetched_at
      """,
      [kind, key, data, final? == true, now]
    )

    :ok
  end

  # Keys come back as strings; the ones the code wrote are atoms it has, the rest stay strings.
  defp atomize(%{} = map), do: Map.new(map, fn {k, v} -> {atom(k), atomize(v)} end)
  defp atomize(list) when is_list(list), do: Enum.map(list, &atomize/1)
  defp atomize(other), do: other

  defp atom(k) when is_binary(k) do
    String.to_existing_atom(k)
  rescue
    ArgumentError -> k
  end

  defp atom(k), do: k
end
