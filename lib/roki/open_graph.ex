defmodule Roki.OpenGraph do
  @moduledoc """
  The picture a link to this site shows when it is pasted somewhere — a chat, a feed: a
  **social card**, 1200×630, drawn by `open_fresco` (the user's own package) and rasterised by
  ImageMagick (`magick` on the path; `open_fresco` falls back to it without the resvg NIF,
  which cannot be built here beside `rustler_precompiled` 0.10).

  Two cards: a title's (`title/2`: its backdrop under a dark wash, the poster on the right,
  the name, year, genres and TMDB score) and a profile's (`profile/1`: the banner, the avatar,
  the name, how much they watched and their average rating). Everything is drawn from the
  site's own copies — `Roki.Titles`, `Roki.Profile` — and the pictures from where the pages
  take them (TMDB's picture server, the media library). A finished card is kept on disk a
  day (`cache_dir/0`, under the cache dataset), so a link shared ten times renders once.

  The name is set in Outfit, the site's typeface: `priv/fonts/Outfit.ttf` (SIL OFL, licence
  beside it), copied into `~/.fonts` on first use so ImageMagick's fontconfig finds it.
  """

  alias OpenFresco.Scene

  @width 1200
  @height 630
  @ttl_s 24 * 3600
  @ink "#ffffff"
  @muted "#d7d3cf"
  @orange "#ff6a13"
  @dark "#141216"
  @font "Outfit"

  @doc "A title's card as JPEG bytes: `{:ok, jpeg}`, or `{:error, reason}` (`:not_found`, `:rasterizer`)."
  def title(type, id) when type in ["movie", "tv"] and is_integer(id) do
    cached("title-#{type}-#{id}", fn ->
      with {:ok, t} <- title_copy(type, id) do
        render(title_scene(t), title_values(t))
      end
    end)
  end

  def title(_, _), do: {:error, :not_found}

  @doc "A profile's card as JPEG bytes, by username."
  def profile(username) when is_binary(username) do
    cached("profile-#{String.downcase(username)}", fn ->
      case Roki.Profile.user(username) do
        nil -> {:error, :not_found}
        user -> render(profile_scene(user), profile_values(user))
      end
    end)
  end

  @doc "The Open Graph assigns a page sets for its `<head>`: `%{image:, title:, description:}`."
  def for_title(type, id, title) do
    %{
      image: RokiWeb.Endpoint.url() <> "/og/title/#{type}/#{id}/card.jpg",
      title: (title && title[:title]) || "Roki",
      description: title && (blank(title[:tagline]) || shorten(title[:overview]))
    }
  end

  def for_profile(username, profile) do
    %{
      image: RokiWeb.Endpoint.url() <> "/og/u/#{username}/card.jpg",
      title: "#{username} on Roki",
      description: profile && blank(profile[:bio])
    }
  end

  # ── the title's card ─────────────────────────────────────────────

  defp title_copy(type, id) do
    case Roki.Titles.get(type, id) do
      {:ok, title, _fresh?} -> {:ok, title}
      _ -> Roki.Watch.title(type, id, nil)
    end
  end

  @doc false
  # The scene: the backdrop as the ground (washed dark), a scrim rising from the bottom, the
  # poster at the right, and the words at the left.
  def title_scene(t) do
    backdrop? = is_binary(t[:backdrop])
    poster? = is_binary(t[:poster])
    text_w = if poster?, do: 700, else: 1072

    scene =
      Scene.new(
        width: @width,
        height: @height,
        background:
          if(backdrop?,
            do: Scene.image_fill(Scene.placeholder("backdrop"), :cover, overlay_opacity: 0.68),
            else: Scene.solid(@dark)
          )
      )
      |> Scene.add(
        Scene.text("brand",
          box: %{x: 64, y: 52, w: 400, h: 40},
          value: "roki.ee",
          font: @font,
          size: 30,
          weight: 700,
          fill: Scene.solid(@orange)
        )
      )
      |> Scene.add(
        Scene.text("title",
          box: %{x: 64, y: 330, w: text_w, h: 180},
          value: Scene.placeholder("title"),
          font: @font,
          size: 72,
          weight: 700,
          line_height: 1.05,
          fill: Scene.solid(@ink)
        )
      )
      |> Scene.add(
        Scene.text("facts",
          box: %{x: 64, y: 0, w: text_w, h: 90},
          value: Scene.placeholder("facts"),
          font: @font,
          size: 30,
          weight: 500,
          fill: Scene.solid(@muted),
          anchor: Scene.anchor("title", :below, gap: 14, align: :start)
        )
      )

    if poster? do
      Scene.add(
        scene,
        Scene.image("poster",
          box: %{x: 836, y: 90, w: 300, h: 450},
          value: Scene.placeholder("poster"),
          fit: :cover,
          radius: 18
        )
      )
    else
      scene
    end
  end

  @doc false
  def title_values(t) do
    %{
      "title" => t[:title] || "Untitled",
      "facts" => facts(t),
      "backdrop" => t[:backdrop] && data_url(t[:backdrop]),
      "poster" => t[:poster] && data_url(t[:poster])
    }
    |> Enum.reject(fn {_, v} -> v == nil end)
    |> Map.new()
  end

  @doc false
  # "1995 · Crime, Drama · TMDB 7.9" (no ★: the typeface has none, and ImageMagick does not fall back)
  def facts(t) do
    [
      t[:year],
      t[:genres] |> List.wrap() |> Enum.take(3) |> Enum.join(", ") |> blank(),
      is_number(t[:vote]) and t[:vote] > 0 and
        "TMDB #{:erlang.float_to_binary(t[:vote] * 1.0, decimals: 1)}"
    ]
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
    |> Enum.join("  ·  ")
  end

  # ── the profile's card ───────────────────────────────────────────

  @doc false
  def profile_scene(user) do
    profile = Roki.Profile.get(user.uuid)
    banner? = Roki.Profile.banner_url(profile) != nil

    Scene.new(
      width: @width,
      height: @height,
      background:
        if(banner?,
          do: Scene.image_fill(Scene.placeholder("banner"), :cover, overlay_opacity: 0.72),
          else: Scene.solid(@dark)
        )
    )
    |> Scene.add(
      Scene.text("brand",
        box: %{x: 64, y: 52, w: 400, h: 40},
        value: "roki.ee",
        font: @font,
        size: 30,
        weight: 700,
        fill: Scene.solid(@orange)
      )
    )
    |> Scene.add(
      Scene.image("avatar",
        box: %{x: 64, y: 300, w: 180, h: 180},
        value: Scene.placeholder("avatar"),
        fit: :cover,
        radius: 90
      )
    )
    |> Scene.add(
      Scene.text("name",
        box: %{x: 280, y: 300, w: 856, h: 90},
        value: Scene.placeholder("name"),
        font: @font,
        size: 72,
        weight: 700,
        valign: :middle,
        fill: Scene.solid(@ink)
      )
    )
    |> Scene.add(
      Scene.text("watched",
        box: %{x: 280, y: 0, w: 856, h: 44},
        value: Scene.placeholder("watched"),
        font: @font,
        size: 30,
        weight: 500,
        fill: Scene.solid(@muted),
        anchor: Scene.anchor("name", :below, gap: 6, align: :start)
      )
    )
    |> Scene.add(
      Scene.text("rated",
        box: %{x: 280, y: 0, w: 856, h: 44},
        value: Scene.placeholder("rated"),
        font: @font,
        size: 30,
        weight: 500,
        fill: Scene.solid(@muted),
        anchor: Scene.anchor("watched", :below, gap: 6, align: :start)
      )
    )
  end

  @doc false
  def profile_values(user) do
    profile = Roki.Profile.get(user.uuid)
    items = Roki.Profile.history(user.uuid)
    films = Enum.count(items, &(&1.type == "movie"))
    anime = Enum.count(items, &(&1[:anime] == true))
    shows = Enum.count(items, &(&1.type == "tv" and &1[:anime] != true))
    breakdown = user.uuid |> Roki.Profile.rating_counts() |> Roki.Profile.rating_breakdown()

    %{
      "name" => user.username,
      "watched" => watched_line(films, shows, anime),
      "rated" =>
        if(breakdown,
          do: "Rates #{breakdown.average} on average, over #{thousands(breakdown.total)} ratings",
          else: "No ratings yet"
        ),
      "banner" => Roki.Profile.banner_url(profile) |> site_url() |> then(&(&1 && data_url(&1))),
      "avatar" => avatar_data_url(user)
    }
    |> Enum.reject(fn {_, v} -> v == nil end)
    |> Map.new()
  end

  @doc false
  def watched_line(0, 0, 0), do: "Nothing watched yet"

  def watched_line(films, shows, anime) do
    [{films, "film"}, {shows, "show"}, {anime, "anime"}]
    |> Enum.filter(fn {n, _} -> n > 0 end)
    |> Enum.map_join("  ·  ", fn
      {n, "anime"} -> "#{n} anime"
      {1, word} -> "1 #{word}"
      {n, word} -> "#{thousands(n)} #{word}s"
    end)
    |> Kernel.<>(" watched")
  end

  defp thousands(n) when is_integer(n) do
    n
    |> Integer.to_string()
    |> String.reverse()
    |> String.replace(~r/(\d{3})(?=\d)/, "\\1,")
    |> String.reverse()
  end

  # The avatar the way PhoenixKit's `user_avatar` finds it: an upload, else the OAuth picture,
  # else Gravatar (which answers blank when there is none — then no picture, and the name alone).
  defp avatar_data_url(user) do
    fields = user.custom_fields || %{}

    cond do
      is_binary(fields["avatar_file_uuid"]) and fields["avatar_file_uuid"] != "" ->
        PhoenixKit.Modules.Storage.URLSigner.signed_url(fields["avatar_file_uuid"], "medium")
        |> site_url()
        |> data_url()

      is_binary(fields["oauth_avatar_url"]) and fields["oauth_avatar_url"] != "" ->
        data_url(fields["oauth_avatar_url"])

      is_binary(user.email) ->
        hash =
          :crypto.hash(:md5, String.downcase(String.trim(user.email)))
          |> Base.encode16(case: :lower)

        data_url("https://www.gravatar.com/avatar/#{hash}?s=360&d=404")

      true ->
        nil
    end
  rescue
    _ -> nil
  end

  # ── pictures, rendering, keeping ─────────────────────────────────

  # A path on this site, fetched from the server itself (the public address goes out through
  # the proxy; this does not have to).
  defp site_url(nil), do: nil
  defp site_url("/" <> _ = path), do: "http://127.0.0.1:#{port()}" <> path
  defp site_url(url), do: url

  defp port, do: (RokiWeb.Endpoint.config(:http) || [])[:port] || 4000

  # The picture as a data URL for the renderer (it reads no addresses, only bytes), or nil.
  defp data_url(nil), do: nil

  defp data_url(url) do
    case Req.get(url, receive_timeout: 10_000, retry: false, decode_body: false) do
      {:ok, %{status: 200, body: body, headers: headers}}
      when is_binary(body) and byte_size(body) > 0 ->
        type =
          case Map.get(headers, "content-type") do
            [t | _] -> t |> String.split(";") |> hd()
            _ -> "image/jpeg"
          end

        if String.starts_with?(type, "image/"),
          do: "data:#{type};base64," <> Base.encode64(body),
          else: nil

      _ ->
        nil
    end
  rescue
    _ -> nil
  end

  @doc """
  A scene with its values as JPEG bytes (a photo card as PNG is over a megabyte). The SVG is
  `open_fresco`'s; ImageMagick turns it into the picture through files (its stdin/stdout pipe
  through `OpenFresco.render/3` came back empty here, and its own SVG reader takes pictures
  from files, not `data:` URLs, and paints a stop-opacity gradient solid — so the scenes use
  the wash and plain shapes only). `{:error, :rasterizer}` without `magick` on the path.
  """
  def render(scene, values) do
    ensure_font()
    svg = OpenFresco.render_svg(scene, values)

    case System.find_executable("magick") do
      nil ->
        {:error, :rasterizer}

      magick ->
        File.mkdir_p(cache_dir())
        base = Path.join(cache_dir(), "render-#{System.unique_integer([:positive])}")
        svg_path = base <> ".svg"
        png_path = base <> ".jpg"

        try do
          # ImageMagick's own SVG reader takes pictures from files, not `data:` URLs — and
          # `open_fresco` inlines every picture as one. Each is written out beside the SVG.
          {svg, _pictures} = pictures_to_files(svg, base)
          File.write!(svg_path, svg)

          case System.cmd(magick, ["-density", "96", svg_path, "-quality", "86", png_path],
                 stderr_to_stdout: true
               ) do
            {_, 0} ->
              case File.read(png_path) do
                {:ok, <<0xFF, 0xD8, _::binary>> = jpeg} -> {:ok, jpeg}
                _ -> {:error, :rasterizer}
              end

            {out, _} ->
              {:error, {:rasterizer, String.slice(out, 0, 200)}}
          end
        after
          File.rm(svg_path)
          File.rm(png_path)
          for p <- Path.wildcard(base <> "-pic-*"), do: File.rm(p)
        end
    end
  end

  # Every `href="data:image/…;base64,…"` in the SVG becomes a file `<base>-pic-N.<ext>` and the
  # href its path; the paths come back for the caller to remove.
  defp pictures_to_files(svg, base) do
    {svg, n} =
      Regex.replace(
        ~r/(xlink:href|href)="data:image\/([a-z0-9.+-]+);base64,([A-Za-z0-9+\/=]+)"/,
        svg,
        fn _, attr, kind, b64 ->
          i = System.unique_integer([:positive])
          ext = if kind == "svg+xml", do: "svg", else: String.replace(kind, ~r/[^a-z0-9]/, "")
          path = "#{base}-pic-#{i}.#{ext}"
          File.write!(path, Base.decode64!(b64))
          ~s(#{attr}="#{path}")
        end
      )
      |> then(&{&1, length(Path.wildcard(base <> "-pic-*"))})

    {svg, n}
  end

  @doc "Where finished cards are kept (a day each): the cache dataset."
  def cache_dir, do: Path.join(System.tmp_dir!(), "roki-og")

  defp cached(key, make) do
    path = Path.join(cache_dir(), key <> ".jpg")

    with {:ok, %{mtime: mtime}} <- File.stat(path, time: :posix),
         true <- System.os_time(:second) - mtime < @ttl_s,
         {:ok, png} <- File.read(path) do
      {:ok, png}
    else
      _ ->
        with {:ok, png} <- make.() do
          File.mkdir_p(cache_dir())
          File.write(path, png)
          {:ok, png}
        end
    end
  end

  @doc "Forget a kept card (a profile changed its banner, say)."
  def forget(key), do: File.rm(Path.join(cache_dir(), key <> ".jpg"))

  # ImageMagick draws with the system's fonts: the site's typeface is put where fontconfig
  # looks, once.
  defp ensure_font do
    home = System.user_home!()
    dest = Path.join([home, ".fonts", "Outfit.ttf"])

    unless File.exists?(dest) do
      File.mkdir_p!(Path.dirname(dest))
      File.cp!(Path.join(:code.priv_dir(:roki), "fonts/Outfit.ttf"), dest)
      System.cmd("fc-cache", ["-f"], stderr_to_stdout: true)
    end

    :ok
  rescue
    _ -> :ok
  end

  defp blank(nil), do: nil
  defp blank(""), do: nil
  defp blank(s) when is_binary(s), do: if(String.trim(s) == "", do: nil, else: s)
  defp blank(_), do: nil

  defp shorten(nil), do: nil

  defp shorten(text) when is_binary(text) do
    text = String.trim(text)
    if String.length(text) <= 200, do: blank(text), else: String.slice(text, 0, 197) <> "…"
  end
end
