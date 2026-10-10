#!/usr/bin/env bash
# One map's hidden world (the answer key a long game would uncover), as JSON. Usage: [seed]
set -euo pipefail
source "$(dirname "$0")/env.sh"
ensure_charts
GT="$HOME/Library/Application Support/factorio-groundtruth"
SEED="${1:-12345}"
mkdir -p "$GT/config" "$GT/mods" "$GT/saves"
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$GT" > "$GT/config/config.ini"
ln -sfn "$REPO/empirical-science" "$GT/mods/empirical-science"
ln -sfn "$REPO/tests/es-groundtruth" "$GT/mods/es-groundtruth"
ln -sfn "$CHARTS" "$GT/mods/factorio-charts"
rm -f "$GT/script-output/es-groundtruth.json" "$GT/saves/g.zip"
"$FACTORIO" --config "$GT/config/config.ini" --create "$GT/saves/g.zip" --map-gen-seed "$SEED" > "$GT/run.out" 2>&1 \
  || { grep -A8 Error "$GT/factorio-current.log" | head -16; exit 1; }
[ -s "$GT/script-output/es-groundtruth.json" ] || { echo "nothing written"; exit 1; }
echo "$GT/script-output/es-groundtruth.json"
