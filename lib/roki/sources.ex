defmodule Roki.Sources do
  @moduledoc """
  What an account can play from, as three independent collections:

    * `:torrent` — the original source system: releases your Real-Debrid or TorBox account streams;
    * `:pengu` — plain https streams from a PenguPlay addon link;
    * `:nuvio` — providers discovered from the All-in-One-Nuvio manifest and run in the
      Nuvio sandbox, only when the account enabled and acknowledged them.

  The sources page and the account menu both draw their switches from this — a kind that is not
  there is greyed out and points to Settings. Each kind is configured on its own: a debrid key,
  a PenguPlay link, and a set of Nuvio providers respectively.

  Kept for a few seconds, because the account menu is drawn on every page; whatever changes the
  answer (a key saved, a link pasted, something lent or taken back, a Nuvio provider toggled)
  calls `forget/1`.
  """

  alias Roki.TTLCache

  @ttl 15

  @doc "`%{torrent: bool, pengu: bool, nuvio: bool}` for this account (all false for nobody)."
  def available(uuid) when is_binary(uuid) do
    {:ok, avail} =
      TTLCache.fetch({:sources_avail, uuid}, @ttl, fn ->
        {:ok,
         %{
           torrent: Roki.Laev.debrid?(uuid),
           pengu: Roki.Pengu.configured?(uuid),
           nuvio: Roki.Nuvio.configured?(uuid)
         }}
      end)

    avail
  end

  def available(_), do: %{torrent: false, pengu: false, nuvio: false}

  def forget(uuid) when is_binary(uuid), do: TTLCache.delete({:sources_avail, uuid})
  def forget(_), do: :ok

  @kinds [:torrent, :pengu, :nuvio]

  @doc """
  The kind to show as the account's choice: its "Play from" setting, unless nothing is connected
  for that and another kind is. Old behaviour (torrent first, then PenguPlay) is kept when the
  new key is absent from a caller's map.
  """
  def current(uuid, avail) do
    wanted =
      case uuid && Roki.Laev.web_settings(uuid)["play_from"] do
        "pengu" -> :pengu
        "nuvio" -> :nuvio
        _ -> :torrent
      end

    if available_kind?(avail, wanted),
      do: wanted,
      else: Enum.find(@kinds, wanted, &available_kind?(avail, &1))
  end

  defp available_kind?(avail, kind), do: Map.get(avail, kind, false) == true
end
