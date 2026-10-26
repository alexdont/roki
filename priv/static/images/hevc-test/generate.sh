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

# HLS variants, to find what iOS Safari accepts: A (above, plain), B proper GOPs + master playlist with CODECS,
# C video only, D the same as B in H.264 (does fMP4 HLS itself play).
GOP="-x265-params log-level=error:keyint=60:min-keyint=60:scenecut=0"
HLS="-f hls -hls_time 2 -hls_playlist_type vod -hls_segment_type fmp4 -hls_flags independent_segments"
mkdir -p hlsB hlsC hlsD
nice -n 15 ffmpeg -loglevel error -y $S1080 -t 8 -c:v libx265 -preset ultrafast -pix_fmt yuv420p -tag:v hvc1 $GOP -crf 28 -c:a aac -b:a 96k -map 0:v -map 1:a $HLS -master_pl_name master.m3u8 -hls_fmp4_init_filename init.mp4 -hls_segment_filename "hlsB/seg%d.m4s" hlsB/index.m3u8
nice -n 15 ffmpeg -loglevel error -y $S1080 -t 8 -c:v libx265 -preset ultrafast -pix_fmt yuv420p -tag:v hvc1 $GOP -crf 28 -an $HLS -master_pl_name master.m3u8 -hls_fmp4_init_filename init.mp4 -hls_segment_filename "hlsC/seg%d.m4s" hlsC/index.m3u8
nice -n 15 ffmpeg -loglevel error -y $S1080 -t 8 -c:v libx264 -preset ultrafast -pix_fmt yuv420p -g 60 -keyint_min 60 -sc_threshold 0 -crf 28 -c:a aac -b:a 96k -map 0:v -map 1:a $HLS -master_pl_name master.m3u8 -hls_fmp4_init_filename init.mp4 -hls_segment_filename "hlsD/seg%d.m4s" hlsD/index.m3u8

# Fragmented MP4 files played directly, no HLS around them
FRAG="-c:v libx265 -preset ultrafast -pix_fmt yuv420p -tag:v hvc1 -x265-params log-level=error:keyint=60:min-keyint=60:scenecut=0:open-gop=0 -crf 28 -c:a aac -b:a 96k"
nice -n 15 ffmpeg -loglevel error -y $S1080 -t 8 $FRAG -movflags frag_keyframe+empty_moov+default_base_moof hevc-frag.mp4
nice -n 15 ffmpeg -loglevel error -y $S1080 -t 8 $FRAG -movflags cmaf+frag_keyframe+empty_moov+default_base_moof hevc-cmaf.mp4
