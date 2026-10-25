defmodule Roki.LightSearchTest do
  use Roki.DataCase, async: false

  alias Roki.Keys
  alias Roki.Watch.Resolver

  @friend "01a16aef-e0cd-74c9-8487-145877110a4d"

  setup do
    on_exit(fn -> Keys.revoke!(@friend) end)
    :ok
  end

  test "the browser searches light releases only, heavy accounts included, unless asked" do
    Keys.set_access!(@friend, %{keys: [], heavy: true})
    assert Resolver.light?(:browser, @friend, false)
    refute Resolver.light?(:browser, @friend, true)
    refute Resolver.light?(:external, @friend, false)
  end

  test "an account without heavy encoding can not ask for it" do
    Keys.set_access!(@friend, %{keys: [], heavy: false})
    assert Resolver.light?(:browser, @friend, true)
  end
end
