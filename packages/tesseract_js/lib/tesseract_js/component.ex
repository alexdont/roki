defmodule TesseractJs.Component do
  @moduledoc """
  HEEx components that wire `tesseract_js` into a Phoenix layout.

  Drop these into `root.html.heex`:

      <TesseractJs.Component.preload />
      <TesseractJs.Component.script />

  `preload/1` hints the browser to start fetching `tesseract.min.js` and the
  WASM core early. `script/1` emits the `<script>` tags that load the upstream
  tesseract.js, the wrapper bundle, and a small inline config block at
  `window.__tesseractJs`.

  Both components read `:tesseract_js` Application config and accept inline
  overrides via attributes for per-page customization.
  """

  use Phoenix.Component

  alias TesseractJs.Config

  attr(:base_path, :string, default: nil)
  attr(:preload_core, :boolean, default: true)

  @doc """
  Renders `<link rel="preload">` hints for the OCR assets.

  When `preload_core: true` (the default), also preloads the WASM core. Disable
  this on pages where OCR is optional/lazy to avoid wasted bandwidth.
  """
  def preload(assigns) do
    cfg = Config.runtime(maybe_override(assigns))
    assigns = assign(assigns, :cfg, cfg)

    ~H"""
    <link rel="preload" href={@cfg.tesseractPath} as="script" />
    <link :if={@preload_core} rel="preload" href={@cfg.corePath} as="fetch" crossorigin="anonymous" />
    """
  end

  attr(:base_path, :string, default: nil)
  attr(:lang, :string, default: nil)
  attr(:source, :atom, default: nil, values: [nil, :cdn, :local])
  attr(:tessdata_repo, :atom, default: nil, values: [nil, :standard, :best])
  attr(:core_variant, :atom, default: nil, values: [nil, :simd_lstm, :simd, :basic])
  attr(:defer, :boolean, default: true)

  @doc """
  Emits the `<script>` tags that load tesseract.js + the wrapper, and an inline
  config block at `window.__tesseractJs` that the wrapper reads at boot.

  All attrs are optional — defaults come from `config :tesseract_js, ...`.
  """
  def script(assigns) do
    cfg = Config.runtime(maybe_override(assigns))
    assigns = assign(assigns, :cfg, cfg)
    assigns = assign(assigns, :inline_config, encode_runtime_config(cfg))

    ~H"""
    <script>
      window.__tesseractJs = <%= Phoenix.HTML.raw(@inline_config) %>;
    </script>
    <script src={@cfg.tesseractPath} defer={@defer}></script>
    <script src={wrapper_url(@cfg)} defer={@defer}></script>
    """
  end

  defp maybe_override(assigns) do
    [
      base_path: assigns[:base_path],
      lang: assigns[:lang],
      source: assigns[:source],
      tessdata_repo: assigns[:tessdata_repo],
      core_variant: assigns[:core_variant]
    ]
    |> Enum.reject(fn {_k, v} -> is_nil(v) end)
  end

  defp wrapper_url(cfg), do: Path.join(Path.dirname(cfg.tesseractPath), "tesseract_js.umd.js")

  # Hand-encode as a JS object literal so we don't need to depend on Jason.
  defp encode_runtime_config(cfg) do
    pairs =
      cfg
      |> Map.to_list()
      |> Enum.map_join(",", fn {k, v} -> "#{k}:#{encode_value(v)}" end)

    "{" <> pairs <> "}"
  end

  defp encode_value(v) when is_binary(v), do: ~s("#{escape(v)}")
  defp encode_value(v) when is_integer(v), do: Integer.to_string(v)
  defp encode_value(v) when is_atom(v), do: ~s("#{v}")
  defp encode_value(v) when is_boolean(v), do: to_string(v)

  defp escape(s) do
    s
    |> String.replace("\\", "\\\\")
    |> String.replace(~s("), ~s(\\"))
    |> String.replace("<", "\\u003c")
    |> String.replace(">", "\\u003e")
  end
end
