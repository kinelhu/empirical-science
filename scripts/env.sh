# Shared paths. Sourced by the other scripts.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents"
FACTORIO="$APP/MacOS/factorio"
DEV="$HOME/Library/Application Support/factorio-dev"   # isolated write-data: mods, saves, logs
REAL="$HOME/Library/Application Support/factorio"      # the real profile; never written to
CONFIG="$DEV/config/config.ini"
MODS="empirical-science"
# factorio-charts, pinned to 1.3.0 (players get the newest release, so tests run on it). Players get it from the mod portal
# as a dependency; dev and test profiles link an unpacked copy. It is published on the mod portal only
# (its GitHub repository stops at 1.1.0), and the portal needs a login to download: put the zip at
# $CHARTS_ZIP by hand; ensure_charts checks its SHA-1 (the portal's) and unpacks it.
CHARTS_VERSION="1.3.0"
CHARTS_SHA1="9ad4b483ec989bc9b86b84be0043b4f3e7a3ea1a"
CHARTS_ZIP="$REPO/vendor/factorio-charts_$CHARTS_VERSION.zip"
CHARTS="$REPO/vendor/factorio-charts-$CHARTS_VERSION"
ensure_charts() {
  local stamp="$CHARTS/.portal-sha1"
  if [ -f "$stamp" ] && [ "$(cat "$stamp")" = "$CHARTS_SHA1" ]; then return 0; fi
  if [ -n "${ES_CHARTS_STANDIN:-}" ] && [ -f "$CHARTS/info.json" ]; then
    echo "WARNING: factorio-charts is a stand-in, not the portal's $CHARTS_VERSION ($CHARTS)" >&2; return 0
  fi
  if [ ! -f "$CHARTS_ZIP" ]; then
    echo "factorio-charts $CHARTS_VERSION missing: download it from https://mods.factorio.com/mod/factorio-charts" \
      "(log in) and save it as $CHARTS_ZIP" >&2
    return 1
  fi
  [ "$(shasum -a 1 "$CHARTS_ZIP" | cut -d' ' -f1)" = "$CHARTS_SHA1" ] \
    || { echo "$CHARTS_ZIP is not the portal's factorio-charts $CHARTS_VERSION (SHA-1 differs)" >&2; return 1; }
  local tmp; tmp="$(mktemp -d)"
  unzip -q "$CHARTS_ZIP" -d "$tmp"
  rm -rf "$CHARTS"; mv "$tmp"/*/ "$CHARTS"; rm -rf "$tmp"
  echo "$CHARTS_SHA1" > "$stamp"
}
