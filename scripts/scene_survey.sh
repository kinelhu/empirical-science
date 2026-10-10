#!/usr/bin/env bash
# What each vanilla menu scene contains around its camera (tests/es-scene-survey): loads each save headless for
# one tick with the survey mod and writes docs/scenes/<name>.json and a character map <name>.txt.
# Usage: scripts/scene_survey.sh [name...]
#        scripts/scene_survey.sh --augment <name>   the scene with the mod's machines added (<name>-augmented.*)
set -euo pipefail
source "$(dirname "$0")/env.sh"
SV="$HOME/Library/Application Support/factorio-survey"
mkdir -p "$SV/config" "$SV/mods" "$SV/saves" "$REPO/docs/scenes"
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$SV" > "$SV/config/config.ini"
ln -sfn "$REPO/tests/es-scene-survey" "$SV/mods/es-scene-survey"
SUFFIX=""; TICKS=1
rm -f "$SV/mods/empirical-science" "$SV/mods/factorio-charts" "$REPO/tests/es-scene-survey/augment.lua"
if [ "${1:-}" = "--augment" ]; then
  shift; SUFFIX="-augmented"; TICKS=1205
  ensure_charts
  ln -sfn "$REPO/empirical-science" "$SV/mods/empirical-science"
  ln -sfn "$CHARTS" "$SV/mods/factorio-charts"
  printf 'return "%s"\n' "$1" > "$REPO/tests/es-scene-survey/augment.lua"
fi
names=("$@")
[ ${#names[@]} -gt 0 ] || names=($(ls "$APP/data/base/menu-simulations/" | grep zip | sed 's/menu-simulation-//; s/.zip//'))
for n in "${names[@]}"; do
  cp "$APP/data/base/menu-simulations/menu-simulation-$n.zip" "$SV/saves/s.zip"
  rm -f "$SV/script-output/scene-survey.json"
  "$FACTORIO" --config "$SV/config/config.ini" --benchmark "$SV/saves/s.zip" --benchmark-ticks "$TICKS" > "$SV/run.out" 2>&1 || true
  if [ -s "$SV/script-output/scene-survey.json" ]; then
    cp "$SV/script-output/scene-survey.json" "$REPO/docs/scenes/$n$SUFFIX.json"
    grep -q "district machines not running" "$SV/run.out" && { grep -a "district machines not running" "$SV/run.out" | head -2; exit 1; }
    cp "$SV/script-output/scene-map.txt" "$REPO/docs/scenes/$n$SUFFIX.txt"; echo "$n ok"
  else echo "$n: nothing"; { grep -iE "error" -A3 "$SV/run.out" || true; } | head -8; exit 1; fi
done
