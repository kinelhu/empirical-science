#!/usr/bin/env bash
# Create the isolated dev profile and symlink the repo's mods into it. Idempotent.
set -euo pipefail
source "$(dirname "$0")/env.sh"

mkdir -p "$DEV/config" "$DEV/mods" "$DEV/saves"
cat > "$CONFIG" <<INI
[path]
read-data=__PATH__system-read-data__
write-data=$DEV
INI

for m in $MODS; do
  ln -sfn "$REPO/$m" "$DEV/mods/$m"
done
ensure_charts
ln -sfn "$CHARTS" "$DEV/mods/factorio-charts"

# Test helpers (Editor Extensions + its dependency flib), copied (not linked) from the real profile.
for pat in EditorExtensions flib; do
  z=$(ls "$REAL/mods"/${pat}_*.zip 2>/dev/null | sort -V | tail -1 || true)
  [ -n "$z" ] && cp -n "$z" "$DEV/mods/" || true
done

echo "dev profile ready: $DEV"
ls -la "$DEV/mods"
