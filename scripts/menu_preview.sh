#!/usr/bin/env bash
# The showcase factory as the main menu shows it (scripts/showcase.lua): a game window opens on the main menu
# with only that scene, screenshots are saved as it plays, and the window closes. No player joins, so no key
# press is needed. Steam allows one running copy: close your game first.
# Usage: scripts/menu_preview.sh [dose_study|before_after|frontier]
# Screenshots: ~/Library/Application Support/factorio-menupreview/shots/<scene>-*.png
set -euo pipefail
source "$(dirname "$0")/env.sh"
MP="$HOME/Library/Application Support/factorio-menupreview"
mkdir -p "$MP/config" "$MP/mods"
# A complete config (the main menu rejects the three-line one other profiles use, asking to reset it): the
# game's own defaults, with this profile's paths, windowed.
python3 - "$MP" <<'PY'
import sys, pathlib
mp = sys.argv[1]
src = pathlib.Path.home() / "Library/Application Support/factorio/config/config.ini"
out = []
for line in src.read_text().splitlines():
    if line.startswith("write-data="): line = "write-data=" + mp
    # Windowed (2026-10-06, user: the preview was extremely laggy; the GUI test, windowed, never was).
    if line.strip().startswith(("full-screen=", "; full-screen=")): line = "full-screen=false"
    out.append(line)
(pathlib.Path(mp) / "config/config.ini").write_text("\n".join(out) + "\n")
PY
ln -sfn "$REPO/empirical-science" "$MP/mods/empirical-science"
ln -sfn "$REPO/tests/es-menu-preview" "$MP/mods/es-menu-preview"
SCENE="${1:-dose_study}"
printf 'return "%s"\n' "$SCENE" > "$REPO/tests/es-menu-preview/scene.lua"
ensure_charts
ln -sfn "$CHARTS" "$MP/mods/factorio-charts"
rm -f "$MP/script-output/showcase-"*
close_game() {
  pkill -f "$MP/config/config.ini" 2>/dev/null || true
  for _ in 1 2 3 4 5; do pgrep -f "$MP/config/config.ini" > /dev/null || return 0; sleep 1; done
  pkill -9 -f "$MP/config/config.ini" 2>/dev/null || true
}
close_game
echo 427520 > "$MP/steam_appid.txt"
(cd "$MP" && exec "$FACTORIO" --config "$MP/config/config.ini" > "$MP/run.out" 2>&1) &
# A menu simulation cannot write files, so the screen itself is captured (macOS screencapture; needs the
# terminal's screen-recording permission) every few seconds once the game is up.
OUT="$MP/shots"; rm -rf "$OUT"; mkdir -p "$OUT"
for _ in $(seq 1 60); do sleep 1; grep -q "Factorio initialised" "$MP/factorio-current.log" 2>/dev/null && break; done
sleep "${PREVIEW_WAIT:-15}"
# The game's own window, by its id from macOS's window list (the game's process, its tallest window), captured
# with screencapture -l: that window's pixels only, whatever covers it (2026-10-06: a capture by screen region
# took in another app's window lying over the game's; it was deleted). Asked once.
GAME_PID="$(pgrep -f "$MP/config/config.ini" | head -1)"
wid=""
for _ in $(seq 1 25); do
  wid=$(uv run --quiet --with pyobjc-framework-Quartz python - "$GAME_PID" <<'PY' 2>/dev/null || true
import sys, Quartz
pid = int(sys.argv[1])
best, bh = None, 0
for w in Quartz.CGWindowListCopyWindowInfo(Quartz.kCGWindowListOptionAll, Quartz.kCGNullWindowID):
    b = w.get("kCGWindowBounds", {})
    if w.get("kCGWindowOwnerPID") == pid and w.get("kCGWindowLayer") == 0 and b.get("Height", 0) > bh:
        best, bh = w["kCGWindowNumber"], b.get("Height", 0)
if best and bh > 300: print(best)
PY
)
  [ -n "$wid" ] && break; sleep 1
done
[ -n "$wid" ] || { echo "no game window: nothing captured" >&2; close_game; exit 1; }
for i in $(seq 1 "${PREVIEW_SHOTS:-12}"); do
  screencapture -x -o -l "$wid" "$OUT/$SCENE-$(printf %02d "$i").png"
  sleep "${PREVIEW_EVERY:-5}"
done
close_game
grep -iE "error" -A6 "$MP/factorio-current.log" | head -20 || true
ls "$OUT"
