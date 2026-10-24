defmodule Roki.Watch.Checks do
  @moduledoc """
  The releases being checked, as the page shows them: each one `:checking`, then `:ok` or
  `{:bad, why}` — or `{:later, note}` for one not waited for because enough others already played. The probe task sends `{:candidates, token, list}` when a round starts and
  `{:checked, token, hash, state}` as each answer comes in; a page keeps the list with these.
  """

  alias Roki.Watch
  alias Roki.Watch.Resolver

  @doc "What the page needs to draw a release in the list."
  def summary(source) do
    %{
      hash: source.hash,
      name: source.name,
      resolution: Resolver.label(source.resolution),
      state: :checking
    }
  end

  @doc "A new round's releases, after the ones already listed."
  def add(checks, candidates) do
    known = MapSet.new(checks, & &1.hash)
    checks ++ Enum.reject(candidates, &MapSet.member?(known, &1.hash))
  end

  def mark(checks, hash, state),
    do: Enum.map(checks, fn c -> if c.hash == hash, do: %{c | state: state}, else: c end)

  @doc "A short reason a release did not work, for the page."
  def why({:error, reason}), do: Watch.why(reason)
  def why(other), do: Watch.why(other)
end
