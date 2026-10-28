defmodule Roki.Manga.Trackers.MAL do
  @moduledoc """
  App adapter over the [`myanimelist`](https://hex.pm/packages/myanimelist)
  package. The API client itself lives in the hex package; this module
  holds the reader-specific bits that don't belong there:

    * app credentials + config → a `MyAnimeList.Client` (`:mal_client_id`,
      `:mal_client_secret`, `:mal_req_options` under `:roki`),
    * the reader's tierlist→score and media_type→reading-mode policy
      (`tier_score/1`, `reading_kind/1`),
    * the legacy token-map shape (`%{access_token, refresh_token,
      expires_in}`) the rest of the app persists.

  The reader is manga-only for now, so every call fixes `media` to `:manga`.
  Errors are values — this module never raises.
  """

  alias MyAnimeList.{Client, Token}

  @media :manga

  # ── credentials / config ──────────────────────────────────────────

  @doc "Owner-provided app credentials from config."
  def app_client_id, do: Application.get_env(:roki, :mal_client_id)
  def app_client_secret, do: Application.get_env(:roki, :mal_client_secret)

  defp req_options, do: Application.get_env(:roki, :mal_req_options, [])

  defp client(redirect_uri \\ nil) do
    %Client{
      client_id: app_client_id(),
      client_secret: app_client_secret(),
      redirect_uri: redirect_uri,
      req_options: req_options()
    }
  end

  @doc "True when the owner has configured the app credentials."
  def oauth_ready?, do: MyAnimeList.oauth_ready?(client())

  @doc "Whether a usable client id was provided."
  def configured?(client_id), do: MyAnimeList.configured?(client_id)

  @doc "Public MAL page for a manga id."
  def page_url(mal_id), do: MyAnimeList.page_url(@media, mal_id)

  # ── OAuth ─────────────────────────────────────────────────────────

  def new_code_verifier, do: MyAnimeList.new_code_verifier()

  def authorize_url(redirect_uri, state, code_verifier),
    do: MyAnimeList.authorize_url(client(redirect_uri), state, code_verifier)

  @doc "Exchange an authorization code for the legacy token map."
  def exchange_code(code, redirect_uri, code_verifier) do
    client(redirect_uri)
    |> MyAnimeList.exchange_code(code, code_verifier)
    |> to_legacy_token()
  end

  @doc "Refresh an access token, returning the legacy token map."
  def refresh_token(refresh_token) do
    client()
    |> MyAnimeList.refresh_token(refresh_token)
    |> to_legacy_token()
  end

  # The app persists `%{access_token, refresh_token, expires_in}`; the
  # package returns a `%MyAnimeList.Token{}` with an absolute `expires_at`.
  defp to_legacy_token({:ok, %Token{access_token: at, refresh_token: rt, expires_at: exp}}) do
    {:ok, %{access_token: at, refresh_token: rt, expires_in: to_expires_in(exp)}}
  end

  defp to_legacy_token(other), do: other

  defp to_expires_in(%DateTime{} = exp), do: max(DateTime.diff(exp, DateTime.utc_now()), 0)
  defp to_expires_in(_), do: nil

  # ── public data ───────────────────────────────────────────────────

  def search(query, client_id, limit \\ 10),
    do: MyAnimeList.search(@media, query, client_id, limit: limit, req_options: req_options())

  def get_manga(mal_id, client_id),
    do: MyAnimeList.get(@media, mal_id, client_id, req_options: req_options())

  # ── list sync ─────────────────────────────────────────────────────

  @doc "The user's current chapters-read for a manga (0 if unknown)."
  def my_chapters_read(access_token, mal_id) do
    case MyAnimeList.my_progress(@media, access_token, mal_id, req_options: req_options()) do
      {:ok, n} -> n
      _ -> 0
    end
  end

  def list_statuses(access_token),
    do: MyAnimeList.list_statuses(@media, access_token, req_options: req_options())

  def list_scores(access_token),
    do: MyAnimeList.list_scores(@media, access_token, req_options: req_options())

  def username(access_token),
    do: MyAnimeList.username(access_token, req_options: req_options())

  def update_list_status(access_token, mal_id, fields),
    do:
      MyAnimeList.update_list_status(@media, access_token, mal_id, fields,
        req_options: req_options()
      )

  # ── display helpers (delegated) ───────────────────────────────────

  defdelegate status_label(status), to: MyAnimeList
  defdelegate year_range(from_year, to_year), to: MyAnimeList

  # ── reader-specific policy (stays in the app) ─────────────────────

  @doc """
  App tierlist tier → MAL score (0–10). The reader's tierlist doubles
  as the user's rating: S+/S = 10, then straight down A=9…E=5. The
  non-ranking tiers ("want", "unknown", "pool") and untiered titles
  map to `nil` — no score is sent, so they never overwrite an
  existing MAL rating.
  """
  def tier_score("sp"), do: 10
  def tier_score("s"), do: 10
  def tier_score("a"), do: 9
  def tier_score("b"), do: 8
  def tier_score("c"), do: 7
  def tier_score("d"), do: 6
  def tier_score("e"), do: 5
  def tier_score(_), do: nil

  @doc """
  MAL manga media_type → reading kind: strip formats (Korean/Chinese
  webtoons) read as vertical `"scroll"`, book formats as `"paged"`.
  Anything else (oel, novels, nil) returns nil — defer to other signals.
  """
  def reading_kind(t) when t in ["manhwa", "manhua"], do: "scroll"
  def reading_kind(t) when t in ["manga", "one_shot", "doujinshi"], do: "paged"
  def reading_kind(_), do: nil
end
