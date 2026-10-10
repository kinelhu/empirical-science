"""Check docs/plot_curves.py against the game's own curve formulas.

Run after scripts/test.sh (which writes CURVE lines with each curve's parameters and gains):
  uv run --with matplotlib docs/check_curves.py
Fails if any Python gain differs from the Lua gain by more than 1e-6.
"""
import json
import sys
from pathlib import Path

src = (Path(__file__).with_name("plot_curves.py")).read_text().split("PANELS = [")[0]  # formulas only
ns = {}
exec(src, ns)
results = Path.home() / "Library/Application Support/factorio-test/script-output/es-test-results.txt"
curves = [json.loads(line[6:]) for line in results.read_text().splitlines() if line.startswith("CURVE ")]
if not curves:
    sys.exit("no CURVE lines: run scripts/test.sh first")
# Lua takes doses in the additive's own units and rescales them to the item scale (0 to 9).
worst = max(abs(ns["gain"](c["r"], d * 9 / c.get("max_dose", 9), c.get("k", 1.0)) - g)
            for c in curves for d, g in enumerate(c["gains"]))
shapes = sorted({c["r"]["shape"] for c in curves if c["r"]["kind"] == "activator"})
print(f"{len(curves)} curves, activator shapes {shapes}: max |python - lua| = {worst:.1e}")
sys.exit(0 if worst < 1e-6 else "plot_curves.py has drifted from truth.lua")
