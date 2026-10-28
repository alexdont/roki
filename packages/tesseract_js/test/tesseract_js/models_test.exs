defmodule TesseractJs.ModelsTest do
  use ExUnit.Case, async: true
  alias TesseractJs.Models

  test "list/0 returns curated map" do
    list = Models.list()
    assert is_map(list)
    assert Map.has_key?(list, "eng")
    assert Map.has_key?(list, "jpn_vert")
  end

  test "filename/1 appends extension" do
    assert Models.filename("eng") == "eng.traineddata.gz"
    assert Models.filename("jpn_vert") == "jpn_vert.traineddata.gz"
  end

  test "cdn_url/2 builds jsDelivr URL for each tier" do
    assert Models.cdn_url("eng", :standard) =~ "@tesseract.js-data/eng@"
    # :standard sits at the bare tessdata version dir, no suffix
    assert Models.cdn_url("eng", :standard) =~ "/4.0.0/eng.traineddata.gz"
    # :best uses the LSTM-only "_best_int" variant on jsDelivr
    assert Models.cdn_url("eng", :best) =~ "_best_int/eng.traineddata.gz"
  end

  test "cdn_url/2 raises on unknown tier" do
    assert_raise ArgumentError, fn -> Models.cdn_url("eng", :weird) end
    # :fast is not supported in v0.1 (needs a different source + uncompressed handling)
    assert_raise ArgumentError, fn -> Models.cdn_url("eng", :fast) end
  end

  test "cdn_url/2 uses first lang for combined codes" do
    url = Models.cdn_url("eng+jpn")
    assert url =~ "/eng@"
    refute url =~ "+jpn"
  end

  test "core_cdn_url/1 covers all variants" do
    assert Models.core_cdn_url(:simd_lstm) =~ "tesseract.js-core@"
    assert Models.core_cdn_url(:simd_lstm) =~ "simd-lstm.wasm.js"
    assert Models.core_cdn_url(:simd) =~ "simd.wasm.js"
    assert Models.core_cdn_url(:basic) =~ "tesseract-core.wasm.js"
  end

  test "local_path/2 strips combined langs" do
    assert Models.local_path("eng") == "/assets/vendor/tesseract/eng.traineddata.gz"
    assert Models.local_path("eng+jpn") == "/assets/vendor/tesseract/eng.traineddata.gz"
    assert Models.local_path("eng", "/custom") == "/custom/eng.traineddata.gz"
  end

  test "split_langs/1 splits on +" do
    assert Models.split_langs("eng") == ["eng"]
    assert Models.split_langs("eng+jpn") == ["eng", "jpn"]
    assert Models.split_langs("eng + jpn + kor") == ["eng", "jpn", "kor"]
  end
end
