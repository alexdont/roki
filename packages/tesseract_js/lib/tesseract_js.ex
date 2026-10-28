defmodule TesseractJs do
  @moduledoc """
  Phoenix-friendly wrapper for [tesseract.js](https://github.com/naptha/tesseract.js).

  Run OCR in the browser — manga, document scanning, receipt parsing, anything
  with text in an image — without writing tesseract.js boilerplate. Pick a language,
  drop two components into your layout, and call `getOcrWorker()` from JS.

  ## Quick start

      # mix.exs
      {:tesseract_js, "~> 0.1"}

      # config/config.exs
      config :tesseract_js, lang: "eng"

      # root.html.heex
      <TesseractJs.Component.preload />
      <TesseractJs.Component.script />

      // anywhere in your JS
      const { getOcrWorker, recognize } = window.TesseractJs;
      const { data } = await recognize(canvasOrImg);
      console.log(data.text);

  By default everything heavy loads from jsDelivr. To self-host, run:

      mix tesseract_js.download eng jpn
      # then in config.exs:
      config :tesseract_js, source: :local

  ## Modules

    * `TesseractJs.Models` — language registry + URL builders.
    * `TesseractJs.Config` — config defaults and runtime resolution.
    * `TesseractJs.Component` — `<.preload />` and `<.script />` HEEx components.
    * `Mix.Tasks.TesseractJs.Download` — `mix tesseract_js.download` task.
  """

  @doc "Default base path under `priv/static/` where local-mode assets live."
  defdelegate asset_base_path(), to: TesseractJs.Config, as: :base_path

  @doc "Returns the merged config map. See `TesseractJs.Config.get/1`."
  defdelegate config(overrides \\ []), to: TesseractJs.Config, as: :get

  @doc "Returns the runtime config that the browser needs. See `TesseractJs.Config.runtime/1`."
  defdelegate runtime_config(overrides \\ []), to: TesseractJs.Config, as: :runtime
end
