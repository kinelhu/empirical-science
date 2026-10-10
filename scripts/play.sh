#!/usr/bin/env bash
# Launch the game on the dev profile (your real saves and mods are untouched).
set -euo pipefail
source "$(dirname "$0")/env.sh"
exec "$FACTORIO" --config "$CONFIG" "$@"
