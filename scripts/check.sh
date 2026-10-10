#!/usr/bin/env bash
# Headless smoke test on the dev profile. Fails (non-zero) on any error.
#   1. data stage: load all mods and dump prototypes -> $DEV/script-output/data-raw-dump.json
#   2. control stage: create a fresh map, which runs every mod's on_init
set -euo pipefail
source "$(dirname "$0")/env.sh"
log="$DEV/factorio-current.log"

fail() {
  echo "CHECK FAILED ($1). Relevant output:"
  { grep -hnE -A6 "Error|Failed|error" "$log" "$DEV/check.out" || tail -15 "$DEV/check.out"; } | head -40
  exit 1
}

# 0. GUI element names must not shadow LuaGuiElement members (the headless test never opens a GUI)
uvx --quiet python "$REPO/scripts/lint_gui_names.py" "$APP/doc-html/runtime-api.json" "$REPO/empirical-science" \
  || { echo "CHECK FAILED (GUI element names)"; exit 1; }

# 0b. Every locale key the code uses exists (a missing one shows in game as "Unknown key").
uvx --quiet python "$REPO/scripts/lint_locale.py" "$REPO/empirical-science" || { echo "CHECK FAILED (locale)"; exit 1; }
# 0d. Every module in scripts/ ends by returning its table: an empty gui.lua (truncated by a tool) passed
# the stage checks below, which require it but never call it (2026-10-03).
for f in "$REPO"/empirical-science/scripts/*.lua; do
  last=$(grep -v '^[[:space:]]*$' "$f" | tail -1 || true)  # an empty file: grep finds nothing
  case "$last" in
    "return "*) ;;
    *) echo "CHECK FAILED ($(basename "$f") does not end by returning its module: empty or cut short?)"; exit 1 ;;
  esac
done
# 0c. docs/how-it-works.md names only what exists, and names every module, placeable entity and signal.
uvx --quiet python "$REPO/scripts/check_how_it_works.py" "$REPO" || { echo "CHECK FAILED (docs/how-it-works.md)"; exit 1; }
# table.deepcopy exists only in the data stage: control-stage code calling it crashes at runtime (the
# GUI test caught one, 2026-10-02, though dosing.lua carried a comment warning of it).
if grep -n "table\.deepcopy" "$REPO/empirical-science/control.lua" "$REPO/empirical-science/scripts/"*.lua | grep -v "^[^:]*:[0-9]*: *--"; then
  echo "CHECK FAILED (table.deepcopy in control-stage code: use shared.copy or util.table.deepcopy)"; exit 1
fi
# A bare "name = ..." at the top level makes a global unless "local name" came earlier in the file: a
# local declared below the assignment stays nil for the functions above it (gui.lua full_summaries, the
# GUI test, 2026-10-02).
globals=$(awk '
  FNR == 1 { delete declared }
  /^local [A-Za-z_][A-Za-z0-9_]*[ \t]*(--.*)?$/ { declared[$2] = 1 }
  /^[A-Za-z_][A-Za-z0-9_]*[ \t]*=[^=]/ { split($0, w, /[ \t=]/); if (!(w[1] in declared)) print FILENAME ":" FNR ": " $0 }
' "$REPO/empirical-science/control.lua" "$REPO/empirical-science/scripts/"*.lua)
if [ -n "$globals" ]; then
  echo "$globals"; echo "CHECK FAILED (top-level assignment to an undeclared name: declare it local above)"; exit 1
fi

# 1. data stage
rm -f "$DEV/script-output/data-raw-dump.json"
"$FACTORIO" --config "$CONFIG" --dump-data > "$DEV/check.out" 2>&1 || {
  if grep -q "Couldn't acquire exclusive lock" "$DEV/check.out"; then
    echo "CHECK NOT RUN: the game is open on the dev profile. Close it, or use scripts/test.sh (own profile)."
    exit 2
  fi
  fail "data stage"
}
grep -qE "Error|Failed to load mods" "$log" && fail "data stage"
[ -s "$DEV/script-output/data-raw-dump.json" ] || fail "no prototype dump written"
echo "data stage ok: $(grep -c 'Checksum of' "$log") mods loaded"
# The target derivation rule's guard, logged by data-final-fixes.
derive_line=$(grep -o 'es-derive check: .*' "$log" | tail -1 || true)
[ -n "$derive_line" ] || fail "no es-derive check line in the log"
case "$derive_line" in *": pass"*) echo "$derive_line" ;; *) echo "$derive_line"; fail "target derivation guard" ;; esac

# 2. control stage
rm -f "$DEV/saves/_check.zip"
"$FACTORIO" --config "$CONFIG" --create "$DEV/saves/_check.zip" > "$DEV/check.out" 2>&1 || fail "control stage (on_init)"
echo "control stage ok: fresh map created, on_init ran"
