# Shared paths. Sourced by the other scripts.
REPO="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
APP="$HOME/Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents"
FACTORIO="$APP/MacOS/factorio"
DEV="$HOME/Library/Application Support/factorio-dev"   # isolated write-data: mods, saves, logs
REAL="$HOME/Library/Application Support/factorio"      # the real profile; never written to
CONFIG="$DEV/config/config.ini"
MODS="empirical-science"
# factorio-charts, pinned to 1.1.0 (the last release for Factorio 2.0). Players get it from the mod
# portal as a dependency; dev and test profiles link this checkout instead.
CHARTS_REPO="https://github.com/nickelbob/factorio-charts.git"
CHARTS_COMMIT="e97b8dc"
CHARTS="$REPO/vendor/factorio-charts-src"
ensure_charts() {
  if [ ! -d "$CHARTS/.git" ]; then git clone -q "$CHARTS_REPO" "$CHARTS"; fi
  git -C "$CHARTS" checkout -q "$CHARTS_COMMIT"
}
