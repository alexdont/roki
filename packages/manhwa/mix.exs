defmodule Manhwa.MixProject do
  use Mix.Project

  @version "0.1.11"
  @description "Batteries-included long-strip comic reader for Phoenix — webtoons, manhwa, manhua, anything that reads by scrolling. Router-mounted reader with panel snap, auto-reader, progress, and settings on top of fresco_strip; persistence via a small Store behaviour."
  @source_url "https://github.com/alexdont/manhwa"

  def project do
    [
      app: :manhwa,
      version: @version,
      description: @description,
      elixir: "~> 1.18",
      start_permanent: Mix.env() == :prod,
      deps: deps(),
      package: package(),
      docs: docs()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  defp deps do
    [
      {:phoenix, "~> 1.8"},
      {:phoenix_live_view, "~> 1.1"},
      {:phoenix_html, "~> 4.0"},
      {:jason, "~> 1.4"},
      {:req, "~> 0.5"},
      {:fresco_strip, "~> 0.2"},
      {:etcher, "~> 0.7", optional: true},
      {:ex_doc, "~> 0.39", only: :dev, runtime: false}
    ]
  end

  defp package do
    [
      name: "manhwa",
      maintainers: ["Alexander Don"],
      licenses: ["MIT"],
      links: %{"GitHub" => @source_url},
      files: ~w(lib mix.exs README.md LICENSE CHANGELOG.md)
    ]
  end

  defp docs do
    [
      name: "Manhwa",
      source_ref: "v#{@version}",
      source_url: @source_url,
      main: "Manhwa",
      extras: ["README.md", "CHANGELOG.md", "LICENSE"]
    ]
  end
end
