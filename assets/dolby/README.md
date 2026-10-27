# dolby.wasm — Dolby AC-3 / E-AC-3 and DTS decoding in the browser

`/vendor/dolby.wasm` (+ `dolby.mjs`, the Emscripten glue) is FFmpeg 7.1.1's `ac3`, `eac3` and
`dca` decoders and nothing else, behind `shim.c`: open a decoder by name, feed it the packets a
Matroska/MP4 file holds, get interleaved 32-bit float stereo back (the decoders mix down
themselves). 757 KB; decodes at ~300× realtime in Node. LGPL 2.1+ (FFmpeg) — the source is
`ffmpeg-7.1.1.tar.xz` from ffmpeg.org, built with `--disable-everything` plus those decoders.

Rebuild (needs Docker; downloads nothing but the FFmpeg source):

    mkdir -p /tmp/dolby && cp shim.c build.sh /tmp/dolby && cd /tmp/dolby
    curl -sSLO https://ffmpeg.org/releases/ffmpeg-7.1.1.tar.xz && tar -xJf ffmpeg-7.1.1.tar.xz
    docker run --rm -v "$PWD":/src -w /src emscripten/emsdk:latest bash /src/build.sh
    cp dolby.mjs dolby.wasm ../../priv/static/vendor/

`nodetest.mjs` decodes a directory of raw E-AC-3 packets (`ffmpeg -c copy -f segment
-segment_time 0.001 pkts/p%05d.eac3`) and prints frames, loudness and speed. The browser side
is `priv/static/lab/dolby.js`: a Mediabunny `CustomAudioDecoder` for `ac3`, `eac3` and `dts`.
