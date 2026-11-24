defmodule Roki.PaletteTest do
  use ExUnit.Case, async: true

  alias Roki.Palette

  # n pixels of one colour, as the raw RGB magick hands back.
  defp px(rgb, n), do: :binary.copy(<<elem(rgb, 0), elem(rgb, 1), elem(rgb, 2)>>, n)

  test "the ground is the colour most of the poster is; the accent its liveliest share" do
    # Mostly a dull navy, a fair patch of saturated orange, a few near-black pixels ignored.
    p = Palette.pick(px({30, 40, 70}, 600) <> px({240, 110, 20}, 150) <> px({2, 2, 2}, 100))

    assert p["h"] > 240 and p["h"] < 290
    assert p["ah"] > 30 and p["ah"] < 80
    assert p["ac"] > p["c"]
  end

  test "a grey poster still gets a palette (a quiet default hue)" do
    p = Palette.pick(px({120, 120, 120}, 500))
    assert %{"h" => _, "c" => c} = p
    assert c < 0.05
  end

  test "the page's custom properties" do
    assert Palette.style(%{h: 56.3, c: 0.0771, ah: 40, ac: 0.14}) ==
             "--th:56;--tc:0.077;--ah:40;--ac:0.14"

    assert Palette.style(nil) == nil
  end
end
