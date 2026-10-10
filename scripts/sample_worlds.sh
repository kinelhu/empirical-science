#!/usr/bin/env bash
# Generate hidden worlds with the mod's own Lua and dump vanilla prototypes, for docs/balance.py.
# Outputs: $SAMPLER/script-output/es-worlds.json and data-raw-dump.json. ES_STRENGTH=gentle|harsh samples
# the same worlds at that world strength, 600 of them, into
# es-worlds-<strength>.json; the standard sample is 2,000.
set -euo pipefail
source "$(dirname "$0")/env.sh"
SAMPLER="$HOME/Library/Application Support/factorio-sampler"
mkdir -p "$SAMPLER/config" "$SAMPLER/mods" "$SAMPLER/saves"
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$SAMPLER" > "$SAMPLER/config/config.ini"
ln -sfn "$REPO/empirical-science" "$SAMPLER/mods/empirical-science"
ln -sfn "$REPO/tests/es-sampler" "$SAMPLER/mods/es-sampler"
ensure_charts
ln -sfn "$CHARTS" "$SAMPLER/mods/factorio-charts"
STRENGTH="${ES_STRENGTH:-standard}"
case "$STRENGTH" in standard) N=2000; OUT=es-worlds.json ;; gentle|harsh) N=600; OUT="es-worlds-$STRENGTH.json" ;;
  *) echo "ES_STRENGTH must be gentle, standard or harsh"; exit 1 ;; esac
printf 'return {n = %d, strength = "%s", out = "%s"}\n' "$N" "$STRENGTH" "$OUT" > "$REPO/tests/es-sampler/sample.lua"
# Reuse the last worlds when nothing they are made from has changed (a balance run
# waited minutes on worlds identical to the last ones). Everything the game loads goes into the
# fingerprint: both mods, the charts library, the game's version and the profile's mod list. ES_RESAMPLE=1
# regenerates regardless.
FP_FILE="$SAMPLER/script-output/${OUT%.json}.fingerprint"
# sample.lua (the strength and N) is left out: every strength's worlds share one fingerprint, so balance.py
# can tell whether the gentle and harsh samples were made from the same mod as the standard one. The dossier
# thresholds (scripts/dossier_*.lua) are left out too: balance.py writes them between the harsh and standard
# runs, so counting them made every standard run reject the harsh sample (2026-10-04).
fp=$( { find "$REPO/empirical-science" "$REPO/tests/es-sampler" "$CHARTS" -name .git -prune -o -name sample.lua -prune \
          -o -name 'dossier_*.lua' -prune \
          -o -type f -print0 \
        | sort -z | xargs -0 shasum; "$FACTORIO" --version | head -1; cat "$SAMPLER/mods/mod-list.json" 2>/dev/null; } \
      | shasum | cut -d' ' -f1)
if [ -z "${ES_RESAMPLE:-}" ] && [ -s "$SAMPLER/script-output/$OUT" ] \
   && [ -s "$SAMPLER/script-output/data-raw-dump.json" ] && [ "$(cat "$FP_FILE" 2>/dev/null)" = "$fp" ]; then
  echo "worlds unchanged since the last sample (fingerprint ${fp:0:12}): reusing them"
  exit 0
fi
rm -f "$FP_FILE"
rm -f "$SAMPLER/script-output/$OUT" "$SAMPLER/script-output/data-raw-dump.json" "$SAMPLER/saves/s.zip"
"$FACTORIO" --config "$SAMPLER/config/config.ini" --dump-data > "$SAMPLER/run.out" 2>&1
"$FACTORIO" --config "$SAMPLER/config/config.ini" --create "$SAMPLER/saves/s.zip" >> "$SAMPLER/run.out" 2>&1 \
  || { grep -A8 Error "$SAMPLER/factorio-current.log" | head -20; exit 1; }
[ -s "$SAMPLER/script-output/$OUT" ] || { echo "no worlds written"; exit 1; }
echo "$fp" > "$FP_FILE"
ls -la "$SAMPLER/script-output/"
