#!/usr/bin/env bash
# GUI smoke test in the real game window (own profile). Opens a window for ~30 s, then closes it.
set -euo pipefail
source "$(dirname "$0")/env.sh"
GT="$HOME/Library/Application Support/factorio-guitest"
mkdir -p "$GT/config" "$GT/mods" "$GT/saves"
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$GT" > "$GT/config/config.ini"
ln -sfn "$REPO/empirical-science" "$GT/mods/empirical-science"
ln -sfn "$REPO/tests/es-guitest" "$GT/mods/es-guitest"
ensure_charts
ln -sfn "$CHARTS" "$GT/mods/factorio-charts"
results="$GT/script-output/es-guitest-results.txt"

# Close the test game on this profile; a game showing an error dialog ignores a polite request.
close_game() {
  pkill -f "$GT/config/config.ini" 2>/dev/null || true
  for _ in 1 2 3 4 5; do pgrep -f "$GT/config/config.ini" > /dev/null || return 0; sleep 1; done
  pkill -9 -f "$GT/config/config.ini" 2>/dev/null || true
  sleep 1
}
close_game  # a leftover from an interrupted run would hold the profile lock
rm -f "$results" "$GT/saves/gui.zip"

"$FACTORIO" --config "$GT/config/config.ini" --create "$GT/saves/gui.zip" > "$GT/test.out" 2>&1 \
  || { echo "GUI TEST FAILED: could not create map"; tail -20 "$GT/test.out"; exit 1; }
# Launched directly, the game asks Steam to relaunch it, and Steam may show a prompt that needs a
# click. A steam_appid.txt in the working directory (standard Steamworks behaviour) makes the game
# skip that relaunch; Steam must still be running. Track the game by its profile path either way.
game_running() { pgrep -f "$GT/config/config.ini" > /dev/null; }
echo 427520 > "$GT/steam_appid.txt"
(cd "$GT" && exec "$FACTORIO" --config "$GT/config/config.ini" --load-game "$GT/saves/gui.zip" >> "$GT/test.out" 2>&1) &
status="timeout"
started=0
for _ in $(seq 1 150); do
  sleep 1
  if [ -f "$results" ]; then status="done"; break; fi
  if grep -q "caused a non-recoverable error" "$GT/factorio-current.log" 2>/dev/null; then status="error"; break; fi
  if game_running; then started=1; elif [ "$started" = 1 ]; then status="exited"; break; fi
done
close_game

case "$status" in
  done) cat "$results"; grep -q "^DONE ALL PASSED" "$results" ;;
  error) echo "GUI TEST FAILED: mod error"; grep -A8 "non-recoverable" "$GT/factorio-current.log" | head -14; exit 1 ;;
  *) echo "GUI TEST FAILED: $status"; tail -15 "$GT/factorio-current.log"; exit 1 ;;
esac
