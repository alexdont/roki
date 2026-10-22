defmodule RokiWeb.DictController do
  @moduledoc """
  `/dict/:lang?q=word` — what a word in the subtitles means (see `Roki.Dictionary`), as JSON,
  for the study player. Signed-in users only, and rate-limited: a lookup can reach a public
  dictionary, and this site should not be what hammers it.
  """
  use RokiWeb, :controller

  def show(conn, %{"lang" => lang, "q" => q}) do
    case conn.assigns[:phoenix_kit_current_user] do
      nil ->
        send_resp(conn, 401, "sign in")

      user ->
        case Roki.RateLimit.check(:dict, {:user, user.uuid}, 240, 60_000) do
          :ok ->
            case Roki.Dictionary.lookup(lang, q) do
              {:ok, result} -> json(conn, result)
              {:error, _} -> conn |> put_status(502) |> json(%{entries: [], error: "unavailable"})
            end

          {:error, {:rate_limited, secs}} ->
            conn
            |> put_resp_header("retry-after", to_string(secs))
            |> put_status(429)
            |> json(%{entries: []})
        end
    end
  end

  def show(conn, _params), do: send_resp(conn, 400, "bad request")
end
