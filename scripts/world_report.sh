#!/usr/bin/env bash
# A seed's field report (docs/world_report): its hidden world, the robot's first run on it, chain leverage,
# family chemistry and the targets' best moves, as one HTML page. Usage: scripts/world_report.sh [seed]
# Writes docs/world_report/out/seed-<seed>.html (gitignored). A designer's QA view; it spoils the map.
set -euo pipefail
cd "$(dirname "$0")/.."
SEED="${1:-12345}"
source scripts/env.sh
WORK="$(mktemp -d)"
GT="$HOME/Library/Application Support/factorio-groundtruth/script-output"
scripts/ground_truth.sh "$SEED" > /dev/null
scripts/playthrough.sh "$SEED" > /dev/null || true  # (the log is read whether or not every check passed)
cp "$HOME/Library/Application Support/factorio-playthrough/script-output/es-playthrough.txt" "$WORK/run.txt"
python3 docs/world_report/chains.py "$GT/es-groundtruth.json" "$DEV/script-output/data-raw-dump.json" "$WORK/chains.json" > /dev/null
python3 docs/world_report/build_data.py "$GT" "$WORK" > /dev/null
mkdir -p docs/world_report/out
python3 docs/world_report/build_page.py "$WORK" "docs/world_report/out/seed-$SEED.html"
echo "written: docs/world_report/out/seed-$SEED.html"
