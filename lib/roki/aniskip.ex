defmodule Roki.AniSkip do
  @moduledoc """
  Opening and ending times for an anime episode from AniSkip (https://api.aniskip.com), a
  community database keyed by MyAnimeList id and the episode's number inside that MAL entry —
  asked through the `aniskip` package, with the site's own care around it.

  `times/2` is `{:ok, [%{kind: "op" | "ed", from:, to:, length:}]}` — `length` is the episode
  length of the file the times were measured on, so the player can drop times from a cut of a
  different length (`aniskipSkips` in cues.js). An episode AniSkip does not know is `{:ok, []}`,
  and is remembered as such. Cached a day; a budget of 60 lookups a minute for the whole site.
  Off when `config :roki, aniskip_offline: true` (the test suite).
  """

  alias Roki.{RateLimit, TTLCache}

  @ttl 86_400

  def times(mal_id, episode) when is_integer(mal_id) and is_integer(episode) and episode > 0 do
    if Application.get_env(:roki, :aniskip_offline, false) do
      {:ok, []}
    else
      TTLCache.fetch({:aniskip, mal_id, episode}, @ttl, fn -> fetch(mal_id, episode) end)
    end
  end

  def times(_, _), do: {:ok, []}

  defp fetch(mal_id, episode) do
    with :ok <- RateLimit.check(:aniskip, :all, 60, 60_000),
         {:ok, times} <- AniSkip.times(mal_id, episode) do
      {:ok, Enum.map(times, &for_player/1)}
    end
  end

  @doc false
  # The package's times in the shape the player's JS reads: string kinds, a length of 0.0 when
  # none was recorded.
  def parse(body), do: body |> AniSkip.parse() |> Enum.map(&for_player/1)

  defp for_player(%{kind: kind, from: from, to: to, length: length}),
    do: %{kind: Atom.to_string(kind), from: from, to: to, length: length || 0.0}
end
