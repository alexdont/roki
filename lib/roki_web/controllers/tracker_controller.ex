defmodule RokiWeb.TrackerController do
  @moduledoc """
  MyAnimeList OAuth login (per-user). The owner provides the app
  credentials once (config); each user just clicks Connect and logs
  in on MAL's own page, so their reading syncs only to their own
  list. Tokens are stored per phoenix_kit user.
  """
  use RokiWeb, :controller

  alias Roki.Manga.Library
  alias Roki.Manga.Trackers.MAL

  @provider "mal"

  # Kick off the OAuth flow: stash PKCE verifier + CSRF state in the
  # session, redirect to MAL.
  def connect(conn, _params) do
    if MAL.oauth_ready?() do
      verifier = MAL.new_code_verifier()
      state = 32 |> :crypto.strong_rand_bytes() |> Base.url_encode64(padding: false)

      conn
      |> put_session(:mal_oauth_verifier, verifier)
      |> put_session(:mal_oauth_state, state)
      |> redirect(external: MAL.authorize_url(callback_url(conn), state, verifier))
    else
      conn
      |> put_flash(:error, "MyAnimeList isn't configured on this server yet.")
      |> redirect(to: ~p"/manga/settings")
    end
  end

  # MAL redirects back here with ?code & ?state.
  def callback(conn, %{"code" => code, "state" => state}) do
    session_state = get_session(conn, :mal_oauth_state)
    verifier = get_session(conn, :mal_oauth_verifier)

    conn =
      conn
      |> delete_session(:mal_oauth_state)
      |> delete_session(:mal_oauth_verifier)

    cond do
      is_nil(session_state) or is_nil(verifier) ->
        redirect_with(conn, :error, "Login session expired — try again.")

      not Plug.Crypto.secure_compare(state, session_state) ->
        redirect_with(conn, :error, "Login could not be verified — try again.")

      true ->
        case MAL.exchange_code(code, callback_url(conn), verifier) do
          {:ok, tokens} ->
            user = conn.assigns[:phoenix_kit_current_user]
            store_tokens(user.uuid, tokens)
            redirect_with(conn, :info, "MyAnimeList connected 🎉")

          {:error, _reason} ->
            redirect_with(conn, :error, "MyAnimeList login failed — try again.")
        end
    end
  end

  # User denied, or MAL returned an error.
  def callback(conn, _params) do
    redirect_with(conn, :error, "MyAnimeList login was cancelled.")
  end

  def disconnect(conn, _params) do
    user = conn.assigns[:phoenix_kit_current_user]
    Library.delete_tracker_token(user.uuid, @provider)
    redirect_with(conn, :info, "MyAnimeList disconnected.")
  end

  # ── helpers ───────────────────────────────────────────────────────

  defp store_tokens(user_id, tokens) do
    expires_at =
      case tokens.expires_in do
        s when is_integer(s) -> DateTime.utc_now() |> DateTime.add(s, :second)
        _ -> nil
      end

    Library.put_tracker_token(user_id, @provider, %{
      access_token: tokens.access_token,
      refresh_token: tokens.refresh_token,
      expires_at: expires_at,
      remote_username: MAL.username(tokens.access_token)
    })
  end

  # Pinned to config so it matches the MAL registration exactly
  # (deriving from the request is unreliable behind the proxy).
  defp callback_url(_conn) do
    Application.get_env(:roki, :mal_redirect_uri) ||
      url(~p"/manga/trackers/mal/callback")
  end

  defp redirect_with(conn, kind, msg) do
    conn |> put_flash(kind, msg) |> redirect(to: ~p"/manga/settings")
  end
end
