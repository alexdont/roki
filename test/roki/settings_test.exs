defmodule Roki.SettingsTest do
  use ExUnit.Case, async: false

  alias Roki.Laev

  setup do
    dir = Path.join(System.tmp_dir!(), "roki-settings-test-#{System.unique_integer([:positive])}")
    prior = Application.get_env(:roki, :laev_dir)
    Application.put_env(:roki, :laev_dir, dir)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:roki, :laev_dir, prior),
        else: Application.delete_env(:roki, :laev_dir)

      File.rm_rf(dir)
    end)

    uuid = Ecto.UUID.generate()
    File.mkdir_p!(Laev.dir(uuid))
    {:ok, uuid: uuid}
  end

  defp setting(uuid, key), do: uuid |> Laev.settings() |> Enum.find(&(&1.key == key))

  test "a setting is changed, saved, and read back", %{uuid: uuid} do
    refute setting(uuid, "LAEV_AUTO_SOURCE").set?
    assert :ok = Laev.put_setting(uuid, "LAEV_AUTO_SOURCE", "off")
    assert %{set?: true, value: "off"} = setting(uuid, "LAEV_AUTO_SOURCE")
    # written to the user's own config file, which is how it survives a restart
    assert File.read!(Path.join(Laev.dir(uuid), "config")) =~ "LAEV_AUTO_SOURCE=off"
  end

  test "text settings take text", %{uuid: uuid} do
    assert :ok = Laev.put_setting(uuid, "LAEV_LANG", "ja")
    assert %{value: "ja"} = setting(uuid, "LAEV_LANG")
  end

  test "laev refuses a value a choice does not offer, and an unknown setting", %{uuid: uuid} do
    assert {:error, {:must_be_one_of, "LAEV_AUTO_SOURCE", allowed}} =
             Laev.put_setting(uuid, "LAEV_AUTO_SOURCE", "maybe")

    assert "on" in allowed
    assert {:error, {:unknown_setting, "NOPE"}} = Laev.put_setting(uuid, "NOPE", "x")
    refute setting(uuid, "LAEV_AUTO_SOURCE").set?
  end

  test "settings are per user", %{uuid: uuid} do
    other = Ecto.UUID.generate()
    File.mkdir_p!(Laev.dir(other))
    Laev.put_setting(uuid, "LAEV_LANG", "fr")
    refute setting(other, "LAEV_LANG").set?
  end

  describe "keys" do
    test "a saved key comes back masked, never in full", %{uuid: uuid} do
      key = "abcd1234efgh5678ijkl"
      assert {:ok, "not checked"} = Laev.replace_key(uuid, "OPENSUBTITLES_API_KEY", "  #{key}  ")

      entry = setting(uuid, "OPENSUBTITLES_API_KEY")
      assert entry.set?
      assert entry.value =~ "•"
      refute entry.value == key
      refute inspect(Laev.settings(uuid)) =~ key
    end

    test "a blank key is not saved", %{uuid: uuid} do
      assert {:error, "paste the key first"} =
               Laev.replace_key(uuid, "OPENSUBTITLES_API_KEY", "   ")

      refute setting(uuid, "OPENSUBTITLES_API_KEY").set?
    end

    test "a key is forgotten on request", %{uuid: uuid} do
      Laev.replace_key(uuid, "JIMAKU_API_KEY", "some-long-key-value")
      assert setting(uuid, "JIMAKU_API_KEY").set?
      assert :ok = Laev.remove_key(uuid, "JIMAKU_API_KEY")
      refute setting(uuid, "JIMAKU_API_KEY").set?
    end

    test "checking a key that is not set says so, without calling anyone", %{uuid: uuid} do
      assert {:error, "not set"} = Laev.check_key(uuid, "RD_TOKEN")
    end
  end

  test "errors read as sentences" do
    assert Laev.explain({:must_be_one_of, "K", ["on", "off"]}) == "must be one of: on, off"
    assert Laev.explain("token rejected (401)") == "token rejected (401)"
    assert Laev.explain({:unknown_setting, "X"}) =~ "not a setting"
  end
end
