#!/bin/sh
set -eu
project_dir=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$project_dir"
export PATH="/opt/homebrew/bin:$PATH"
mkdir -p build/fixtures
if [ ! -f build/fixtures/h264.mp4 ]; then
    ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i testsrc2=size=640x360:rate=24 \
        -f lavfi -i sine=frequency=440:sample_rate=48000 -t 90 -filter:a volume=0.015 \
        -c:v libx264 -preset ultrafast -crf 26 -c:a aac -movflags +faststart build/fixtures/h264.mp4
fi
make_video() {
    output=$1
    shift
    if [ ! -f "build/fixtures/$output" ]; then
        ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i testsrc2=size=320x180:rate=10 \
            -t 30 -an "$@" "build/fixtures/$output"
    fi
}
make_video hevc.mkv -c:v libx265 -preset ultrafast -x265-params pools=2:log-level=error
make_video vp9.webm -c:v libvpx-vp9 -deadline realtime -cpu-used 8 -b:v 250k
make_video av1.mkv -c:v libsvtav1 -preset 12 -crf 45 -svtav1-params lp=2
make_video mpeg4.avi -c:v mpeg4 -q:v 5
make_video ffv1.mkv -c:v ffv1
for spec in 'portrait.mp4 180x320' 'ultrawide.mp4 420x180'; do
    set -- $spec
    if [ ! -f "build/fixtures/$1" ]; then
        ffmpeg -nostdin -hide_banner -loglevel error -f lavfi -i "testsrc2=size=$2:rate=10" \
            -t 5 -an -c:v libx264 -preset ultrafast "build/fixtures/$1"
    fi
done
printf 'Codec fixtures ready in %s/build/fixtures\n' "$project_dir"
