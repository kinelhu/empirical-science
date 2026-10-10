#!/usr/bin/env bash
# Builds the mod portal's zip from a commit: empirical-science_<version>.zip holding the folder
# empirical-science_<version>/, as the portal and the game expect. Committed files only.
# Fails if the changelog has no entry for the version, or if the zip does not load in a clean profile.
#   scripts/build_release.sh [commit]     (default HEAD; the zip goes to dist/)
set -euo pipefail
source "$(dirname "$0")/env.sh"
REV="${1:-HEAD}"
version="$(git -C "$REPO" show "$REV:empirical-science/info.json" | python3 -c 'import json,sys; print(json.load(sys.stdin)["version"])')"
# (Read whole, then searched: with pipefail, grep -q closing the pipe early failed git show on a good changelog.)
changelog="$(git -C "$REPO" show "$REV:empirical-science/changelog.txt")"
grep -q "^Version: $version$" <<< "$changelog" || { echo "RELEASE REFUSED: changelog.txt has no entry for $version"; exit 1; }
name="empirical-science_$version"
mkdir -p "$REPO/dist"
zip="$REPO/dist/$name.zip"
rm -f "$zip"
git -C "$REPO" archive --format=zip --prefix="$name/" -o "$zip" "$REV:empirical-science"

# Load it: a profile with only this zip and Factorio Charts, no Space Age or Quality, then with both.
REL="$HOME/Library/Application Support/factorio-release"
for expansions in false true; do
  rm -rf "$REL"; mkdir -p "$REL/config" "$REL/mods"
  printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$REL" > "$REL/config/config.ini"
  cp "$zip" "$REL/mods/"
  ensure_charts
  ln -sfn "$CHARTS" "$REL/mods/factorio-charts"
  printf '{"mods": [{"name": "base", "enabled": true}, {"name": "empirical-science", "enabled": true},
    {"name": "factorio-charts", "enabled": true}, {"name": "space-age", "enabled": %s},
    {"name": "quality", "enabled": %s}, {"name": "elevated-rails", "enabled": %s}]}\n' \
    "$expansions" "$expansions" "$expansions" > "$REL/mods/mod-list.json"
  if ! "$FACTORIO" --config "$REL/config/config.ini" --create "$REL/check.zip" > "$REL/run.out" 2>&1; then
    echo "RELEASE FAILED: the zip does not load (Space Age and Quality: $expansions)"
    grep -hE -A6 "Error" "$REL/factorio-current.log" | head -20
    exit 1
  fi
  grep -q "Loading mod empirical-science $version " "$REL/factorio-current.log" \
    || { echo "RELEASE FAILED: the game did not load the mod (Space Age and Quality: $expansions)"; exit 1; }
done
rm -rf "$REL"
echo "RELEASE OK: $zip ($(du -h "$zip" | cut -f1)), loads with and without Space Age and Quality"
