#!/bin/bash
# Generates the audio files the tests use, with this Mac's voice. Apple's license limits
# sharing those recordings, so they aren't in the repository, and scripts/test.sh runs
# this when they're missing. It also needs ffmpeg: brew install ffmpeg
set -euo pipefail
cd "$(dirname "$0")/.."

out="Tests/PodcastReaderCoreTests/Fixtures"
work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
mkdir -p "$out"

say -o "$work/speech.aiff" "Memory is rebuilt every time you recall it. Testing yourself makes that path stronger. Spacing your study over several days works better than cramming."

ffmpeg -y -loglevel error -i "$work/speech.aiff" -c:a libmp3lame -b:a 128k "$out/sample.mp3"
ffmpeg -y -loglevel error -i "$work/speech.aiff" -c:a libmp3lame -q:a 4 "$out/sample_vbr.mp3"
ffmpeg -y -loglevel error -i "$work/speech.aiff" -c:a aac -b:a 96k "$out/sample.m4a"
ffmpeg -y -loglevel error -i "$work/speech.aiff" "$out/sample.wav"
ffmpeg -y -loglevel error -f lavfi -i anullsrc=r=44100:cl=mono -t 15 -c:a libmp3lame -q:a 4 "$out/silence.mp3"
printf 'this is not audio\n' > "$out/notaudio.mp3"

ls -lh "$out"
