#!/bin/bash
# Builds dolby.wasm: FFmpeg's AC-3, E-AC-3 and DTS decoders and nothing else, behind shim.c.
# Run inside emscripten/emsdk with this directory mounted at /src.
set -euo pipefail
cd /src/ffmpeg-7.1.1
if [ ! -f libavcodec/libavcodec.a ]; then
  emconfigure ./configure \
    --cc=emcc --cxx=em++ --ar=emar --ranlib=emranlib --nm=llvm-nm \
    --target-os=none --arch=x86_32 --enable-cross-compile \
    --disable-x86asm --disable-inline-asm --disable-asm --disable-stripping \
    --disable-programs --disable-doc --disable-everything --disable-network \
    --disable-avdevice --disable-avformat --disable-avfilter --disable-swscale --disable-postproc --disable-swresample \
    --enable-avcodec --enable-avutil \
    --enable-decoder=ac3,eac3,dca,flac --enable-parser=ac3,dca,flac \
    --disable-pthreads --disable-debug --disable-autodetect \
    --extra-cflags="-O3 -fno-exceptions" > /src/configure.log 2>&1
  emmake make -j"$(nproc)" libavcodec/libavcodec.a libavutil/libavutil.a > /src/make.log 2>&1
fi
cd /src
emcc shim.c ffmpeg-7.1.1/libavcodec/libavcodec.a ffmpeg-7.1.1/libavutil/libavutil.a \
  -I ffmpeg-7.1.1 -O3 \
  -sMODULARIZE=1 -sEXPORT_ES6=1 -sENVIRONMENT=web,worker,node \
  -sEXPORTED_FUNCTIONS=_dolby_open,_dolby_decode,_dolby_flush,_dolby_close,_dolby_out,_dolby_channels,_dolby_rate,_malloc,_free \
  -sEXPORTED_RUNTIME_METHODS=HEAPU8,HEAPF32,stringToUTF8,lengthBytesUTF8 \
  -sALLOW_MEMORY_GROWTH=1 -sFILESYSTEM=0 -sINITIAL_MEMORY=32MB \
  -o dolby.mjs
ls -la dolby.mjs dolby.wasm
