#!/usr/bin/env bash
# Start (or resume) the VM and stream an app with Moonlight.
#   ./play.sh                 Deadlock
#   ./play.sh Desktop         the Windows desktop (Steam login, installs)
#   RES=2560x1600 BITRATE=60000 ./play.sh
source "$(dirname "$0")/lib.sh"
APP=${1:-Deadlock}
MOONLIGHT=/Applications/Moonlight.app/Contents/MacOS/Moonlight
[ -x "$MOONLIGHT" ] || die "Moonlight not installed: brew install --cask moonlight"

"$ROOT/deploy.sh"   # starts the VM if paused and waits until Sunshine answers
exec "$MOONLIGHT" stream "$(public_ip)" "$APP" --resolution "${RES:-1920x1200}" --fps 60 \
  --bitrate "${BITRATE:-40000}" --video-codec HEVC --display-mode fullscreen
