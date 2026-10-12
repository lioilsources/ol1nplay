#!/usr/bin/env bash
# Builds a small tagged library (three albums, covers, one lyrics file) for
# screenshots and for trying the apps without pointing them at real music.
# The audio is sine tones with a quiet intro and slow swells, so the seek
# bar's loudness overview has something to show. Usage: tools/demo_library.sh <out-dir>
set -euo pipefail

out="${1:?usage: demo_library.sh <out-dir>}"
secs="${DEMO_SECS:-45}"

# album <dir> <artist> <album> <year> <rate> <sample_fmt> <bits> <gradient colours> <title>...
album() {
  local dir="$out/$1" artist="$2" name="$3" year="$4" rate="$5" fmt="$6" bits="$7" c0="$8" c1="$9"
  shift 9
  mkdir -p "$dir"
  ffmpeg -v error -y -f lavfi \
    -i "gradients=s=800x800:c0=$c0:c1=$c1:x0=0:y0=0:x1=800:y1=800:d=1" \
    -frames:v 1 "$dir/cover.jpg"
  local n=1 title
  for title in "$@"; do
    ffmpeg -v error -y -f lavfi \
      -i "sine=frequency=$((180 + n * 55)):sample_rate=$rate:duration=$((secs + n * 7))" \
      -af "volume=eval=frame:volume='0.012+0.22*gt(t,6)*pow(abs(sin(0.31*t+$n)),1.6)*(0.65+0.35*sin(2.1*t))'" -ac 2 -sample_fmt "$fmt" -bits_per_raw_sample "$bits" \
      -metadata artist="$artist" -metadata album_artist="$artist" \
      -metadata album="$name" -metadata title="$title" \
      -metadata track="$n" -metadata date="$year" \
      "$dir/$(printf '%02d' "$n") $title.flac"
    n=$((n + 1))
  done
}

album "Nils Aaberg Trio/Harbour Lights" "Nils Aaberg Trio" "Harbour Lights" 2019 \
  96000 s32 24 0x12355b 0xd7263d \
  "Low Tide" "Harbour Lights" "Salt and Rust" "The Long Pier" "Night Ferry"

album "Marta Kolar/Paper Rooms" "Marta Kolar" "Paper Rooms" 2022 \
  44100 s16 16 0x1b4332 0xf2cc8f \
  "Paper Rooms" "Window, Left Open" "Small Hours" "A Borrowed Coat"

album "Quartet Solaris/Schubert - String Quartet No. 14" "Quartet Solaris" \
  "Schubert: String Quartet No. 14" 2016 \
  192000 s32 24 0x2b2d42 0xe0a458 \
  "I. Allegro" "II. Andante con moto" "III. Scherzo" "IV. Presto"

cat > "$out/Nils Aaberg Trio/Harbour Lights/02 Harbour Lights.lrc" <<'EOF'
[00:00.00]Lamps along the water
[00:06.00]counting out the evening
[00:12.00]one for every boat that
[00:18.00]never left the quay
[00:24.00]Harbour lights, harbour lights
[00:30.00]keep the dark at bay
EOF

echo "demo library in $out"
