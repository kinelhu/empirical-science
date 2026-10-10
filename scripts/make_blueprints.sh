#!/usr/bin/env bash
# Regenerates empirical-science/scripts/blueprints.lua: the example builds (tests/es-blueprints) exported
# with the mod's own blueprint tagging. Run after changing a prototype, a tag or an example.
set -euo pipefail
source "$(dirname "$0")/env.sh"
ensure_charts
BP="$HOME/Library/Application Support/factorio-blueprints"
mkdir -p "$BP/config" "$BP/mods" "$BP/saves"
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$BP" > "$BP/config/config.ini"
ln -sfn "$REPO/empirical-science" "$BP/mods/empirical-science"
ln -sfn "$REPO/tests/es-blueprints" "$BP/mods/es-blueprints"
ln -sfn "$CHARTS" "$BP/mods/factorio-charts"
rm -f "$BP/saves/bp.zip" "$BP/script-output/es-blueprints.lua"
"$FACTORIO" --config "$BP/config/config.ini" --create "$BP/saves/bp.zip" > "$BP/create.out" 2>&1 \
  || { grep -A10 Error "$BP/create.out" | head -20; exit 1; }
"$FACTORIO" --config "$BP/config/config.ini" --benchmark "$BP/saves/bp.zip" --benchmark-ticks 130 \
  > "$BP/bench.out" 2>&1 || { grep -hA10 Error "$BP/bench.out" "$BP/factorio-current.log" | head -20; exit 1; }
[ -s "$BP/script-output/es-blueprints.lua" ] || { echo "no blueprints written"; exit 1; }
cp "$BP/script-output/es-blueprints.lua" "$REPO/empirical-science/scripts/blueprints.lua"
echo "written: empirical-science/scripts/blueprints.lua ($(grep -c ' = "' "$REPO/empirical-science/scripts/blueprints.lua") blueprints)"
