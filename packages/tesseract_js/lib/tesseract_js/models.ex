defmodule TesseractJs.Models do
  @moduledoc """
  Model registry — single source of truth for the languages and core WASM files
  that `tesseract_js` knows about. Both CDN mode and local mode are driven from
  this module.

  The curated list below covers ~20 common languages with checksums and approximate
  sizes for the `:standard` tessdata tier. Any language code (e.g. `"hin"`,
  `"chi_tra+chi_sim"`) that is *not* in the curated list still works at runtime —
  it just falls through to the URL template without checksum verification.

  Use the helpers to resolve URLs and paths:

      TesseractJs.Models.cdn_url("eng")
      TesseractJs.Models.cdn_url("jpn_vert", :best)
      TesseractJs.Models.local_path("eng")
      TesseractJs.Models.filename("eng")

  The tessdata-version pinned by this package is `4.0.0` (the tessdata bundle
  format used by tesseract.js 5.x). Bump it in lockstep with the JS core release.
  """

  @tessdata_version "4.0.0"
  @core_version "5.1.1"

  @models %{
    "eng" => %{name: "English", size_mb: 11, sha256: nil},
    "jpn" => %{name: "Japanese", size_mb: 13, sha256: nil},
    "jpn_vert" => %{name: "Japanese (vertical, manga-friendly)", size_mb: 4, sha256: nil},
    "chi_sim" => %{name: "Chinese (simplified)", size_mb: 18, sha256: nil},
    "chi_tra" => %{name: "Chinese (traditional)", size_mb: 18, sha256: nil},
    "kor" => %{name: "Korean", size_mb: 7, sha256: nil},
    "fra" => %{name: "French", size_mb: 9, sha256: nil},
    "deu" => %{name: "German", size_mb: 10, sha256: nil},
    "spa" => %{name: "Spanish", size_mb: 10, sha256: nil},
    "ita" => %{name: "Italian", size_mb: 8, sha256: nil},
    "por" => %{name: "Portuguese", size_mb: 9, sha256: nil},
    "rus" => %{name: "Russian", size_mb: 11, sha256: nil},
    "ara" => %{name: "Arabic", size_mb: 4, sha256: nil},
    "hin" => %{name: "Hindi", size_mb: 8, sha256: nil},
    "nld" => %{name: "Dutch", size_mb: 9, sha256: nil},
    "pol" => %{name: "Polish", size_mb: 9, sha256: nil},
    "tur" => %{name: "Turkish", size_mb: 9, sha256: nil},
    "vie" => %{name: "Vietnamese", size_mb: 4, sha256: nil},
    "tha" => %{name: "Thai", size_mb: 6, sha256: nil},
    "ukr" => %{name: "Ukrainian", size_mb: 7, sha256: nil}
  }

  @core_variants %{
    simd_lstm: "tesseract-core-simd-lstm.wasm.js",
    simd: "tesseract-core-simd.wasm.js",
    basic: "tesseract-core.wasm.js"
  }

  @cdn_base "https://cdn.jsdelivr.net/npm"

  @doc "Returns the curated registry as a map of `lang => %{name, size_mb, sha256}`."
  @spec list() :: %{String.t() => map()}
  def list, do: @models

  @doc "Returns the tessdata version (`4.0.0`) this package is pinned to."
  def tessdata_version, do: @tessdata_version

  @doc "Returns the tesseract.js-core version this package is pinned to."
  def core_version, do: @core_version

  @doc "Returns the registry entry for a language, or `nil` if not curated."
  @spec get(String.t()) :: map() | nil
  def get(lang), do: Map.get(@models, lang)

  @doc "Filename for a language's traineddata file."
  @spec filename(String.t()) :: String.t()
  def filename(lang), do: "#{lang}.traineddata.gz"

  @doc "Filename for a WASM core variant."
  @spec core_filename(atom()) :: String.t()
  def core_filename(variant \\ :simd_lstm) do
    Map.get(@core_variants, variant) || @core_variants[:simd_lstm]
  end

  @doc """
  Builds the jsDelivr URL for a language's traineddata file.

      iex> TesseractJs.Models.cdn_url("eng")
      "https://cdn.jsdelivr.net/npm/@tesseract.js-data/eng@1.0.0/4.0.0/eng.traineddata.gz"

  Supports `+`-combined langs by returning the URL for the *first* lang — the
  consumer is expected to download each lang separately. (For local mode, all
  combined langs must be present in the same dir.)

  ## Tiers

    * `:standard` — full LSTM+legacy combined model, ~11 MB/lang gzipped.
    * `:best` — smaller LSTM-only model (the `_best_int` variant on jsDelivr),
      ~3 MB/lang gzipped, similar accuracy to standard for most languages.

  > The `:fast` tier (`tessdata_fast`) requires uncompressed `.traineddata`
  > files served from a different source and isn't supported in v0.1.
  """
  @spec cdn_url(String.t(), atom()) :: String.t()
  def cdn_url(lang, tier \\ :standard) do
    primary = lang |> String.split("+", parts: 2) |> List.first()

    tier_path =
      case tier do
        :standard ->
          @tessdata_version

        :best ->
          "#{@tessdata_version}_best_int"

        other ->
          raise ArgumentError, "unknown tier #{inspect(other)} (expected :standard or :best)"
      end

    "#{@cdn_base}/@tesseract.js-data/#{primary}@1.0.0/#{tier_path}/#{filename(primary)}"
  end

  @doc "jsDelivr URL for the tesseract.js-core WASM bundle."
  @spec core_cdn_url(atom()) :: String.t()
  def core_cdn_url(variant \\ :simd_lstm) do
    "#{@cdn_base}/tesseract.js-core@#{@core_version}/#{core_filename(variant)}"
  end

  @doc """
  Local filesystem path (relative to a Phoenix app's `priv/static/`) where the
  Mix download task will write a language file.

      iex> TesseractJs.Models.local_path("eng")
      "/assets/vendor/tesseract/eng.traineddata.gz"
  """
  @spec local_path(String.t(), Path.t()) :: String.t()
  def local_path(lang, base \\ "/assets/vendor/tesseract") do
    primary = lang |> String.split("+", parts: 2) |> List.first()
    Path.join(base, filename(primary))
  end

  @doc "Local path for the WASM core."
  @spec core_local_path(atom(), Path.t()) :: String.t()
  def core_local_path(variant \\ :simd_lstm, base \\ "/assets/vendor/tesseract") do
    Path.join(base, core_filename(variant))
  end

  @doc "Splits a `+`-combined lang string into individual lang codes."
  @spec split_langs(String.t()) :: [String.t()]
  def split_langs(lang), do: lang |> String.split("+", trim: true) |> Enum.map(&String.trim/1)
end
