#!/usr/bin/env bash
# The mod page's pictures (docs/modpage/images), in a real game window (own profile): the menu's lab scene
# (baked by scene_workshop.sh bake lab) and the findings playtest save's panels. Two short game windows, one
# after the other; each may wait for one Tab press (the tutorial bubble, as in scripts/guitest.sh).
# Usage: scripts/page_shots.sh [hero|panels]. The game must be closed (Steam allows one copy). Screenshots land in …/factorio-pageshots/script-output.
set -euo pipefail
source "$(dirname "$0")/env.sh"
PS="$HOME/Library/Application Support/factorio-pageshots"
MOD="$REPO/tests/es-page-shots"
mkdir -p "$PS/config" "$PS/mods" "$PS/saves"
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$PS" > "$PS/config/config.ini"
ensure_charts
ln -sfn "$REPO/empirical-science" "$PS/mods/empirical-science"
ln -sfn "$MOD" "$PS/mods/es-page-shots"
ln -sfn "$CHARTS" "$PS/mods/factorio-charts"
echo 427520 > "$PS/steam_appid.txt"
done_file="$PS/script-output/es-page-shots-done.txt"
for f in es-bake-lab.zip es-bake-lab.camera.lua es-findings.zip; do
  [ -f "$DEV/saves/$f" ] || { echo "missing $DEV/saves/$f (scene_workshop.sh bake lab; make_playtest.sh findings)"; exit 1; }
done

close_game() {
  pkill -f "$PS/config/config.ini" 2>/dev/null || true
  for _ in 1 2 3 4 5; do pgrep -f "$PS/config/config.ini" > /dev/null || return 0; sleep 1; done
  pkill -9 -f "$PS/config/config.ini" 2>/dev/null || true
  sleep 1
}
game_running() { pgrep -f "$PS/config/config.ini" > /dev/null; }

# run <shot> <save>: one window, closed once the mod says it is done.
run() {
  if [ "$1" = hero ]; then
    printf 'return {shot = "hero", camera = (function() %s end)()}\n' "$(cat "$DEV/saves/es-bake-lab.camera.lua")" > "$MOD/mode.lua"
  else
    printf 'return {shot = "%s"}\n' "$1" > "$MOD/mode.lua"
  fi
  cp "$DEV/saves/$2" "$PS/saves/in.zip"
  close_game
  rm -f "$done_file"
  (cd "$PS" && exec "$FACTORIO" --config "$PS/config/config.ini" --load-game "$PS/saves/in.zip" > "$PS/run.out" 2>&1) &
  local status=timeout started=0
  for _ in $(seq 1 150); do
    sleep 1
    if [ -f "$done_file" ]; then status=done; sleep 2; break; fi
    if grep -q "caused a non-recoverable error" "$PS/factorio-current.log" 2>/dev/null; then status=error; break; fi
    if game_running; then started=1; elif [ "$started" = 1 ]; then status=exited; break; fi
  done
  close_game
  case "$status" in
    done) cat "$done_file"; ! grep -q missing "$done_file" ;;
    error) echo "PAGE SHOTS FAILED ($1): mod error"; grep -A8 "non-recoverable" "$PS/factorio-current.log" | head -14; return 1 ;;
    *) echo "PAGE SHOTS FAILED ($1): $status"; tail -15 "$PS/factorio-current.log"; return 1 ;;
  esac
}
# Which: "hero", "panels" or both (the default).
for which in ${1:-hero panels}; do
  case "$which" in
    hero) rm -f "$PS"/script-output/es-hero-*.png; run hero es-bake-lab.zip ;;
    panels) rm -f "$PS"/script-output/es-page-*.png; run panels es-findings.zip ;;
    *) echo "hero or panels"; exit 1 ;;
  esac
done
ls -la "$PS"/script-output/*.png
