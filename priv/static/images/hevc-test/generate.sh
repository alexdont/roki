#!/bin/sh
# Rebuilds the test clips next to this file (they are not kept in git). Run inside the roki container.
set -e
cd "$(dirname "$0")"
mkdir -p hls
S1080="-f lavfi -i testsrc2=size=1920x1080:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000"
S2160="-f lavfi -i testsrc2=size=3840x2160:rate=30 -f lavfi -i sine=frequency=440:sample_rate=48000"
X265="-c:v libx265 -preset ultrafast -pix_fmt yuv420p -tag:v hvc1 -x265-params log-level=error -c:a aac -b:a 96k"
nice -n 15 ffmpeg -loglevel error -y $S1080 -t 6 $X265 -crf 28 -movflags +faststart hevc1080.mp4
nice -n 15 ffmpeg -loglevel error -y $S2160 -t 4 $X265 -crf 30 -movflags +faststart hevc2160.mp4
nice -n 15 ffmpeg -loglevel error -y $S1080 -t 6 -c:v libx264 -preset ultrafast -crf 28 -pix_fmt yuv420p -c:a aac -b:a 96k -movflags +faststart h264-1080.mp4
nice -n 15 ffmpeg -loglevel error -y $S1080 -t 8 $X265 -crf 28 -f hls -hls_time 2 -hls_playlist_type vod -hls_segment_type fmp4 -hls_fmp4_init_filename init.mp4 -hls_segment_filename "hls/seg%d.m4s" hls/index.m3u8
