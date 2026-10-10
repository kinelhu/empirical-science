#!/usr/bin/env bash
# Build the playtest saves (tests/es-playtest-kit), one per theme, as es-<theme>.zip in the dev profile's saves.
# With "onboarding": the new-game save instead (tests/es-onboarding), as es-onboarding.zip.
# With "showcase": the all-in-one factory from raw ore (tests/es-showcase), as es-showcase.zip; it runs
# ten game-minutes instead of two (a jammed belt shows only after a while).
# Otherwise one save per theme (each save's evidence its own experiment): lab, discovery,
# fluids, quality, gleba, vulcanus, fulgora, platform, findings, saved as es-<theme>.zip; "all" builds each.
set -euo pipefail
THEMES="lab discovery fluids quality gleba vulcanus fulgora platform findings"
if [ "${1:-all}" = all ]; then
  for t in $THEMES; do "$0" "$t" || exit 1; done
  exit 0
fi
KIT=es-playtest-kit; SAVE="es-$1.zip"; THEME="$1"
TICKS=7200
if [ "$1" = onboarding ]; then KIT=es-onboarding; SAVE=es-onboarding.zip; THEME=; fi
if [ "$1" = showcase ]; then KIT=es-showcase; SAVE=es-showcase.zip; TICKS=36000; THEME=; fi
# "complete" (2026-10-09): every target's evidence filled in by a simulated history; not in "all" (minutes).
if [ -n "$THEME" ] && ! [[ " $THEMES complete " == *" $THEME "* ]]; then echo "unknown save: $THEME (one of: $THEMES, complete, onboarding, showcase, all)"; exit 1; fi
source "$(dirname "$0")/env.sh"
if [ -n "$THEME" ]; then printf 'return "%s"\n' "$THEME" > "$REPO/tests/es-playtest-kit/kit_choice.lua"; fi
ensure_charts
KP="$HOME/Library/Application Support/factorio-kit"
mkdir -p "$KP/config" "$KP/mods" "$KP/saves"
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$KP" > "$KP/config/config.ini"
ln -sfn "$REPO/empirical-science" "$KP/mods/empirical-science"
rm -f "$KP/mods/es-playtest-kit" "$KP/mods/es-onboarding" "$KP/mods/es-showcase"
ln -sfn "$REPO/tests/$KIT" "$KP/mods/$KIT"
ln -sfn "$CHARTS" "$KP/mods/factorio-charts"
rm -f "$KP/saves/$SAVE" "$KP/script-output/es-kit-status.txt"
# SEED=<n> rebuilds a given map (each build reports its seed): a failure on one map can be reproduced.
SEED_ARGS=(); [ -n "${SEED:-}" ] && SEED_ARGS=(--map-gen-seed "$SEED")
"$FACTORIO" --config "$KP/config/config.ini" --create "$KP/saves/$SAVE" ${SEED_ARGS[@]+"${SEED_ARGS[@]}"} > "$KP/create.out" 2>&1 \
  || { grep -A10 Error "$KP/create.out" | head -20; exit 1; }
# Check it runs: two game-minutes headless (and the kit's entities keep working).
"$FACTORIO" --config "$KP/config/config.ini" --benchmark "$KP/saves/$SAVE" --benchmark-ticks "$TICKS" \
  > "$KP/bench.out" 2>&1 || { grep -A10 Error "$KP/bench.out" | head -20; exit 1; }
echo "== $SAVE"
grep -E "^map seed|^station at|made|crafts|trials|findings|\(O\)|\(L\)|\(J-K\)|\(M\)|\(N\)|^KIT" "$KP/script-output/es-kit-status.txt"
# A failed build prints its whole status (the seed included) so it can be replayed with SEED=.
grep -q "^KIT OK" "$KP/script-output/es-kit-status.txt" || {
  cat "$KP/script-output/es-kit-status.txt"; echo "the kit does not work: not saved"; exit 1; }
# The complete save's screen must stay quick on its evidence (2026-10-09: it froze the game for a minute).
# First open: one product's summaries under 1 s, Coverage under 3 s; reopened: findings under 1.5 s.
if [ "$THEME" = complete ]; then
  python3 - "$KP/factorio-current.log" <<'PY' || { echo "the complete save's screen is too slow: not kept"; exit 1; }
import re, sys
t = re.findall(r"control.lua:\d+: ([^:]+): Duration: ([\d.]+)ms", open(sys.argv[1]).read())
first = {k: float(v) for k, v in t[:5]}; second = {k: float(v) for k, v in t[5:10]}
limits = [(first, "summaries, gear, 5 effects", 1000), (first, "research rows, every target x additive (Coverage)", 3000),
          (second, "dossiers.evaluate", 1500)]
bad = [f"{k} {d[k]:.0f} ms (limit {lim})" for d, k, lim in limits if d.get(k, 1e9) > lim]
print("screen timings:", "; ".join(f"{k} {v:.0f} ms" for k, v in first.items()))
if bad: print("too slow:", "; ".join(bad)); sys.exit(1)
PY
fi
# The findings save must reach the ending by itself: ten more game-minutes, then finished.
if [ "$THEME" = findings ]; then
  rm -f "$KP/script-output/es-kit-findings-end.txt"
  "$FACTORIO" --config "$KP/config/config.ini" --benchmark "$KP/saves/$SAVE" --benchmark-ticks 36100 > "$KP/val.out" 2>&1 || true
  grep -q "^finished true" "$KP/script-output/es-kit-findings-end.txt" 2>/dev/null || {
    cat "$KP/script-output/es-kit-findings-end.txt" 2>/dev/null; echo "the findings save does not reach the ending: not saved"; exit 1; }
  echo "findings: the ending is reached in ten game-minutes"
fi
mkdir -p "$DEV/saves"
cp "$KP/saves/$SAVE" "$DEV/saves/$SAVE"
echo "saved: $DEV/saves/$SAVE"
