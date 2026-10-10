"""Plot every hidden dose-response curve the mod can generate, with example parameters.

Run: uv run --with matplotlib docs/plot_curves.py   -> docs/response-curves.png
The formulas mirror empirical-science/scripts/truth.lua (curve table and truth.gain). If you change
one, change the other. Parameters are fixed examples, so the plot is identical on every run.
"""
import math
from pathlib import Path

import matplotlib.pyplot as plt

# Okabe-Ito, named for what the colours encode.
CURVE_KIND = {"activator": "#0072B2", "inhibitor": "#D55E00", "inert": "#999999"}


def clamp(x, lo, hi):
    return max(lo, min(hi, x))


def bump(x, centre, width):
    return math.exp(-((x - centre) ** 2) / (2 * width ** 2))


def bump0(x, centre, width):
    b0 = bump(0, centre, width)
    return (bump(x, centre, width) - b0) / (1 - b0)


def rise(x, scale):
    return 1 - math.exp(-3 * max(x, 0) / scale)


def hump(r, d):
    x = d / r["opt"]
    return x ** r["k"] * math.exp(r["k"] * (1 - x))


def plateau(r, d):
    return rise(d, r["opt"])


def threshold(r, d):
    at = clamp(r["opt"] - 1, 2, 7)
    step = lambda x: 1 / (1 + math.exp(-4 * (x - at + 0.5)))
    return (step(d) - step(0)) / (1 - step(0))


def two_peak(r, d):
    o = r["opt"]
    trap = o - 3.5 if o >= 5 else min(o + 3.5, 9)
    return bump0(d, o, 0.9) + 0.45 * bump0(d, trap, 0.7)


def biphasic(r, d):
    b = clamp(0.3 * r["opt"], 1, 3)
    dip = -0.4 * math.sin(math.pi * d / (2 * b)) if d < 2 * b else 0
    return dip + rise(d - b, max(r["opt"] - b, 1))


def spike(r, d):
    at = clamp(math.floor(r["opt"] + 0.5), 2, 8)
    return bump0(d, at, 0.45)


def cliff(r, d):
    o = min(r["opt"], 6)
    at = min(1.6 * o, 8.5)
    return rise(d, o) - 2 / (1 + math.exp(-4 * (d - at)))


SHAPES = {"hump": hump, "plateau": plateau, "threshold": threshold, "two_peak": two_peak,
          "biphasic": biphasic, "spike": spike, "cliff": cliff}


def gain(r, d, k=1.0):
    """k: the target's responsiveness within the additive's cap (truth.scale in Lua)."""
    if d == 0:
        return 0.0
    if r["kind"] == "inhibitor":
        return -k * r["peak"] * (1 - math.exp(-d / 2.5))
    shape = r["shape"] if r["kind"] == "activator" else "hump"
    return k * (r["peak"] * SHAPES[shape](r, d) - r["tox"] * abs(r["peak"]) * d)


def example(kind, shape, peak, opt, k=4.0, tox=0.015):
    return {"kind": kind, "shape": shape, "peak": peak, "opt": opt, "k": k, "tox": tox}


PANELS = [
    ("Hump (weight 3)", example("activator", "hump", 0.30, 4.5)),
    ("Plateau (weight 2)", example("activator", "plateau", 0.30, 4.0)),
    ("Threshold (weight 1.5)", example("activator", "threshold", 0.30, 5.5)),
    ("Two peaks, first is a trap (weight 1)", example("activator", "two_peak", 0.30, 7.0)),
    ("Biphasic: hurts low, helps high (weight 1)", example("activator", "biphasic", 0.30, 6.0)),
    ("Spike: one dose only (weight 0.5)", example("activator", "spike", 0.30, 5.0)),
    ("Inhibitor", example("inhibitor", "hump", 0.30, 4.0)),
    ("Inert (tiny effect, small toxicity)", example("inert", "hump", 0.02, 3.0, tox=0.028)),
]

fine = [i / 20 for i in range(0, 181)]
doses = list(range(10))
fig, axes = plt.subplots(2, 4, figsize=(17, 7.5), sharey=True, constrained_layout=True)
for ax, (name, r) in zip(axes.flat, PANELS):
    colour = CURVE_KIND[r["kind"]]
    ax.axhline(0, color="black", linewidth=0.8)
    ax.plot(fine, [100 * gain(r, d) for d in fine], color=colour, linewidth=1.2, alpha=0.5)
    ax.plot(doses, [100 * gain(r, d) for d in doses], "o", color=colour, markersize=6)
    ax.set_title(name, fontsize=10)
    ax.set_xticks(doses)
    ax.grid(alpha=0.3)
for ax in axes[:, 0]:
    ax.set_ylabel("true yield gain (%)")
for ax in axes[1, :]:
    ax.set_xlabel("dose (additive units per trial, 0 = control)")
fig.suptitle("Hidden dose-response shapes as implemented (example parameters: peak +30%, varying optimum). "
             "Dots: doses a player can run. Players see only noisy estimates (±20% per trial).", fontsize=11)
out = Path(__file__).with_name("response-curves.png")
fig.savefig(out, dpi=110)
print(out)
