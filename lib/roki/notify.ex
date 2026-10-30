defmodule Roki.Notify do
  @moduledoc """
  Which kinds of notification a person wants. Each kind has a default; a person's own choice
  (the Settings page) is kept in `roki_notify_prefs` and wins. Friend requests and replies to
  your own comments are not here: someone is addressing you, so they always arrive.
  """

  alias Roki.Repo

  # key, label, what it is, on unless chosen otherwise
  @kinds [
    {"release", "New episodes and releases",
     "A new episode of a show or anime you saved or are following, a saved film reaching theaters or digital.",
     true},
    {"season", "New seasons", "A show you saved or follow gets a new season with a date.", true},
    {"digest", "Your week ahead", "One summary on Sundays of what comes out in the coming week.",
     true},
    {"comments", "Comments", "Likes on your comments, and being mentioned in one.", true},
    {"connection", "Connection problems",
     "A Real-Debrid, TorBox, MyAnimeList or TMDB login that stopped working or is about to.",
     true},
    {"link", "Linked progress",
     "A friend marked an episode for you on a show you have linked (one note per show every ten minutes).",
     true},
    {"friend_activity", "What friends do",
     "A friend finished a film or rated something. Can be a lot, so it starts off.", false}
  ]

  @doc "The kinds, in order: `[{key, label, description, default}]`."
  def kinds, do: @kinds

  @doc "Does this person want this kind of notification?"
  def wants?(uuid, key) when is_binary(uuid) do
    case Repo.query!("select enabled from roki_notify_prefs where user_uuid = $1 and key = $2", [
           Ecto.UUID.dump!(uuid),
           key
         ]).rows do
      [[enabled]] -> enabled
      _ -> default(key)
    end
  end

  def wants?(_uuid, key), do: default(key)

  @doc "Every kind with what this person has chosen (or the default): `%{key => boolean}`."
  def choices(uuid) do
    chosen =
      Repo.query!("select key, enabled from roki_notify_prefs where user_uuid = $1", [
        Ecto.UUID.dump!(uuid)
      ]).rows
      |> Map.new(fn [k, e] -> {k, e} end)

    Map.new(@kinds, fn {key, _, _, default} -> {key, Map.get(chosen, key, default)} end)
  end

  @doc "Choose: want this kind (`true`) or not."
  def set(uuid, key, enabled) when is_boolean(enabled) do
    if Enum.any?(@kinds, &(elem(&1, 0) == key)) do
      Repo.query!(
        """
        insert into roki_notify_prefs (user_uuid, key, enabled) values ($1, $2, $3)
        on conflict (user_uuid, key) do update set enabled = excluded.enabled
        """,
        [Ecto.UUID.dump!(uuid), key, enabled]
      )

      :ok
    else
      {:error, :unknown_kind}
    end
  end

  # (Not `find_value`: a default of `false` would read as "no answer" and come out `true`.)
  defp default(key) do
    case Enum.find(@kinds, &(elem(&1, 0) == key)) do
      {_key, _label, _description, default} -> default
      nil -> true
    end
  end
end
