#!/bin/bash
# Regenerates the test fixtures. Needs ffmpeg with libmp3lame/libopus/libvorbis.
set -e
gen() { ffmpeg -hide_banner -loglevel error -y -f lavfi -i sine=frequency=440:sample_rate=96000:duration=1.5 -f lavfi -i sine=frequency=660:sample_rate=96000:duration=1.5 -filter_complex "[0:a][1:a]amerge=inputs=2[a]" -map "[a]" "$@"; }
gen -ar 44100 -sample_fmt s16 -metadata title="Sine Sixteen" -metadata artist="Ol1n" -metadata album="Test" -metadata track=3/12 -metadata date=2026 sine16_44.flac
gen -ar 96000 -sample_fmt s32 -metadata title="Sine TwentyFour" sine24_96.flac
gen -ar 48000 -c:a pcm_s24le sine24_48.wav
gen -ar 44100 -c:a pcm_s16le sine16_44.wav
gen -ar 44100 -c:a alac -sample_fmt s32p sine24_44.m4a
gen -ar 44100 -c:a libmp3lame -b:a 192k sine.mp3
gen -ar 44100 -c:a aac -b:a 128k sine_aac.m4a
gen -ar 48000 -c:a libopus -b:a 96k sine.opus
gen -ar 44100 -c:a vorbis -strict -2 sine.ogg || true
gen -ar 44100 -c:a pcm_s16be sine16_44.aiff
gen -ar 44100 -c:a wavpack sine24_44.wv || true
ffmpeg -hide_banner -loglevel error -y -i sine24_96.flac -f s32le ref_sine24_96.s32le.raw
ffmpeg -hide_banner -loglevel error -y -i sine16_44.flac -f s16le ref_sine16_44.s16le.raw
ffmpeg -hide_banner -loglevel error -y -i sine24_48.wav -f s32le ref_sine24_48.s32le.raw
ffmpeg -hide_banner -loglevel error -y -i sine24_44.m4a -f s32le ref_sine24_44_alac.s32le.raw
ffmpeg -hide_banner -loglevel error -y -f lavfi -i color=c=red:s=64x64:d=1 -frames:v 1 cover.png
ffmpeg -hide_banner -loglevel error -y -i sine16_44.flac -i cover.png -map 0:a -map 1 -c copy -disposition:v attached_pic -metadata:s:v title="Album cover" sine_cover.flac
