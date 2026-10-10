"""Dose range and response shapes (rules set before the numbers).

Can a careful study (24 samples per additive) tell an activator's shape from what it measures? Three
designs: (A) today, doses 1-9 screened at 2, 5, 8 x 8 samples; (B) doses 1-9, every dose 1-8 x 3; (C) doses
1-18, the optimum doubled and every other feature kept at its width in doses, 8 doses spread evenly x 3.
Identified: the best least-squares fit among the six shapes (each shape's parameters on a grid, amplitude
and baseline fitted) is the true shape. Curves come from docs/plot_curves.py (drift-checked against the
mod's Lua by docs/check_curves.py).

Run: uv run --with numpy --with matplotlib docs/shapes.py
"""
import json
import math
from pathlib import Path

import numpy as np

import plot_curves as pc

OUT_DIR = Path.home() / "Library/Application Support/factorio-sampler/script-output"
SEED = 20261003
WORLDS = 150

params = json.loads((OUT_DIR / "es-worlds.json").read_text())
sd = params["params"]["noise_sd"]
worlds = params["worlds"][:WORLDS]


def stretched(shape, r, d, s):
    """The shape on a range s times longer: the optimum (and what hangs on it) scaled by s, every other
    feature kept at its width in doses. s = 1 is the mod's curve."""
    o = r["opt"] * s
    if shape == "hump":  # width ~ opt / sqrt(k): keep the width in doses, so k grows with s^2
        x = d / o
        k = r["k"] * s * s
        return x ** k * math.exp(k * (1 - x))
    if shape == "plateau":  # the rise's scale is the optimum itself
        return pc.rise(d, o)
    if shape == "threshold":
        at = pc.clamp(o - 1, 2, 9 * s - 2)
        step = lambda x: 1 / (1 + math.exp(-4 * (x - at + 0.5)))
        return (step(d) - step(0)) / (1 - step(0))
    if shape == "two_peak":
        trap = o - 3.5 * s if o >= 5 * s else min(o + 3.5 * s, 9 * s)
        return pc.bump0(d, o, 0.9) + 0.45 * pc.bump0(d, trap, 0.7)
    if shape == "biphasic":
        b = pc.clamp(0.3 * o, 1, 3 * s)
        dip = -0.4 * math.sin(math.pi * d / (2 * b)) if d < 2 * b else 0
        return dip + pc.rise(d - b, max(o - b, 1))
    if shape == "spike":
        at = pc.clamp(math.floor(o + 0.5), 2, 9 * s - 1)
        return pc.bump0(d, at, 0.45)
    raise ValueError(shape)


SHAPES = list(pc.SHAPES)
OPTS = np.arange(1.5, 8.01, 0.5)
KS = [2, 3.5, 5, 6]


def templates(doses, s):
    """Every shape's candidate curves at these doses: {shape: [vector, ...]}."""
    out = {}
    for shape in SHAPES:
        vs = []
        for o in OPTS:
            for k in (KS if shape == "hump" else [4]):
                vs.append(np.array([stretched(shape, {"opt": o, "k": k}, d, s) for d in doses]))
        out[shape] = vs
    return out


def classify(y, w, tpl):
    """The shape whose best template (amplitude >= 0 and a baseline fitted, weights w) fits y best."""
    best, best_shape = np.inf, None
    for shape, vs in tpl.items():
        for v in vs:
            X = np.column_stack([np.ones_like(v), v])
            W = np.sqrt(w)
            b, *_ = np.linalg.lstsq(X * W[:, None], y * W, rcond=None)
            if b[1] < 0:
                continue
            sse = float(np.sum(w * (y - X @ b) ** 2))
            if sse < best:
                best, best_shape = sse, shape
    return best_shape


def main():
    DESIGNS = {
        "A": dict(s=1, doses=[2, 5, 8], n=8),
        "B": dict(s=1, doses=list(range(1, 9)), n=3),
        "C": dict(s=2, doses=[2, 4, 7, 9, 11, 13, 16, 18], n=3),
    }

    rng = np.random.default_rng(SEED)
    cells = []
    for w in worlds:
        for key, t in w.items():
            if not isinstance(t, dict):
                continue
            for a, c in t.items():
                if isinstance(c, dict) and c.get("tier") == 1 and c.get("kind") == "activator" and not c.get("fluid"):
                    cells.append(c)
    print(f"{len(cells)} tier 1 activators from {len(worlds)} worlds; noise SD {sd:.2f}")

    result = {}
    for name, dz in DESIGNS.items():
        tpl = templates(dz["doses"], dz["s"])
        hits, by_shape = 0, {}
        for c in cells:
            r = {"opt": c["opt"], "k": 4}
            truth = np.array([c["peak"] * stretched(c["shape"], r, d, dz["s"]) for d in dz["doses"]])
            se = sd / math.sqrt(dz["n"])
            control = rng.normal(0, sd / math.sqrt(dz["n"]))
            y = truth + rng.normal(0, se, len(truth)) - control
            got = classify(y, np.ones(len(y)), tpl)
            ok = got == c["shape"]
            hits += ok
            h = by_shape.setdefault(c["shape"], [0, 0])
            h[0] += ok
            h[1] += 1
        result[name] = hits / len(cells)
        print(f"design {name}: identified {result[name]:.0%}  " +
              ", ".join(f"{k} {v[0] / v[1]:.0%}" for k, v in sorted(by_shape.items())))

    print(f"\nchance {1 / len(SHAPES):.0%}")
    print(f"C - B = {100 * (result['C'] - result['B']):+.0f} points (rule: >= +15 and C >= 50% for a longer range)")
    print(f"B - A = {100 * (result['B'] - result['A']):+.0f} points (rule: >= +15 means the protocol is the constraint)")


if __name__ == "__main__":
    main()
