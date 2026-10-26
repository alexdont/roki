defmodule Roki.SyncPush do
  @moduledoc """
  What the terminal app does reaches the site only when the site pulls from its sync store, and
  that used to wait for somebody to open a page. Now a push to the store (`RokiWeb.SyncApiController`)
  tells the account it belongs to to pull a few seconds later — one pull for a burst of pushes —
  so a film finished in the terminal is on the profile and in the activity feed within moments.
  """

  @settle_ms 4_000

  @doc "A document was stored under `token` (the laev key up to its first dot)."
  def notify(token) when is_binary(token) do
    Task.Supervisor.start_child(Roki.TaskSupervisor, fn ->
      with uuid when is_binary(uuid) <- account_for(token),
           false <- Roki.TTLCache.cached?({:push_pull, uuid}) do
        Roki.TTLCache.fetch({:push_pull, uuid}, 10, fn -> {:ok, :queued} end)
        # The terminal app sends several documents; let them all land first.
        Process.sleep(@settle_ms)
        Roki.TTLCache.delete({:sync_pull, uuid})
        RokiWeb.SyncPull.pull(uuid)
      end
    end)

    :ok
  end

  def notify(_token), do: :ok

  @doc "The connected account whose laev key has this token, or nil."
  def account_for(token) do
    Enum.find(Roki.Warm.accounts(), fn uuid ->
      case Roki.Laev.sync_key(uuid) do
        key when is_binary(key) -> key |> String.split(".", parts: 2) |> hd() == token
        _ -> false
      end
    end)
  end
end
