defmodule TesseractJs.Config do
  @moduledoc """
  Reads `:tesseract_js` Application config with sensible defaults and resolves
  the paths the browser needs (workerPath, corePath, langPath) for either CDN
  or local mode.

  Config keys:

      config :tesseract_js,
        base_path: "/assets/vendor/tesseract",  # where local files live (when source: :local)
        lang: "eng",                            # default language
        source: :cdn,                           # :cdn (default) or :local
        tessdata_repo: :standard,               # :standard | :best | :fast
        core_variant: :simd_lstm                # :simd_lstm | :simd | :basic
  """

  alias TesseractJs.Models

  @defaults %{
    base_path: "/assets/vendor/tesseract",
    lang: "eng",
    source: :cdn,
    tessdata_repo: :standard,
    core_variant: :simd_lstm
  }

  @doc """
  Returns the merged config map (defaults ← Application env ← overrides).
  """
  @spec get(keyword() | map()) :: map()
  def get(overrides \\ []) do
    env = Application.get_all_env(:tesseract_js) |> Map.new()

    @defaults
    |> Map.merge(env)
    |> Map.merge(Map.new(overrides))
  end

  @doc "Just the base_path used for local-mode asset URLs."
  def base_path(overrides \\ []), do: get(overrides).base_path

  @doc """
  Returns the runtime configuration the browser needs:

      %{
        workerPath: "/assets/vendor/tesseract/worker.min.js",
        corePath:   "<cdn or local>/tesseract-core-simd-lstm.wasm.js",
        langPath:   "<cdn or local>",
        lang:       "eng",
        oem:        1
      }

  This is what the `<.script />` component serializes into
  `window.__tesseractJs`. The JS wrapper reads these defaults at boot.

  Notes:

    * `workerPath` is always served from the package's vendored files
      (small, no benefit to CDN).
    * `corePath` and `langPath` flip based on `source`.
    * For CDN mode, `langPath` points at the parent jsDelivr directory so
      tesseract.js's worker can build per-lang URLs from it.
  """
  @spec runtime(keyword() | map()) :: map()
  def runtime(overrides \\ []) do
    cfg = get(overrides)
    base = cfg.base_path

    {core_path, lang_path} =
      case cfg.source do
        :cdn ->
          core = Models.core_cdn_url(cfg.core_variant)
          lang = lang_base_cdn(cfg.lang, cfg.tessdata_repo)
          {core, lang}

        :local ->
          {Path.join(base, Models.core_filename(cfg.core_variant)), base}

        other ->
          raise ArgumentError, "unknown :source #{inspect(other)} (expected :cdn or :local)"
      end

    %{
      workerPath: Path.join(base, "worker.min.js"),
      tesseractPath: Path.join(base, "tesseract.min.js"),
      corePath: core_path,
      langPath: lang_path,
      lang: cfg.lang,
      oem: 1
    }
  end

  defp lang_base_cdn(lang, tier) do
    # Strip filename off cdn_url to get the directory.
    url = Models.cdn_url(lang, tier)
    Path.dirname(url)
  end
end
