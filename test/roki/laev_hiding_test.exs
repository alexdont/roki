defmodule Roki.LaevHidingTest do
  use ExUnit.Case, async: false

  test "while a sync can carry keys, laev's export cannot see the site's own MyAnimeList app, and it is back after" do
    prior = {Application.get_env(:laev, :mal_client_id), Application.get_env(:laev, :mal_client_secret)}
    Application.put_env(:laev, :mal_client_id, "site-app-id")
    Application.put_env(:laev, :mal_client_secret, "site-app-secret")
    on_exit(fn -> restore(prior) end)

    # Outside: the export would carry them (that is how they reached every stored key copy).
    assert Laev.Config.export()["MAL_CLIENT_ID"] == "site-app-id"
    assert Laev.Config.export()["MAL_CLIENT_SECRET"] == "site-app-secret"

    inside =
      Roki.Laev.hiding_site_keys(fn ->
        # Another request finishing meanwhile puts the site's settings back; it must not here.
        Roki.Laev.scrub_env()
        Laev.Config.export()
      end)

    refute Map.has_key?(inside, "MAL_CLIENT_ID")
    refute Map.has_key?(inside, "MAL_CLIENT_SECRET")

    # After: the site's own settings are back, as the application started with them.
    site = :persistent_term.get({Roki.Laev, :site_env}, %{})
    assert Application.get_env(:laev, :mal_client_id) == Map.get(site, :mal_client_id)
    assert Application.get_env(:laev, :mal_client_secret) == Map.get(site, :mal_client_secret)
    assert Application.get_env(:roki, :hiding_site_keys) == false
  end

  defp restore({id, secret}) do
    for {key, value} <- [mal_client_id: id, mal_client_secret: secret] do
      if value, do: Application.put_env(:laev, key, value), else: Application.delete_env(:laev, key)
    end
  end
end
