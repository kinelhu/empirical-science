#!/usr/bin/env bash
# Menu scenes built by hand (a person lays a scene out in the map editor; scripts do the rest).
#   scripts/scene_workshop.sh prepare <scene> [--from-script]
#       vanilla's menu save for <scene>, everything researched, the view's frame outlined in hazard concrete,
#       saved in the dev profile as es-scene-<scene>.zip. --from-script starts it from the mod's scripted additions.
#       Open it in the map editor, build (sources and sinks outside the frame: infinity chests and pipes), set
#       the doses, save it under the same name.
#   scripts/scene_workshop.sh extract <scene> [save]   (save: its name in the dev profile, es-scene-<scene> if left out)
#       what was added to that save becomes empirical-science/scenes/<scene>.lua (a blueprint, its doses, what
#       was removed), which the menu scene pastes into vanilla's save.
#   scripts/scene_workshop.sh bake <scene>
#       vanilla's menu save with the scene pasted as the menu does it, without Factorio's logo, after the menu's
#       warm-up: es-bake-<scene>.zip in the dev profile, and where the menu's camera stands, for screenshots.
set -euo pipefail
source "$(dirname "$0")/env.sh"
ACTION="${1:?prepare, extract or bake}"; SCENE="${2:?scene name, e.g. lab}"; FROM="${3:-}"   # (prepare: --from-script)
WS="$HOME/Library/Application Support/factorio-workshop"
MOD="$REPO/tests/es-scene-workshop"
mkdir -p "$WS/config" "$WS/mods" "$WS/saves" "$DEV/saves" "$REPO/empirical-science/scenes"
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$WS" > "$WS/config/config.ini"
ensure_charts
ln -sfn "$MOD" "$WS/mods/es-scene-workshop"
ln -sfn "$REPO/empirical-science" "$WS/mods/empirical-science"
ln -sfn "$CHARTS" "$WS/mods/factorio-charts"
rm -f "$WS/script-output/workshop-status.txt"
case "$ACTION" in
  prepare|bake)
    printf 'return {action = "%s", scene = "%s", from_script = %s}\n' "$ACTION" "$SCENE" \
      "$([ "$FROM" = "--from-script" ] && echo true || echo false)" > "$MOD/mode.lua"
    cp "$APP/data/base/menu-simulations/menu-simulation-$SCENE.zip" "$WS/saves/in.zip"
    OUT="es-scene-$SCENE"; DONE=prepared
    [ "$ACTION" = bake ] && { OUT="es-bake-$SCENE"; DONE=baked; }
    rm -f "$WS/saves/$OUT.zip"
    # A headless server (only a server can save from script), stopped once the save is written.
    "$FACTORIO" --config "$WS/config/config.ini" --start-server "$WS/saves/in.zip" --port 34299 \
      --server-settings "$MOD/server-settings.json" > "$WS/run.out" 2>&1 &
    PID=$!
    for _ in $(seq 1 90); do
      sleep 1
      grep -q "Saving finished" "$WS/run.out" 2>/dev/null && break
      grep -q "^not" "$WS/script-output/workshop-status.txt" 2>/dev/null && break
      kill -0 $PID 2>/dev/null || break
    done
    kill $PID 2>/dev/null || true; wait $PID 2>/dev/null || true
    grep -q "^$DONE" "$WS/script-output/workshop-status.txt" 2>/dev/null \
      || { { grep -iE "error" -A5 "$WS/run.out" || true; } | head -12; echo "not $DONE"; exit 1; }
    [ -f "$WS/saves/$OUT.zip" ] || { ls "$WS/saves"; tail -5 "$WS/run.out"; echo "the save was not written"; exit 1; }
    cp "$WS/saves/$OUT.zip" "$DEV/saves/$OUT.zip"
    if [ "$ACTION" = bake ]; then
      cp "$WS/script-output/camera_$SCENE.lua" "$DEV/saves/$OUT.camera.lua"
      echo "saved: $DEV/saves/$OUT.zip (camera: $(cat "$WS/script-output/camera_$SCENE.lua" | tr -d '\n'))"
    else
      cp "$WS/script-output/vanilla_$SCENE.lua" "$MOD/vanilla_$SCENE.lua"
      echo "saved: $DEV/saves/$OUT.zip (open it in the map editor)"
    fi
    ;;
  extract)
    [ -f "$MOD/vanilla_$SCENE.lua" ] || { echo "prepare $SCENE first"; exit 1; }
    printf 'return {action = "extract", scene = "%s"}\n' "$SCENE" > "$MOD/mode.lua"
    SAVE="${3:-es-scene-$SCENE}"
    [ -f "$DEV/saves/$SAVE.zip" ] || { echo "no save $SAVE in the dev profile"; exit 1; }
    cp "$DEV/saves/$SAVE.zip" "$WS/saves/in.zip"
    "$FACTORIO" --config "$WS/config/config.ini" --benchmark "$WS/saves/in.zip" --benchmark-ticks 1 > "$WS/run.out" 2>&1 || true
    grep -q extracted "$WS/script-output/workshop-status.txt" 2>/dev/null \
      || { { grep -iE "error" -A5 "$WS/run.out" || true; } | head -12; echo "not extracted"; exit 1; }
    cp "$WS/script-output/scene_$SCENE.lua" "$REPO/empirical-science/scenes/$SCENE.lua"
    cat "$WS/script-output/workshop-status.txt"
    echo "written: empirical-science/scenes/$SCENE.lua"
    ;;
  *) echo "prepare, extract or bake"; exit 1 ;;
esac
