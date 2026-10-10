"""Dose range and response shapes, second model (rules R1-R3
set before the numbers). Net ore, not identification: a dose is spent per batch, one unit costing
1/shared.batch_ore of a batch's ore (as today), so net saving = 1 - (1 + d/B) / (1 + gain). Axes 1-9 and
1-20 in the same unit; each activator's optimum spread over the axis (opt x L/9), other features kept at
their width in doses. Shapes: today's six (docs/shapes.py's `stretched`), a cliff, a growing oscillation.
Every shape is evaluated on the same sampled activators (their peak and optimum), so shapes compare on
equal footing.

Run: uv run --with numpy --with matplotlib docs/shapes_net.py
"""
import json
import math
from pathlib import Path

import numpy as np

from shapes import stretched, OUT_DIR  # noqa: E402  (the same curves as the first model)
import plot_curves as pc

SEED = 20261004
N_CELLS = 2000
W = json.loads((OUT_DIR / "es-worlds.json").read_text())
sd = W["params"]["noise_sd"]
B = W["params"]["batch_ore"]

cells = [c for w in W["worlds"][:200] for t in w.values() if isinstance(t, dict)
         for c in t.values() if isinstance(c, dict) and c.get("tier") == 1 and c.get("kind") == "activator"
         and not c.get("fluid")]
rng = np.random.default_rng(SEED)
cells = [cells[i] for i in rng.choice(len(cells), N_CELLS, replace=False)]


def cliff(o, d, s):
    """Saturates toward the optimum, then collapses to minus the peak past a cliff 60% beyond it."""
    at = 1.6 * o
    fall = 1 / (1 + math.exp(-4 * (d - at)))
    return pc.rise(d, o) - 2 * fall


def oscillation(o, d, L):
    """Help and harm alternating with a period of 4 doses, the swing growing with the dose to 1 at the
    axis end; the optimum only sets the phase."""
    return (d / L) * math.sin(2 * math.pi * (d - o) / 4 + math.pi / 2)


SHAPES = ["hump", "plateau", "threshold", "two_peak", "biphasic", "spike", "cliff", "oscillation"]
SATURATING = ["plateau", "threshold"]


import sys
FINE = "--fine" in sys.argv  # the third model: 1-20 in finer units (9/20 of today's ore each)


def curve(shape, c, d, L):
    s = L / 9
    o = c["opt"] * s
    if shape == "cliff":
        return cliff(o, d, s)
    if shape == "oscillation":
        return oscillation(o, d, L)
    if FINE:  # stretched whole: the same curve in ore terms, finer steps
        return stretched(shape, {"opt": c["opt"], "k": 4}, d * 9 / L, 1)
    return stretched(shape, {"opt": c["opt"], "k": 4}, d, s)


def net(g, d, L=9):
    unit = (9 / L) if FINE else 1
    return 1 - (1 + d * unit / B) / (1 + g)


out = {}
for L in (9, 20):
    doses = np.arange(1, L + 1)
    study = np.unique(np.round(np.linspace(1, L, 8)).astype(int))  # 8 doses, 3 samples each
    for shape in SHAPES:
        look, capture, helping = [], [], []
        for c in cells:
            g = np.array([c["peak"] * curve(shape, c, d, L) for d in doses])
            n = np.array([net(gi, d, L) for gi, d in zip(g, doses)])
            best = n.max()
            look.append(best - n[-1])
            se = sd / math.sqrt(3)
            control = rng.normal(0, se)
            gs = g[study - 1] + rng.normal(0, se, len(study)) - control
            est = [net(gi, d, L) for gi, d in zip(gs, study)]
            pick = study[int(np.argmax(est))]
            if best > 0:
                capture.append(n[pick - 1] / best)
            helping.append(g[pick - 1] > 0)
        out[(L, shape)] = dict(look=float(np.median(look)), capture=float(np.median(capture)) if capture else float("nan"),
                               helping=float(np.mean(helping)), pays=len(capture) / len(cells))

print(("FINER UNITS (1-20 at 9/20 of the ore each). " if FINE else "") + f"{N_CELLS} activators (peak and optimum from the sampled worlds); noise SD {sd:.2f}; one unit = 1/{B} of a batch"
      + (" on 1-9, 9/20 of that on 1-20" if FINE else ""))
print(f"{'shape':12} {'axis':>4} {'value of looking':>17} {'careful capture':>16} {'lands helping':>14} {'any dose pays':>14}")
for shape in SHAPES:
    for L in (9, 20):
        r = out[(L, shape)]
        print(f"{shape:12} {L:>4} {100 * r['look']:>16.1f}% {100 * r['capture']:>15.0f}% {100 * r['helping']:>13.0f}% "
              f"{100 * r['pays']:>13.0f}%")

r1 = [out[(20, s)]["look"] / max(out[(9, s)]["look"], 1e-9) for s in SATURATING]
r2 = float(np.nanmedian([out[(20, s)]["capture"] for s in SHAPES]))
r3 = out[(20, "oscillation")]["helping"]
print(f"\nR1 value of looking, 1-20 over 1-9, saturating: " + ", ".join(f"{s} x{v:.1f}" for s, v in zip(SATURATING, r1))
      + f"  (rule: x2 or more) {'holds' if min(r1) >= 2 else 'fails'}")
print(f"R2 careful capture on 1-20, median over shapes: {r2:.0%}  (rule: 60% or more) {'holds' if r2 >= 0.6 else 'fails'}")
print(f"R3 oscillation lands in a helping window on 1-20: {r3:.0%}  (rule: 70% or more) {'holds' if r3 >= 0.7 else 'fails'}")
