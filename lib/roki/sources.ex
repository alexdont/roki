defmodule Roki.Sources do
  @moduledoc """
  What an account can play from: `%{torrent: bool, pengu: bool}`. Torrents need a Real-Debrid or
  TorBox key (its own, or lent); PenguPlay needs a link of its own or the owner's lent one. The
  sources page and the account menu both draw their switches from this — a kind that is not
  there is greyed out and points to Settings.

  Kept for a few seconds, because the account menu is drawn on every page; whatever changes the
  answer (a key saved, a link pasted, something lent or taken back) calls `forget/1`.
  """

  alias Roki.TTLCache

  @ttl 15

  @doc "`%{torrent: bool, pengu: bool}` for this account (both false for nobody)."
  def available(uuid) when is_binary(uuid) do
    {:ok, avail} =
      TTLCache.fetch({:sources_avail, uuid}, @ttl, fn ->
        {:ok, %{torrent: Roki.Laev.debrid?(uuid), pengu: Roki.Pengu.configured?(uuid)}}
      end)

    avail
  end

  def available(_), do: %{torrent: false, pengu: false}

  def forget(uuid) when is_binary(uuid), do: TTLCache.delete({:sources_avail, uuid})
  def forget(_), do: :ok

  @doc """
  The kind to show as the account's choice: its "Play from" setting, unless nothing is connected
  for that and the other kind is.
  """
  def current(uuid, avail) do
    wanted = if uuid && Roki.Laev.web_settings(uuid)["play_from"] == "pengu", do: :pengu, else: :torrent
    other = if wanted == :pengu, do: :torrent, else: :pengu
    if not avail[wanted] and avail[other], do: other, else: wanted
  end
end
