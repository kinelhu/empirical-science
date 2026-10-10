#!/usr/bin/env bash
# Headless integration test in its own profile: builds a lab, runs 10 game-minutes, asserts.
set -euo pipefail
source "$(dirname "$0")/env.sh"
TEST="$HOME/Library/Application Support/factorio-test"
SEED="${1:-12345}"

mkdir -p "$TEST/config" "$TEST/mods" "$TEST/saves"
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$TEST" > "$TEST/config/config.ini"
ln -sfn "$REPO/empirical-science" "$TEST/mods/empirical-science"
ln -sfn "$REPO/tests/es-test" "$TEST/mods/es-test"
ensure_charts
ln -sfn "$CHARTS" "$TEST/mods/factorio-charts"
results="$TEST/script-output/es-test-results.txt"
rm -f "$results" "$TEST/saves/test.zip"

run() { "$FACTORIO" --config "$TEST/config/config.ini" "$@" > "$TEST/test.out" 2>&1 || {
  echo "TEST FAILED: factorio exited non-zero"; grep -hnE -A8 "Error" "$TEST/factorio-current.log" | head -30; exit 1; }; }
run --create "$TEST/saves/test.zip" --map-gen-seed "$SEED"
run --benchmark "$TEST/saves/test.zip" --benchmark-ticks 36300 --benchmark-runs 1

[ -f "$results" ] || { echo "TEST FAILED: no results written"; tail -20 "$TEST/test.out"; exit 1; }
cat "$results"
grep -q "^DONE ALL PASSED" "$results"
