#!/usr/bin/env bash
# Download the licensed sample videos, verify their sha256, and prepare the box-sim test streams:
# audio removed, 10 fps, keyframe every second (GOP 10), no B-frames, H.264.
# Transcoding runs inside the pinned go2rtc image (ffmpeg 8 + libx264), so the host needs no ffmpeg.
# License: CC BY 4.0, Intel IoT DevKit sample-videos. See test-media/README.md for attribution.
set -euo pipefail

cd "$(dirname "$0")/.."
DIR="$PWD/test-media"
IMG='alexxit/go2rtc:1.9.14@sha256:675c318b23c06fd862a61d262240c9a63436b4050d177ffc68a32710d9e05bae'
BASE='https://raw.githubusercontent.com/intel-iot-devkit/sample-videos/master'
mkdir -p "$DIR/originals"

fetch() {  # fetch <file> <sha256>
  local f="$1" sum="$2"
  if [[ ! -f "$DIR/originals/$f" ]] || ! echo "$sum  $DIR/originals/$f" | sha256sum -c --status; then
    curl -fL --retry 3 --retry-delay 2 -o "$DIR/originals/$f" "$BASE/$f"
  fi
  echo "$sum  $DIR/originals/$f" | sha256sum -c
}
fetch person-bicycle-car-detection.mp4 452b11b7e0efbd019f1d9570d0c790e90416ad4ad29eec6003872d08443140ef
fetch worker-zone-detection.mp4        b8b58b8100a81600bc42ee7ee082ced777b12a32a3619139ef289d27cbdcd284

transcode() {  # transcode <input> <output> <extra -vf filters>
  local in="$1" out="$2" vf="$3"
  if [[ -f "$DIR/$out" ]]; then echo "exists: $out"; return; fi
  sudo docker run --rm --network none --user "$(id -u):$(id -g)" -v "$DIR:/work" --entrypoint ffmpeg "$IMG" \
    -hide_banner -loglevel error -y -i "/work/originals/$in" \
    -map 0:v:0 -an -vf "$vf" \
    -c:v libx264 -preset medium -profile:v main -pix_fmt yuv420p -crf 26 \
    -g 10 -keyint_min 10 -sc_threshold 0 -bf 0 -movflags +faststart \
    "/work/$out"
  echo "created: $out"
}
transcode person-bicycle-car-detection.mp4 yard_cam.mp4      "fps=10"
transcode worker-zone-detection.mp4        warehouse_cam.mp4 "fps=10,scale=1280:720"

# Prove the prepared files have no audio stream and report their format.
for f in yard_cam.mp4 warehouse_cam.mp4; do
  sudo docker run --rm --network none -v "$DIR:/work:ro" --entrypoint ffprobe "$IMG" -v error \
    -show_entries stream=codec_type,codec_name,width,height,avg_frame_rate -of csv=p=0 "/work/$f" \
    | sed "s|^|$f: |"
done
