defmodule Mix.Tasks.TesseractJs.Download do
  @shortdoc "Downloads tesseract.js core WASM + traineddata language files"
  @moduledoc """
  Downloads the tesseract.js core WASM bundle and one or more traineddata
  language files into your app's `priv/static/assets/vendor/tesseract/`,
  so you can run `tesseract_js` in local mode (no jsDelivr at runtime).

  ## Examples

      mix tesseract_js.download                       # core + "eng" + :standard
      mix tesseract_js.download eng jpn               # core + two langs
      mix tesseract_js.download --tier best eng jpn   # from tessdata_best
      mix tesseract_js.download --list                # prints curated registry
      mix tesseract_js.download --core-only           # just the WASM core

  ## Options

    * `--tier` — one of `standard` (default) or `best`.
    * `--core-variant` — `simd_lstm` (default), `simd`, `basic`.
    * `--out` — output dir, defaults to `priv/static/assets/vendor/tesseract`.
    * `--core-only` — download only the WASM core.
    * `--list` — print the curated language registry and exit.
    * `--force` — re-download even if file exists.
  """
  use Mix.Task

  alias TesseractJs.Models

  @switches [
    tier: :string,
    core_variant: :string,
    out: :string,
    core_only: :boolean,
    list: :boolean,
    force: :boolean
  ]

  @impl true
  def run(argv) do
    {:ok, _} = Application.ensure_all_started(:inets)
    {:ok, _} = Application.ensure_all_started(:ssl)

    {opts, positional} = OptionParser.parse!(argv, strict: @switches)

    cond do
      opts[:list] -> print_registry()
      true -> do_download(positional, opts)
    end
  end

  defp do_download(positional, opts) do
    tier = parse_tier(opts[:tier] || "standard")
    variant = parse_variant(opts[:core_variant] || "simd_lstm")
    out_dir = resolve_out_dir(opts[:out])
    force? = !!opts[:force]

    File.mkdir_p!(out_dir)

    langs =
      if opts[:core_only] do
        []
      else
        case positional do
          [] -> ["eng"]
          ls -> ls
        end
        |> Enum.flat_map(&Models.split_langs/1)
        |> Enum.uniq()
      end

    Mix.shell().info("→ Output: #{out_dir}")
    Mix.shell().info("→ Tier:   #{tier}, core variant: #{variant}")

    fetch_core(variant, out_dir, force?)
    Enum.each(langs, fn lang -> fetch_lang(lang, tier, out_dir, force?) end)

    Mix.shell().info("")
    Mix.shell().info("Done. Add this to config/config.exs to switch to local mode:")
    Mix.shell().info("")
    Mix.shell().info("    config :tesseract_js,")
    Mix.shell().info("      source: :local,")
    Mix.shell().info("      tessdata_repo: #{inspect(tier)},")
    Mix.shell().info("      core_variant: #{inspect(variant)}")
  end

  defp fetch_core(variant, out_dir, force?) do
    url = Models.core_cdn_url(variant)
    filename = Models.core_filename(variant)
    dest = Path.join(out_dir, filename)
    fetch(url, dest, force?, nil)
  end

  defp fetch_lang(lang, tier, out_dir, force?) do
    url = Models.cdn_url(lang, tier)
    filename = Models.filename(lang)
    dest = Path.join(out_dir, filename)
    expected = Models.get(lang) && Models.get(lang).sha256
    fetch(url, dest, force?, expected)
  end

  defp fetch(url, dest, force?, expected_sha256) do
    cond do
      File.exists?(dest) and not force? and sha_ok?(dest, expected_sha256) ->
        Mix.shell().info("✓ already present: #{Path.basename(dest)}")

      true ->
        Mix.shell().info("↓ downloading #{Path.basename(dest)} from #{url}")

        case download_to(url, dest) do
          :ok ->
            if expected_sha256 do
              if sha_ok?(dest, expected_sha256) do
                Mix.shell().info("✓ verified #{Path.basename(dest)}")
              else
                File.rm(dest)
                Mix.raise("checksum mismatch for #{Path.basename(dest)} — file removed")
              end
            else
              Mix.shell().info(
                "✓ downloaded #{Path.basename(dest)} (no checksum in registry — skipped verification)"
              )
            end

          {:error, reason} ->
            Mix.raise("download failed for #{url}: #{inspect(reason)}")
        end
    end
  end

  defp download_to(url, dest) do
    headers = [{~c"user-agent", ~c"tesseract_js mix task"}]
    request = {String.to_charlist(url), headers}

    http_opts = [
      ssl: [
        verify: :verify_peer,
        cacerts: :public_key.cacerts_get(),
        depth: 4,
        customize_hostname_check: [
          match_fun: :public_key.pkix_verify_hostname_match_fun(:https)
        ]
      ],
      autoredirect: true
    ]

    opts = [body_format: :binary]

    case :httpc.request(:get, request, http_opts, opts) do
      {:ok, {{_, 200, _}, _, body}} ->
        File.write!(dest, body)
        :ok

      {:ok, {{_, code, _}, _, _}} ->
        {:error, "HTTP #{code}"}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp sha_ok?(_path, nil), do: true

  defp sha_ok?(path, expected) when is_binary(expected) do
    case File.read(path) do
      {:ok, body} ->
        actual = :crypto.hash(:sha256, body) |> Base.encode16(case: :lower)
        actual == String.downcase(expected)

      _ ->
        false
    end
  end

  defp parse_tier("standard"), do: :standard
  defp parse_tier("best"), do: :best

  defp parse_tier(other),
    do: Mix.raise("unknown --tier #{inspect(other)} (expected standard|best)")

  defp parse_variant("simd_lstm"), do: :simd_lstm
  defp parse_variant("simd"), do: :simd
  defp parse_variant("basic"), do: :basic
  defp parse_variant(other), do: Mix.raise("unknown --core-variant #{inspect(other)}")

  # When invoked from the host app, Mix.Project is the host's, so `priv`
  # resolves to the host's `priv/`. From inside the package itself, this
  # would write into the package's priv — not useful, but harmless.
  defp resolve_out_dir(nil), do: Path.join(["priv", "static", "assets", "vendor", "tesseract"])
  defp resolve_out_dir(custom), do: custom

  defp print_registry do
    Mix.shell().info("Curated tesseract_js language registry:")
    Mix.shell().info("")
    Mix.shell().info("  code        size  name")
    Mix.shell().info("  ----------  ----  ----")

    Models.list()
    |> Enum.sort_by(fn {code, _} -> code end)
    |> Enum.each(fn {code, %{name: name, size_mb: size}} ->
      Mix.shell().info(
        "  #{String.pad_trailing(code, 10)}  #{String.pad_leading("#{size}M", 4)}  #{name}"
      )
    end)

    Mix.shell().info("")

    Mix.shell().info(
      "Any tesseract language code works at runtime; the registry is just for help text + checksums."
    )
  end
end
