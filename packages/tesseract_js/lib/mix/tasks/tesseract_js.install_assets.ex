defmodule Mix.Tasks.TesseractJs.InstallAssets do
  @shortdoc "Copies tesseract_js's bundled JS files into your app's priv/static/"
  @moduledoc """
  Copies the package's bundled JS files (`tesseract.min.js`, `worker.min.js`,
  `tesseract_js.umd.js`) into your app's `priv/static/assets/vendor/tesseract/`,
  so Phoenix's static plug can serve them at the paths the HEEx components emit.

  Run this once after adding `tesseract_js` to your deps:

      mix deps.get
      mix tesseract_js.install_assets

  ## When to re-run

  Re-run after upgrading the `tesseract_js` package — the bundled
  `tesseract.min.js`, `worker.min.js`, or the wrapper UMD may have changed.

  ## Options

    * `--out` — output dir (defaults to `priv/static/assets/vendor/tesseract`).
    * `--force` — overwrite existing files even if identical.

  ## Why a copy step?

  Phoenix only serves files from the host app's `priv/static/` — dependencies'
  `priv/static/` directories aren't auto-mounted. Copying is the simplest,
  most explicit way to surface the files without endpoint config changes.
  """
  use Mix.Task

  @switches [out: :string, force: :boolean]
  @files ~w(tesseract.min.js worker.min.js tesseract_js.umd.js)

  @impl true
  def run(argv) do
    {opts, _rest} = OptionParser.parse!(argv, strict: @switches)

    src_dir = source_dir()
    out_dir = opts[:out] || default_out_dir()
    force? = !!opts[:force]

    File.mkdir_p!(out_dir)

    Mix.shell().info("→ Source: #{src_dir}")
    Mix.shell().info("→ Output: #{out_dir}")

    Enum.each(@files, fn name ->
      copy(Path.join(src_dir, name), Path.join(out_dir, name), force?)
    end)

    Mix.shell().info("")
    Mix.shell().info("Done. Don't forget to add the components to your layout:")
    Mix.shell().info("")
    Mix.shell().info("    <TesseractJs.Component.preload />")
    Mix.shell().info("    <TesseractJs.Component.script />")
  end

  defp copy(src, dest, force?) do
    cond do
      not File.exists?(src) ->
        Mix.raise("missing source file: #{src} — is the tesseract_js package installed?")

      File.exists?(dest) and not force? and same?(src, dest) ->
        Mix.shell().info("✓ unchanged: #{Path.basename(dest)}")

      true ->
        File.cp!(src, dest)
        Mix.shell().info("✓ copied:    #{Path.basename(dest)}")
    end
  end

  defp same?(a, b) do
    case {File.read(a), File.read(b)} do
      {{:ok, x}, {:ok, y}} -> x == y
      _ -> false
    end
  end

  defp source_dir do
    case :code.priv_dir(:tesseract_js) do
      {:error, _} ->
        Mix.raise("tesseract_js application not found — is it in your mix.exs deps?")

      priv when is_list(priv) ->
        Path.join(to_string(priv), "static")
    end
  end

  defp default_out_dir, do: Path.join(["priv", "static", "assets", "vendor", "tesseract"])
end
