defmodule TesseractJs.MixProject do
  use Mix.Project

  @version "0.1.0"
  @source_url "https://github.com/alexdont/tesseract_js"

  def project do
    [
      app: :tesseract_js,
      version: @version,
      elixir: "~> 1.15",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      aliases: aliases(),
      description:
        "Phoenix-friendly wrapper for tesseract.js — OCR in the browser, with a unified model registry that serves both CDN and local modes.",
      package: package(),
      source_url: @source_url,
      docs: [
        main: "TesseractJs",
        source_ref: "v#{@version}",
        source_url: @source_url
      ]
    ]
  end

  def application do
    [
      extra_applications: [:logger, :inets, :ssl, :crypto, :public_key]
    ]
  end

  defp deps do
    [
      {:phoenix_live_view, "~> 0.20 or ~> 1.0", optional: true},
      {:phoenix_html, "~> 3.3 or ~> 4.0", optional: true},
      {:ex_doc, ">= 0.0.0", only: :dev, runtime: false}
    ]
  end

  defp aliases do
    [
      precommit: [
        "compile --warnings-as-errors",
        "format --check-formatted",
        "deps.unlock --check-unused"
      ]
    ]
  end

  defp package do
    [
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(
        lib
        priv/static
        assets/js/src
        mix.exs
        README.md
        CHANGELOG.md
        LICENSE
        .formatter.exs
      )
    ]
  end
end
