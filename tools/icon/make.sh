#!/usr/bin/env bash
# Writes every platform's launcher icon from speaker_1024.png. That PNG is
# speaker.svg rendered by Chrome (ImageMagick's own SVG renderer drops the
# gradients):
#   chrome --headless=new --default-background-color=00000000 \
#     --window-size=1024,1024 --screenshot=speaker_1024.png speaker.svg
set -euo pipefail
cd "$(dirname "$0")"
src=speaker_1024.png
root=../..

mac=$root/app_desktop/macos/Runner/Assets.xcassets/AppIcon.appiconset
for s in 16 32 64 128 256 512 1024; do
  magick $src -resize ${s}x${s} "$mac/app_icon_$s.png"
done

magick $src -define icon:auto-resize=256,128,64,48,32,16 \
  $root/app_desktop/windows/runner/resources/app_icon.ico

# Phones want an opaque square; the OS cuts its own corners.
flat=$(mktemp -t icon).png
magick $src -background '#17171c' -alpha remove -alpha off "$flat"

ios=$root/app_remote/ios/Runner/Assets.xcassets/AppIcon.appiconset
for f in "$ios"/Icon-App-*.png; do
  n=$(basename "$f" .png)                 # Icon-App-83.5x83.5@2x
  pt=${n#Icon-App-}; pt=${pt%%x*}         # 83.5
  scale=${n##*@}; scale=${scale%x}        # 2
  px=$(awk -v p="$pt" -v s="$scale" 'BEGIN{printf "%d", p*s}')
  magick "$flat" -resize ${px}x${px} "$f"
done

res=$root/app_remote/android/app/src/main/res
for d in mdpi:48 hdpi:72 xhdpi:96 xxhdpi:144 xxxhdpi:192; do
  magick $src -resize ${d#*:}x${d#*:} "$res/mipmap-${d%:*}/ic_launcher.png"
done
rm -f "$flat"
echo "icons written"
