defmodule Roki.Manga.AddressTest do
  @moduledoc "Clean manga addresses: a name per title, shared across its sources, resolved per reader."
  use Roki.DataCase, async: true

  alias Roki.Manga.Address

  test "a title gets its name the first time, and keeps it" do
    assert Address.name_for("kotatsu", "MANGAPILL~a", "Nozoki Ana") == "nozoki-ana"
    assert Address.name_for("kotatsu", "MANGAPILL~a", "Something Else Now") == "nozoki-ana"
    assert Address.path("nozoki-ana") == "/manga/nozoki-ana"
    assert Address.path("nozoki-ana", "86") == "/manga/nozoki-ana/86"
    assert Address.path("nozoki-ana", "86", 5) == "/manga/nozoki-ana/86/5"
  end

  test "the same title on another source shares the name; another title with it is numbered" do
    assert Address.name_for("kotatsu", "ALLMANGA~a", "Nozoki Ana") == "nozoki-ana"
    assert Address.name_for("kotatsu", "MANGAPILL~a", "Nozoki Ana") == "nozoki-ana"
    assert Address.name_for("mangadex", "x", "Nozoki-Ana!") == "nozoki-ana-2"
  end

  test "a name the site uses, a source's name or a number, and a title with no letters it can keep" do
    assert Address.name_for("mangadex", "e", "Explore") == "explore-manga"
    assert Address.name_for("mangadex", "k", "Kotatsu") == "kotatsu-manga"
    assert Address.name_for("mangadex", "n", "100") == "100-manga"
    assert "manga-" <> _ = Address.name_for("mangadex", "q", "???")
  end

  test "a name resolves to the reader's own copy first, else the one used last" do
    {:ok, user} =
      PhoenixKit.Users.Auth.register_user(%{
        "email" => "addr@example.com",
        "password" => "a-long-enough-password-123",
        "username" => "addrme"
      })

    Address.name_for("kotatsu", "ALLMANGA~a", "Nozoki Ana")
    Address.name_for("kotatsu", "MANGAPILL~a", "Nozoki Ana")

    assert Address.resolve("nozoki-ana") in [
             {"kotatsu", "ALLMANGA~a"},
             {"kotatsu", "MANGAPILL~a"}
           ]

    {:ok, _} =
      Roki.Manga.Library.save_manga(user.uuid, %{
        source: "kotatsu",
        slug: "ALLMANGA~a",
        title: "Nozoki Ana",
        cover_url: "https://example.invalid/c.jpg"
      })

    assert Address.resolve("nozoki-ana", user.uuid) == {"kotatsu", "ALLMANGA~a"}
    assert Address.resolve("Nozoki-Ana", user.uuid) == {"kotatsu", "ALLMANGA~a"}
    assert Address.resolve("no-such-manga") == nil
  end
end
