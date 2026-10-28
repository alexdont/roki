defmodule TesseractJs.ConfigTest do
  use ExUnit.Case, async: false
  alias TesseractJs.Config

  @keys [:base_path, :lang, :source, :tessdata_repo, :core_variant]

  setup do
    clear_env()
    on_exit(&clear_env/0)
    :ok
  end

  defp clear_env do
    Enum.each(@keys, &Application.delete_env(:tesseract_js, &1))
  end

  test "defaults" do
    Application.put_all_env(tesseract_js: [])
    cfg = Config.get()
    assert cfg.lang == "eng"
    assert cfg.source == :cdn
    assert cfg.tessdata_repo == :standard
    assert cfg.core_variant == :simd_lstm
    assert cfg.base_path == "/assets/vendor/tesseract"
  end

  test "Application env overrides defaults" do
    Application.put_all_env(tesseract_js: [lang: "jpn", source: :local])
    cfg = Config.get()
    assert cfg.lang == "jpn"
    assert cfg.source == :local
  end

  test "inline opts override Application env" do
    Application.put_all_env(tesseract_js: [lang: "jpn"])
    cfg = Config.get(lang: "kor")
    assert cfg.lang == "kor"
  end

  test "runtime/1 in :cdn mode points lang+core at jsDelivr" do
    Application.put_all_env(tesseract_js: [])
    rt = Config.runtime()
    assert rt.workerPath == "/assets/vendor/tesseract/worker.min.js"
    assert rt.tesseractPath == "/assets/vendor/tesseract/tesseract.min.js"
    assert rt.corePath =~ "cdn.jsdelivr.net"
    assert rt.langPath =~ "cdn.jsdelivr.net"
    assert rt.lang == "eng"
  end

  test "runtime/1 in :local mode points core+lang at base_path" do
    Application.put_all_env(tesseract_js: [source: :local])
    rt = Config.runtime()
    assert rt.corePath == "/assets/vendor/tesseract/tesseract-core-simd-lstm.wasm.js"
    assert rt.langPath == "/assets/vendor/tesseract"
  end

  test "custom base_path flows through" do
    Application.put_all_env(tesseract_js: [source: :local, base_path: "/custom/path"])
    rt = Config.runtime()
    assert rt.workerPath == "/custom/path/worker.min.js"
    assert rt.langPath == "/custom/path"
  end
end
