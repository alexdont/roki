defmodule Roki.KeysTest do
  use Roki.DataCase, async: false

  alias Roki.Keys

  @owner "01a163a7-a312-7691-8440-db7feaca900f"
  @friend "01a16aef-e0cd-74c9-8487-145877110a4d"
  @other "01a16aef-0000-7000-8000-000000000001"

  setup do
    dir = Path.join(System.tmp_dir!(), "roki-keys-test-#{System.unique_integer([:positive])}")
    prior = Application.get_env(:roki, :laev_dir)
    Application.put_env(:roki, :laev_dir, dir)

    # The owner's own keys, in the owner's config file.
    File.mkdir_p!(Roki.Laev.dir(@owner))

    File.write!(
      Path.join(Roki.Laev.dir(@owner), "config"),
      "RD_TOKEN=owner-rd-token\nTMDB_API_KEY=owner-tmdb\nJIMAKU_API_KEY=owner-jimaku\n"
    )

    Keys.save_config!(@owner, Keys.shareable())
    Enum.each([@friend, @other], &Keys.revoke!/1)
    Roki.TTLCache.delete(:key_owner_keys)

    on_exit(fn ->
      if prior,
        do: Application.put_env(:roki, :laev_dir, prior),
        else: Application.delete_env(:roki, :laev_dir)

      File.rm_rf(dir)
      Roki.TTLCache.delete(:key_owner_keys)
      Roki.TTLCache.delete(:key_config)
    end)

    :ok
  end

  test "an account without a grant gets nothing" do
    assert Keys.overrides(@friend, %{}) == %{}
    refute Keys.granted?(@friend)
  end

  test "a granted account borrows the keys it has none of; its own always win" do
    Keys.grant!(@friend)
    assert Keys.granted?(@friend)

    lent = Keys.overrides(@friend, %{tmdb_key: "friends-own-tmdb"})
    assert lent.rd_token == "owner-rd-token"
    assert lent.jimaku_api_key == "owner-jimaku"
    refute Map.has_key?(lent, :tmdb_key)
  end

  test "only the keys the owner chose to lend are lent" do
    Keys.save_config!(@owner, ["TMDB_API_KEY"])
    Keys.grant!(@friend)
    assert Keys.overrides(@friend, %{}) == %{tmdb_key: "owner-tmdb"}
  end

  test "keys are allowed one at a time, and the browser separately" do
    Keys.set_access!(@friend, %{keys: ["RD_TOKEN"], browser: false})
    assert Keys.overrides(@friend, %{}) == %{rd_token: "owner-rd-token"}
    refute Keys.browser?(@friend)

    Keys.set_access!(@friend, %{keys: [], browser: true})
    assert Keys.overrides(@friend, %{}) == %{}
    assert Keys.browser?(@friend)

    Keys.set_access!(@friend, %{keys: [], browser: false})
    refute Keys.browser?(@friend)
    assert Keys.all_grants()[@friend] == nil
  end

  test "taking the grant away takes the keys away" do
    Keys.grant!(@friend)
    assert map_size(Keys.overrides(@friend, %{})) > 0

    Keys.revoke!(@friend)
    assert Keys.overrides(@friend, %{}) == %{}
  end

  test "the keys reach the scope of a granted account and nothing else" do
    Keys.grant!(@friend)
    assert Roki.Laev.run(@friend, fn -> Laev.Scope.get(:rd_token) end) == "owner-rd-token"
    assert Roki.Laev.run(@other, fn -> Laev.Scope.get(:rd_token) end) == nil

    # not written into the account's own files
    refute File.exists?(Path.join(Roki.Laev.dir(@friend), "config")) and
             File.read!(Path.join(Roki.Laev.dir(@friend), "config")) =~ "owner-rd-token"
  end

  test "uses are counted per account and day, only for accounts with a grant" do
    Keys.record(@other, :play)
    assert Keys.stats() |> Enum.all?(&(&1.uuid != @other))

    Keys.grant!(@friend)
    Keys.record(@friend, :play)
    Keys.record(@friend, :play)
    Keys.record(@friend, :probe, 8)

    assert %{today: 10, total: 10, kinds: %{"play" => 2, "probe" => 8}} =
             Enum.find(Keys.stats(), &(&1.uuid == @friend))
  end

  test "a daily play cap stops plays but nothing else" do
    Keys.grant!(@friend, 2)
    assert Keys.allow_play?(@friend)
    Keys.record(@friend, :play)
    assert Keys.allow_play?(@friend)
    Keys.record(@friend, :play)
    refute Keys.allow_play?(@friend)

    Keys.set_daily_plays!(@friend, nil)
    assert Keys.allow_play?(@friend)
  end

  test "the heaviest account comes first" do
    Keys.grant!(@friend)
    Keys.grant!(@other)
    Keys.record(@other, :probe, 3)
    Keys.record(@friend, :play, 4)

    assert [%{uuid: @friend}, %{uuid: @other}] = Keys.stats()
  end
end
