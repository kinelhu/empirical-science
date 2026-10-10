#!/usr/bin/env bash
# Upgrade test: build a base with an OLD version of the mod, save, load it with the CURRENT version,
# run a game-minute, check. Usage: scripts/upgrade_test.sh <commit> [<commit> ...]
set -euo pipefail
source "$(dirname "$0")/env.sh"
ensure_charts
UP="$HOME/Library/Application Support/factorio-upgrade"
status=0
for commit in "$@"; do
  wt="$REPO/vendor/worktrees/$commit"
  [ -d "$wt" ] || git -C "$REPO" worktree add -q --detach "$wt" "$commit"
  rm -rf "$UP"; mkdir -p "$UP/config" "$UP/mods" "$UP/saves"
  printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$UP" > "$UP/config/config.ini"
  ln -sfn "$CHARTS" "$UP/mods/factorio-charts"
  ln -sfn "$wt/empirical-science" "$UP/mods/empirical-science"
  ln -sfn "$REPO/tests/es-upgrade-setup" "$UP/mods/es-upgrade-setup"
  version=$(grep -o '"version": "[^"]*"' "$wt/empirical-science/info.json" | cut -d'"' -f4)
  if ! "$FACTORIO" --config "$UP/config/config.ini" --create "$UP/saves/old.zip" > "$UP/create.out" 2>&1; then
    echo "[$version] SETUP FAILED"; grep -A6 Error "$UP/create.out" | head -12; status=1; continue
  fi
  # Now the current version, with the checker instead of the setup mod.
  rm "$UP/mods/es-upgrade-setup"
  ln -sfn "$REPO/empirical-science" "$UP/mods/empirical-science"
  ln -sfn "$REPO/tests/es-upgrade-check" "$UP/mods/es-upgrade-check"
  printf '{"mods": [{"name": "base", "enabled": true}, {"name": "empirical-science", "enabled": true}, {"name": "factorio-charts", "enabled": true}, {"name": "es-upgrade-check", "enabled": true}, {"name": "quality", "enabled": true}, {"name": "space-age", "enabled": true}, {"name": "elevated-rails", "enabled": true}]}' > "$UP/mods/mod-list.json"
  if ! "$FACTORIO" --config "$UP/config/config.ini" --benchmark "$UP/saves/old.zip" --benchmark-ticks 3700 > "$UP/load.out" 2>&1; then
    echo "[$version -> current] LOAD FAILED"; grep -hA8 "Error" "$UP/load.out" "$UP/factorio-current.log" | head -16; status=1; continue
  fi
  echo "[$version -> current]"; sed 's/^/  /' "$UP/script-output/es-upgrade-results.txt" 2>/dev/null || { echo "  no results"; status=1; }
  grep -q "DONE ALL PASSED" "$UP/script-output/es-upgrade-results.txt" 2>/dev/null || status=1
  # The hidden world must survive the upgrade unchanged (targets added since are filled, not redrawn).
  if [ -s "$UP/script-output/es-truth-before.txt" ]; then
    # Every line of the old world must survive unchanged; lines may be added (things that did not exist).
    lost=$(grep -Fxv -f "$UP/script-output/es-truth-after.txt" "$UP/script-output/es-truth-before.txt" || true)
    if [ -z "$lost" ]; then
      echo "  PASS hidden world kept by the upgrade ($(wc -l < "$UP/script-output/es-truth-before.txt" | tr -d ' ') lines kept, $(( $(wc -l < "$UP/script-output/es-truth-after.txt") - $(wc -l < "$UP/script-output/es-truth-before.txt") )) added)"
    else
      echo "  FAIL hidden world changed by the upgrade:"; echo "$lost" | head -6 | sed 's/^/    /'
      status=1
    fi
  else
    echo "  (no fingerprint from the old version)"
  fi
done
exit $status
