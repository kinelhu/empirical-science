#!/usr/bin/env bash
# The circuit tips' scenes as the Tips window runs them: base game, this mod and its library only, no Space
# Age or Quality, and no test hooks (tests/tips-check: its name must not start with "es-"). Headless, own profile.
set -euo pipefail
source "$(dirname "$0")/env.sh"
ensure_charts
TC="$HOME/Library/Application Support/factorio-tipscheck"
mkdir -p "$TC/config" "$TC/mods" "$TC/saves"
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$TC" > "$TC/config/config.ini"
ln -sfn "$REPO/empirical-science" "$TC/mods/empirical-science"
rm -f "$TC/mods/es-tips-check"
ln -sfn "$REPO/tests/tips-check" "$TC/mods/tips-check"
ln -sfn "$CHARTS" "$TC/mods/factorio-charts"
printf '{"mods": [{"name": "base", "enabled": true}, {"name": "empirical-science", "enabled": true}, {"name": "factorio-charts", "enabled": true}, {"name": "tips-check", "enabled": true}, {"name": "space-age", "enabled": false}, {"name": "quality", "enabled": false}, {"name": "elevated-rails", "enabled": false}]}' > "$TC/mods/mod-list.json"
out="$TC/script-output/es-tips-check.txt"
rm -f "$out" "$TC/saves/t.zip"
"$FACTORIO" --config "$TC/config/config.ini" --create "$TC/saves/t.zip" > "$TC/create.out" 2>&1 \
  || { echo "TIPS CHECK FAILED: create"; grep -A8 Error "$TC/create.out" | head -16; exit 1; }
"$FACTORIO" --config "$TC/config/config.ini" --benchmark "$TC/saves/t.zip" --benchmark-ticks 7300 > "$TC/run.out" 2>&1 \
  || { echo "TIPS CHECK FAILED: run"; grep -hA8 Error "$TC/run.out" "$TC/factorio-current.log" | head -16; exit 1; }
[ -f "$out" ] || { echo "TIPS CHECK FAILED: no results"; exit 1; }
cat "$out"
grep -q "^DONE ALL PASSED" "$out"
