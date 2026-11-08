defmodule RokiWeb.StreamToken do
  @moduledoc """
  A stream address that needs no sign-in: `/stream/t/<token>/<id>/playlist.m3u8`.

  AirPlay hands the video element's own address to the Apple TV (or a HomePod), which then
  fetches the playlist, its segments, audio renditions and subtitle pieces by itself — with no
  cookie, so the cookie-only `/stream/<id>/...` answers it 401 and the TV shows nothing. The
  player is therefore given the playlist under a signed token instead: it names the remux and
  the account (whose language picks the default audio), is good for a day (laev sweeps a remux
  after one anyway), and since every playlist only uses relative names, everything under it
  inherits the token. A token for one remux opens no other. The page's own requests — the
  subtitle files it draws the lines from — keep the cookie address.
  """

  @salt "stream"
  @max_age 24 * 3600

  def sign(uuid, id) when is_binary(uuid) and is_binary(id),
    do: Phoenix.Token.sign(RokiWeb.Endpoint, @salt, %{"u" => uuid, "id" => id})

  @doc "The address the player loads, for this account and remux."
  def path(uuid, id, file \\ "playlist.m3u8"), do: "/stream/t/#{sign(uuid, id)}/#{id}/#{file}"

  @doc "`{:ok, uuid}` when `token` was signed for `id` within the day, else `:error`."
  def verify(token, id) when is_binary(token) and is_binary(id) do
    case Phoenix.Token.verify(RokiWeb.Endpoint, @salt, token, max_age: @max_age) do
      {:ok, %{"u" => uuid, "id" => ^id}} when is_binary(uuid) -> {:ok, uuid}
      _ -> :error
    end
  end

  def verify(_token, _id), do: :error
end
