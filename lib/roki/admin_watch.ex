defmodule Roki.AdminWatch do
  @moduledoc """
  What the site's owner is told about the site itself (the owner is the account named under
  Admin → API access, `Roki.Keys.config/0`):

    * a new account was made: "New account: max";
    * an account that borrows the owner's keys used up its daily plays: "max reached today's
      limit of 20 plays", once a day for each.

  Checked every hour. Nothing is told about the first run, only about what comes after it, and
  nothing about the owner's own account.
  """
  use GenServer
  require Logger

  alias Roki.{Keys, Releases, Social}

  @first_ms 25 * 60 * 1000
  @every_ms 3600 * 1000
  @marker "roki_signup_marker"

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    Process.send_after(self(), :check, @first_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:check, state) do
    Task.Supervisor.start_child(Roki.TaskSupervisor, fn -> check() end)
    Process.send_after(self(), :check, @every_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Look at the site and tell its owner what is new. Returns how many were told."
  def check(today \\ Date.utc_today()) do
    case Keys.config().owner_uuid do
      nil -> 0
      owner -> signups(owner) + limits(owner, today)
    end
  rescue
    e ->
      Logger.warning("admin watch: #{Exception.message(e)}")
      0
  end

  @doc "Tell `owner` about the accounts made since the last look. The first look only marks the time."
  def signups(owner) do
    marker = PhoenixKit.Settings.get_setting(@marker, nil)
    now = DateTime.utc_now() |> DateTime.truncate(:second)

    case marker && DateTime.from_iso8601(marker) do
      {:ok, since, _offset} ->
        %{rows: rows} =
          Roki.Repo.query!(
            "select uuid, username, inserted_at from phoenix_kit_users where inserted_at > $1 order by inserted_at",
            [since]
          )

        PhoenixKit.Settings.update_setting(
          @marker,
          DateTime.to_iso8601(rows |> List.last() |> then(&if(&1, do: Enum.at(&1, 2), else: now)))
        )

        Enum.count(rows, fn [uuid, username, _at] ->
          Ecto.UUID.load!(uuid) != owner and
            Social.notify_system(
              owner,
              "new_account",
              "New account: #{username}",
              "hero-user-plus",
              "/u/#{username}/profile"
            ) == :ok
        end)

      _ ->
        PhoenixKit.Settings.update_setting(@marker, DateTime.to_iso8601(now))
        0
    end
  end

  @doc "Tell `owner` which accounts reached their daily plays today, once each."
  def limits(owner, today \\ Date.utc_today()) do
    Keys.all_grants()
    |> Enum.filter(fn {uuid, grant} ->
      uuid != owner and is_integer(grant.daily_plays) and
        Keys.plays_today(uuid) >= grant.daily_plays
    end)
    |> Enum.count(fn {uuid, grant} ->
      name = PhoenixKit.Users.Auth.get_user(uuid) |> then(&((&1 && &1.username) || "An account"))

      Releases.claim(
        uuid,
        "limit",
        today.year * 10_000 + today.month * 100 + today.day,
        0,
        0,
        "limit"
      ) and
        Social.notify_system(
          owner,
          "limit",
          "#{name} reached today's limit of #{grant.daily_plays} plays",
          "hero-exclamation-triangle",
          "/phoenix_kit/admin/api-access"
        ) == :ok
    end)
  end
end
