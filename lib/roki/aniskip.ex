defmodule Roki.AniSkip do
  @moduledoc """
  Opening and ending times for an anime episode from AniSkip (https://api.aniskip.com), a
  community database keyed by MyAnimeList id and the episode's number inside that MAL entry.

  `times/2` is `{:ok, [%{kind: "op" | "ed", from:, to:, length:}]}` — `length` is the episode
  length of the file the times were measured on, so the player can drop times from a cut of a
  different length. An episode AniSkip does not know is `{:ok, []}`, and is remembered as such.
  Cached a day; a budget of 60 lookups a minute for the whole site. Off when
  `config :roki, aniskip_offline: true` (the test suite).
  """

  alias Roki.{RateLimit, TTLCache}

  @base "https://api.aniskip.com/v2/skip-times"
  @ttl 86_400
  @kinds %{"op" => "op", "ed" => "ed", "mixed-op" => "op", "mixed-ed" => "ed"}

  def times(mal_id, episode) when is_integer(mal_id) and is_integer(episode) and episode > 0 do
    if Application.get_env(:roki, :aniskip_offline, false) do
      {:ok, []}
    else
      TTLCache.fetch({:aniskip, mal_id, episode}, @ttl, fn -> fetch(mal_id, episode) end)
    end
  end

  def times(_, _), do: {:ok, []}

  defp fetch(mal_id, episode) do
    with :ok <- RateLimit.check(:aniskip, :all, 60, 60_000) do
      url =
        "#{@base}/#{mal_id}/#{episode}?types[]=op&types[]=ed&types[]=mixed-op&types[]=mixed-ed&episodeLength=0"

      case Req.get(url, receive_timeout: 8_000, retry: false) do
        {:ok, %{status: 200, body: body}} -> {:ok, parse(body)}
        {:ok, %{status: 404}} -> {:ok, []}
        {:ok, %{status: status}} -> {:error, {:http, status}}
        {:error, reason} -> {:error, reason}
      end
    end
  end

  @doc false
  def parse(%{"results" => results}) when is_list(results) do
    for %{"interval" => %{"startTime" => a, "endTime" => b}, "skipType" => type} = r <- results,
        kind = @kinds[type],
        is_number(a) and is_number(b) and b > a do
      %{kind: kind, from: a * 1.0, to: b * 1.0, length: num(r["episodeLength"])}
    end
  end

  def parse(_), do: []

  defp num(n) when is_number(n), do: n * 1.0
  defp num(_), do: 0.0
end
