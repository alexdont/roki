defmodule Roki.Health do
  @moduledoc """
  Tells people when one of their logins stops working or is about to: a Real-Debrid or TorBox
  key that is rejected or whose premium is ending, a MyAnimeList or TMDB login that has expired.
  Otherwise they find out when playback or a rating fails.

  Every six hours each connected account's *own* keys are tried (keys lent by the site owner
  are the owner's to watch, and the owner's own account is checked like anyone's). What each
  person was last told is kept in `roki_health`, so a problem is told when it starts, again if
  it gets worse (premium within 7 days, then 3, then 1, then gone), and once more a week later if
  nothing was done, and not at every check. A key that works again clears it, so the next failure
  is news.

  A MyAnimeList or TMDB answer of "no" can also be a network hiccup, so those have to say it at
  two checks in a row. Real-Debrid and TorBox answer 401 or 403 outright, which is believed at
  once. A service that cannot be reached tells nothing either way.
  """
  use GenServer
  require Logger

  alias Roki.{Notify, Repo, Social}

  @first_ms 20 * 60 * 1000
  @every_ms 6 * 3600 * 1000
  @remind_after_days 7
  @labels %{"rd" => "Real-Debrid", "torbox" => "TorBox", "mal" => "MyAnimeList", "tmdb" => "TMDB"}

  def start_link(_opts), do: GenServer.start_link(__MODULE__, nil, name: __MODULE__)

  @impl true
  def init(_) do
    Process.send_after(self(), :check, @first_ms)
    {:ok, nil}
  end

  @impl true
  def handle_info(:check, state) do
    Task.Supervisor.start_child(Roki.TaskSupervisor, fn ->
      told = Enum.sum(for uuid <- Roki.Warm.accounts(), do: check(uuid))
      Logger.info("health: #{told} connection notices")
    end)

    Process.send_after(self(), :check, @every_ms)
    {:noreply, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @doc "Try one account's own logins and tell what is wrong. Returns how many were told."
  def check(uuid) do
    if Notify.wants?(uuid, "connection") do
      own = Laev.Config.read_dir(Roki.Laev.dir(uuid))

      results = [
        {"rd", if(blank?(own[:rd_token]), do: :none, else: rd(own[:rd_token]))},
        {"torbox", if(blank?(own[:torbox_api_key]), do: :none, else: torbox(own[:torbox_api_key]))},
        {"mal", Roki.Laev.run(uuid, &mal/0)},
        {"tmdb", Roki.Laev.run(uuid, &tmdb/0)}
      ]

      Enum.count(results, fn {service, result} -> settle(uuid, service, result) == :told end)
    else
      0
    end
  rescue
    e ->
      Logger.warning("health #{uuid}: #{Exception.message(e)}")
      0
  end

  defp blank?(v), do: v in [nil, ""]

  # ── asking each service ────────────────────────────────────────────

  @doc "Real-Debrid: `:ok`, `:unreachable`, or `{:bad, state}`."
  def rd(token) do
    case Req.get("https://api.real-debrid.com/rest/1.0/user", auth: {:bearer, token}, retry: false, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{} = body}} -> premium(body["expiration"], body["type"] == "premium")
      {:ok, %{status: 401}} -> {:bad, "rejected"}
      {:ok, %{status: 403}} -> {:bad, "locked"}
      _ -> :unreachable
    end
  end

  @doc "TorBox: `:ok`, `:unreachable`, or `{:bad, state}`. A free plan has nothing to expire."
  def torbox(key) do
    case Req.get("https://api.torbox.app/v1/api/user/me", auth: {:bearer, key}, retry: false, receive_timeout: 10_000) do
      {:ok, %{status: 200, body: %{"success" => true, "data" => data}}} ->
        if (data["plan"] || 0) == 0, do: :ok, else: premium(data["premium_expires_at"], true)

      {:ok, %{status: s}} when s in [401, 403] -> {:bad, "rejected"}
      _ -> :unreachable
    end
  end

  # How near the end of a premium is: fine, or one of the steps people are told at.
  @doc false
  def premium(expiration, premium?, now \\ DateTime.utc_now()) do
    days =
      with value when is_binary(value) <- expiration,
           {:ok, at, _} <- DateTime.from_iso8601(value) do
        DateTime.diff(at, now, :second) / 86_400
      else
        _ -> nil
      end

    cond do
      days != nil and days <= 0 -> {:bad, "expired"}
      not premium? -> {:bad, "expired"}
      days == nil -> :ok
      days <= 1 -> {:bad, "expiring:1"}
      days <= 3 -> {:bad, "expiring:3"}
      days <= 7 -> {:bad, "expiring:7"}
      true -> :ok
    end
  end

  @doc "MyAnimeList, inside the account's scope: connected but no longer answering as the person."
  def mal do
    cond do
      not Laev.MAL.authenticated?() -> :none
      Laev.MAL.username() != nil -> :ok
      true -> {:bad, "invalid"}
    end
  end

  @doc "TMDB, inside the account's scope: a session that TMDB no longer knows."
  def tmdb do
    cond do
      not Laev.Tmdb.account?() -> :none
      Laev.Tmdb.account_name() != nil -> :ok
      true -> {:bad, "invalid"}
    end
  end

  # ── what to do with an answer ──────────────────────────────────────

  @doc """
  Act on one service's answer for one person: tell them, or not. Returns `:told` or `:quiet`.
  """
  def settle(uuid, service, result) do
    bin = Ecto.UUID.dump!(uuid)
    row = Repo.query!("select state, told_at from roki_health where user_uuid = $1 and service = $2", [bin, service]).rows

    case {result, row} do
      {r, _} when r in [:unreachable, :none] ->
        # Nothing to say either way; a login that is not there is not a problem.
        if r == :none, do: clear(bin, service)
        :quiet

      {:ok, _} ->
        clear(bin, service)
        :quiet

      {{:bad, state}, []} ->
        if debounce?(service, state), do: remember(bin, service, "suspect:" <> state, false), else: tell(uuid, bin, service, state)

      {{:bad, state}, [["suspect:" <> state, _]]} ->
        tell(uuid, bin, service, state)

      {{:bad, state}, [[state, told_at]]} ->
        if NaiveDateTime.diff(NaiveDateTime.utc_now(), told_at, :second) >= @remind_after_days * 86_400,
          do: tell(uuid, bin, service, state),
          else: :quiet

      {{:bad, state}, [["suspect:" <> _, _]]} ->
        remember(bin, service, "suspect:" <> state, false)

      {{:bad, state}, _} ->
        tell(uuid, bin, service, state)
    end
  end

  # MyAnimeList and TMDB say "no" for a hiccup too.
  defp debounce?(service, _state), do: service in ["mal", "tmdb"]

  defp clear(bin, service), do: Repo.query!("delete from roki_health where user_uuid = $1 and service = $2", [bin, service])

  defp remember(bin, service, state, told?) do
    Repo.query!(
      """
      insert into roki_health (user_uuid, service, state, told_at) values ($1, $2, $3, now())
      on conflict (user_uuid, service) do update set state = excluded.state, told_at = excluded.told_at
      """,
      [bin, service, state]
    )

    if told?, do: :told, else: :quiet
  end

  defp tell(uuid, bin, service, state) do
    %{text: text, icon: icon} = notice(service, state)
    username = PhoenixKit.Users.Auth.get_user(uuid) |> then(&(&1 && &1.username))

    Social.notify_system(uuid, "connection", text, icon, if(username, do: "/#{username}/settings", else: "/"))
    remember(bin, service, state, true)
  end

  @doc "What the bell says for a service in a state."
  def notice(service, state) do
    label = Map.fetch!(@labels, service)

    text =
      case state do
        "rejected" -> "Your #{label} key was rejected, so nothing can play. Add a new one in settings."
        "locked" -> "Your #{label} account is locked or not premium. Check it on #{label}."
        "expired" -> "Your #{label} premium has ended. Renew it to keep playing."
        "expiring:1" -> "Your #{label} premium ends within a day."
        "expiring:3" -> "Your #{label} premium ends within 3 days."
        "expiring:7" -> "Your #{label} premium ends within 7 days."
        "invalid" -> "Your #{label} login stopped working. Connect it again in settings."
      end

    %{text: text, icon: if(String.starts_with?(state, "expiring"), do: "hero-clock", else: "hero-exclamation-triangle")}
  end
end
