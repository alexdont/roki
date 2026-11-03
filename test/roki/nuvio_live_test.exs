defmodule Roki.NuvioLiveTest do
  @moduledoc """
  The real manifest and real provider calls. Excluded from the ordinary suite; run it with

      NUVIO_LIVE=1 mix test test/roki/nuvio_live_test.exs

  It reports which providers are actually operational for the two titles used during
  implementation: The Matrix (TMDB 603, movie) and Breaking Bad S1E1 (TMDB 1396, tv).
  """
  use RokiWeb.ConnCase, async: false

  @moduletag :external
  @moduletag timeout: 300_000

  # Providers that returned playable, direct https streams for the two titles used while
  # building this. They are not special-cased by the runtime: the test still passes them
  # through the manifest, validator and sandbox like any other provider.
  @known_operational ~w(cinemacity dahmermovies dahmermovies-tv desiflix movix playimdb purstream vidrock)

  alias Roki.Nuvio

  setup do
    Application.put_env(:roki, :nuvio_offline, false)
    on_exit(fn -> Application.put_env(:roki, :nuvio_offline, true) end)

    if System.get_env("NUVIO_LIVE") != "1" do
      :ok
    else
      {:ok, user} =
        PhoenixKit.Users.Auth.register_user(%{
          "email" => "nuvio-live-#{System.unique_integer([:positive])}@example.com",
          "password" => "a-long-enough-password-123",
          "username" => "nuviolive#{System.unique_integer([:positive])}"
        })

      {:ok, providers} = Roki.Nuvio.Registry.providers()

      # Only providers that are self-contained and pass the static validator; the same gate
      # the runtime applies.
      enabled =
        providers
        |> Enum.filter(&(&1.id in @known_operational))
        |> Enum.filter(&(Roki.Nuvio.Registry.eligible?(&1) |> elem(1) |> Map.get(:eligible)))
        |> Enum.map(& &1.id)

      settings = %{
        "enabled" => enabled,
        "options" => %{}
      }

      {:ok, user} = Roki.Nuvio.Settings.save(user, settings)
      {:ok, user: user, enabled: enabled}
    end
  end

  test "the live manifest lists providers with safe relative files" do
    if System.get_env("NUVIO_LIVE") == "1" do
      assert {:ok, manifest} = Roki.Nuvio.Registry.manifest()
      assert manifest.origin in [:live, :snapshot]
      assert length(manifest.providers) > 0
      assert Enum.all?(manifest.providers, &String.starts_with?(&1.filename, "providers/"))
    end
  end

  test "movie search reports provider statuses and at least one playable stream", %{user: user} do
    if System.get_env("NUVIO_LIVE") == "1" do
      assert {:ok, results} = Nuvio.search(user.uuid, 603, "movie", nil, nil, force: true)

      for result <- results do
        IO.puts(
          "MOVIE #{result.provider.id}: #{result.status} " <>
            "#{length(result.streams)} streams, #{result.ms}ms #{result.error || ""}"
        )
      end

      assert results != []
      assert Nuvio.streams(results) != []
    end
  end

  test "tv search reports provider statuses", %{user: user} do
    if System.get_env("NUVIO_LIVE") == "1" do
      assert {:ok, results} = Nuvio.search(user.uuid, 1396, "tv", 1, 1, force: true)

      for result <- results do
        IO.puts(
          "TV #{result.provider.id}: #{result.status} " <>
            "#{length(result.streams)} streams, #{result.ms}ms #{result.error || ""}"
        )
      end

      assert results != []
    end
  end
end
