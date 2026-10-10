#!/usr/bin/env bash
# Robot playthrough (tests/es-playthrough): screen, confirm, adopt, produce; report. Usage: [seed]
set -euo pipefail
source "$(dirname "$0")/env.sh"
ensure_charts
PT="$HOME/Library/Application Support/factorio-playthrough"
SEED="${1:-12345}"
mkdir -p "$PT/config" "$PT/mods" "$PT/saves"
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$PT" > "$PT/config/config.ini"
ln -sfn "$REPO/empirical-science" "$PT/mods/empirical-science"
ln -sfn "$REPO/tests/es-playthrough" "$PT/mods/es-playthrough"
ln -sfn "$CHARTS" "$PT/mods/factorio-charts"
rm -f "$PT/script-output/es-playthrough.txt" "$PT/saves/p.zip"
"$FACTORIO" --config "$PT/config/config.ini" --create "$PT/saves/p.zip" --map-gen-seed "$SEED" > "$PT/run.out" 2>&1
"$FACTORIO" --config "$PT/config/config.ini" --benchmark "$PT/saves/p.zip" --benchmark-ticks 216000 >> "$PT/run.out" 2>&1 \
  || { grep -A8 Error "$PT/run.out" | head -16; exit 1; }
cat "$PT/script-output/es-playthrough.txt"
grep -q "^DONE ALL PASSED" "$PT/script-output/es-playthrough.txt"
