#!/usr/bin/env bash
# Script cost of the mod in a large base (tests/es-perf): Factorio's own per-tick timings.
# Usage: scripts/perf_test.sh [mega]
set -euo pipefail
source "$(dirname "$0")/env.sh"
ensure_charts
PF="$HOME/Library/Application Support/factorio-perf"
mkdir -p "$PF/config" "$PF/mods" "$PF/saves"
printf '[path]\nread-data=__PATH__system-read-data__\nwrite-data=%s\n' "$PF" > "$PF/config/config.ini"
ln -sfn "$REPO/empirical-science" "$PF/mods/empirical-science"
ln -sfn "$REPO/tests/es-perf" "$PF/mods/es-perf"
# `perf_test.sh mega`: 800 more benches (1,000 in all), through an empty marker mod.
if [ "${1:-}" = "mega" ]; then ln -sfn "$REPO/tests/es-perf-mega" "$PF/mods/es-perf-mega"; else rm -f "$PF/mods/es-perf-mega"; fi
ln -sfn "$CHARTS" "$PF/mods/factorio-charts"
rm -f "$PF/saves/perf.zip"
"$FACTORIO" --config "$PF/config/config.ini" --create "$PF/saves/perf.zip" > "$PF/create.out" 2>&1 \
  || { grep -A8 Error "$PF/create.out" | head; exit 1; }
"$FACTORIO" --config "$PF/config/config.ini" --benchmark "$PF/saves/perf.zip" --benchmark-ticks 7200 \
  --benchmark-verbose all > "$PF/bench.out" 2>&1 || { grep -A8 Error "$PF/bench.out" | head; exit 1; }
uvx --quiet python - "$PF/bench.out" <<'PY'
import sys, re
lines = open(sys.argv[1]).read().splitlines()
hi = next(i for i, l in enumerate(lines) if l.startswith("tick,"))
head = lines[hi].split(",")
rows = [l.split(",") for l in lines[hi + 1:] if re.match(r"^t?\d+,", l)]
col = lambda name: [float(r[head.index(name)]) / 1e6 for r in rows if len(r) == len(head)]
wall, script = col("wholeUpdate"), col("scriptUpdate")
ents = col("entityUpdate")
rows_ok = len(script)
script.sort(); wall_sorted = sorted(wall)
mean = lambda v: sum(v) / len(v)
print(f"ticks {rows_ok}: whole update {mean(wall):.2f} ms/tick (p99 {wall_sorted[int(0.99*rows_ok)]:.2f}), "
      f"entities {mean(ents):.2f}, mod scripts {mean(script):.3f} ms/tick (p99 {script[int(0.99*rows_ok)]:.3f}, "
      f"max {script[-1]:.3f}); budget 16.67 ms")
PY
# What the base did during the run (an idle base would prove nothing).
cat "$PF/script-output/es-perf-work.txt" 2>/dev/null | sed 's/^/  /'
