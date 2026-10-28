defmodule Roki.Grid do
  @moduledoc """
  The grid for the things this site knows about — films, shows and anime — beside the reader's
  own (`Roki.Manga.Library`), which keeps its table.

  Fifteen named places per board, filled by hand: "Favorite", "Best Ending", "Worst". Nothing
  is filled in for you, by rating or by anything else; an empty board is the point until
  somebody says otherwise.

  The boards are Overall, Movies, Shows and Anime here, and Manga and Manhwa in the reader.
  Overall holds either kind, which is why one place there is cleared on both sides before it is
  set on one.
  """
  alias Roki.Repo

  @modes ~w(overall movie tv anime)
  @slots 15

  @labels [
    "Favorite",
    "Best Looking",
    "First One",
    "Watching Now",
    "Best Villain",
    "Best Plot Twist",
    "Underrated Gem",
    "Comfort Watch",
    "Best Scene",
    "Most Emotional",
    "Best Ending",
    "Best Opening",
    "Best Comeback",
    "Most Rewatched",
    "Worst"
  ]

  @doc "The boards this side keeps."
  def modes, do: @modes

  @doc "How many places a board has."
  def slots, do: @slots

  @doc """
  The fifteen places of a board, in order, each `%{slot:, label:, type:, id:}` with `type` nil
  where nothing has been put. Missing places are written as they are first looked at, the way
  the reader's own board does it.
  """
  def board(uuid, mode) when mode in @modes do
    {:ok, bin} = Ecto.UUID.dump(uuid)

    %{rows: rows} =
      Repo.query!(
        "select slot, label, type, id from roki_grid_slots where user_uuid = $1 and mode = $2 order by slot",
        [bin, mode]
      )

    if length(rows) == @slots do
      for [slot, label, type, id] <- rows,
          do: %{slot: slot, label: label, type: type, id: id}
    else
      seed(bin, mode, MapSet.new(rows, &hd/1))
      board(uuid, mode)
    end
  end

  defp seed(bin, mode, taken) do
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    for n <- 1..@slots, not MapSet.member?(taken, n) do
      Repo.query!(
        "insert into roki_grid_slots (user_uuid, mode, slot, label, inserted_at, updated_at) " <>
          "values ($1, $2, $3, $4, $5, $5)",
        [bin, mode, n, Enum.at(@labels, n - 1), now]
      )
    end
  end

  @doc "Put a title in a place, or empty it with `nil`."
  def set(uuid, mode, slot, key) when mode in @modes and slot in 1..@slots do
    {:ok, bin} = Ecto.UUID.dump(uuid)
    board(uuid, mode)
    now = DateTime.utc_now() |> DateTime.truncate(:second)
    {type, id} = key || {nil, nil}

    Repo.query!(
      "update roki_grid_slots set type = $4, id = $5, updated_at = $6 " <>
        "where user_uuid = $1 and mode = $2 and slot = $3",
      [bin, mode, slot, type, id, now]
    )

    :ok
  end

  @doc "Empty one place without saying what goes there — what the other side does before it sets one."
  def clear(uuid, mode, slot) when mode in @modes and slot in 1..@slots,
    do: set(uuid, mode, slot, nil)
end
