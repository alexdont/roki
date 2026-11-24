defmodule Roki.Palette do
  @moduledoc """
  A title's colours, read from its poster, for the title page drawn in them (the shelf lab's A,
  after stripe.press): the poster's main colour (`h`/`c`, its OKLCH hue and chroma — the ground the
  page is laid on) and its liveliest well-represented one (`ah`/`ac` — the accent). The page makes
  its lightnesses itself (`[data-tint]` in app.css), so one palette serves the dark and the light
  theme.

  The poster is read at TMDB's smallest size and shrunk to 24×36 by ImageMagick (`magick`, as the
  social cards use); the pixels are bucketed by hue (30° each, near-grey ones apart, near-black
  and near-white left out). Kept for good in `Roki.Kept` (`palette`, a poster does not change
  colour), so it is worked out once per title.
  """

  alias Roki.Kept

  @kind "palette"

  @doc "The kept palette of a title, or nil (not worked out yet)."
  def get(type, id) do
    case Kept.get(@kind, key(type, id)) do
      {:ok, %{} = p, _fresh?} -> shape(p)
      _ -> nil
    end
  end

  @doc "The palette, working it out from `poster` (a picture URL) the first time: `{:ok, p}` or `{:error, _}`."
  def fetch(type, id, poster) when is_binary(poster) do
    case Kept.fetch(@kind, key(type, id), 10 * 365 * 86_400, fn -> read(poster) end, fn _ ->
           true
         end) do
      {:ok, p} -> {:ok, shape(p)}
      other -> other
    end
  end

  def fetch(_type, _id, _poster), do: {:error, :no_poster}

  @doc "The CSS custom properties a page sets for a palette (`--th --tc --ah --ac`)."
  def style(nil), do: nil

  def style(%{h: h, c: c, ah: ah, ac: ac}),
    do:
      "--th:#{round(h)};--tc:#{Float.round(c / 1, 3)};--ah:#{round(ah)};--ac:#{Float.round(ac / 1, 3)}"

  defp key(type, id), do: "#{type}:#{id}"

  # Kept rows come back with atom keys where the atom exists, string keys where not.
  defp shape(p) do
    g = fn k -> Map.get(p, k, Map.get(p, String.to_atom(k))) end
    %{h: g.("h"), c: g.("c"), ah: g.("ah"), ac: g.("ac")}
  end

  defp read(poster) do
    url = String.replace(poster, ~r{/w\d+/|/original/}, "/w92/")

    with magick when is_binary(magick) <- System.find_executable("magick") || {:error, :no_magick},
         {:ok, %{status: 200, body: body}} when is_binary(body) <-
           Req.get(url, receive_timeout: 10_000, retry: false, decode_body: false),
         {:ok, pixels} <- shrink(magick, body) do
      {:ok, pick(pixels)}
    else
      {:ok, %{status: status}} -> {:error, {:http, status}}
      {:error, _} = e -> e
      other -> {:error, other}
    end
  end

  # 24×36 raw RGB, through files (magick reads the picture from one, writes the pixels to another).
  defp shrink(magick, body) do
    dir = Path.join(System.tmp_dir!(), "roki-palette")
    File.mkdir_p!(dir)
    base = Path.join(dir, Integer.to_string(System.unique_integer([:positive])))
    src = base <> ".img"
    out = base <> ".rgb"

    try do
      File.write!(src, body)

      case System.cmd(magick, [src, "-resize", "24x36!", "-depth", "8", "rgb:" <> out],
             stderr_to_stdout: true
           ) do
        {_, 0} -> File.read(out)
        {msg, _} -> {:error, {:magick, String.slice(msg, 0, 200)}}
      end
    after
      File.rm(src)
      File.rm(out)
    end
  end

  @doc false
  # The same choice as the lab's: the main colour from the biggest coloured bucket; the accent
  # from the most saturated bucket that holds a fair share of the picture (else the main one).
  def pick(pixels) do
    buckets =
      for <<r, g, b <- pixels>>, reduce: %{} do
        acc ->
          %{l: l, c: c, h: h} = oklch(r, g, b)

          if l < 0.12 or l > 0.95 do
            acc
          else
            k = if c < 0.03, do: :grey, else: round(h / 30)
            rad = h * :math.pi() / 180
            {n, sl, sc, hx, hy} = Map.get(acc, k, {0, 0.0, 0.0, 0.0, 0.0})
            Map.put(acc, k, {n + 1, sl + l, sc + c, hx + :math.cos(rad), hy + :math.sin(rad)})
          end
      end

    coloured =
      for {k, {n, _l, c, hx, hy}} <- buckets, k != :grey do
        %{n: n, c: c / n, h: rem_deg(:math.atan2(hy, hx) * 180 / :math.pi())}
      end
      |> Enum.sort_by(& &1.n, :desc)

    main = List.first(coloured) || %{h: 300.0, c: 0.02, n: 0}

    lively =
      coloured
      |> Enum.filter(&(&1.n > 12))
      |> Enum.max_by(& &1.c, fn -> main end)

    %{
      "h" => Float.round(main.h / 1, 1),
      "c" => Float.round(main.c / 1, 3),
      "ah" => Float.round(lively.h / 1, 1),
      "ac" => Float.round(lively.c / 1, 3)
    }
  end

  defp rem_deg(d) when d < 0, do: d + 360
  defp rem_deg(d), do: d

  # sRGB (0..255) → OKLCH.
  defp oklch(r, g, b) do
    lin = fn v ->
      v = v / 255
      if v <= 0.04045, do: v / 12.92, else: :math.pow((v + 0.055) / 1.055, 2.4)
    end

    {rr, gg, bb} = {lin.(r), lin.(g), lin.(b)}
    l = cbrt(0.4122214708 * rr + 0.5363325363 * gg + 0.0514459929 * bb)
    m = cbrt(0.2119034982 * rr + 0.6806995451 * gg + 0.1073969566 * bb)
    s = cbrt(0.0883024619 * rr + 0.2817188376 * gg + 0.6299787005 * bb)
    ok_l = 0.2104542553 * l + 0.793617785 * m - 0.0040720468 * s
    a = 1.9779984951 * l - 2.428592205 * m + 0.4505937099 * s
    bk = 0.0259040371 * l + 0.7827717662 * m - 0.808675766 * s
    %{l: ok_l, c: :math.sqrt(a * a + bk * bk), h: rem_deg(:math.atan2(bk, a) * 180 / :math.pi())}
  end

  defp cbrt(x), do: :math.pow(x, 1 / 3)
end
