"""The mod page's diagrams (docs/modpage), drawn from the game's own icons and font in its GUI's colours.
Run: uv run --with pillow --with numpy docs/modpage/build_images.py"""
from pathlib import Path
import numpy as np
from PIL import Image, ImageDraw, ImageFont

APP = Path.home() / "Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/data"
ES = Path(__file__).resolve().parents[2] / "empirical-science" / "graphics"
OUT = Path(__file__).resolve().parent / "images"
K = 2  # drawn at twice the size, for sharp text on high-density screens

# The game's GUI: a dark frame, a darker inset, warm caption text, the orange of its highlights.
FRAME, INSET, EDGE = (49, 48, 49), (36, 35, 36), (18, 18, 18)
CAPTION, TEXT, DIM, ORANGE = (255, 230, 192), (226, 226, 226), (150, 150, 150), (227, 152, 39)
FONT = str(APP / "core/fonts/TitilliumWeb-SemiBold.ttf")
FONT_R = str(APP / "core/fonts/TitilliumWeb-Regular.ttf")


def icon(path, tint=None, size=64):
    """An icon (the first mip of a strip), tinted like the game tints an icon layer."""
    im = Image.open(path).convert("RGBA")
    im = im.crop((0, 0, size, size))
    if tint:
        a = np.asarray(im).astype(float)
        a[..., :3] *= np.array(tint)
        im = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA")
    return im


V = lambda rel, tint=None: icon(APP / "base/graphics/icons" / rel, tint)
SA = lambda rel, tint=None: icon(APP / "space-age/graphics/icons" / rel, tint)
M = lambda rel: icon(ES / rel)


def canvas(w, h):
    im = Image.new("RGBA", (w * K, h * K), FRAME + (255,))
    d = ImageDraw.Draw(im)
    d.rectangle((0, 0, w * K - 1, h * K - 1), outline=EDGE, width=2 * K)
    return im, d


def slot(im, d, x, y, ic, size=64):
    """An icon in an inset slot, as the game shows items."""
    pad = 6
    d.rounded_rectangle(((x - pad) * K, (y - pad) * K, (x + size + pad) * K, (y + size + pad) * K), radius=4 * K,
                        fill=INSET, outline=EDGE, width=K)
    im.alpha_composite(ic.resize((size * K, size * K), Image.LANCZOS), (x * K, y * K))


def text(d, x, y, s, size=17, fill=TEXT, font=FONT, anchor="mm"):
    d.text((x * K, y * K), s, font=ImageFont.truetype(font, size * K), fill=fill, anchor=anchor)


def arrow(d, x0, y, x1, fill=ORANGE):
    d.line((x0 * K, y * K, (x1 - 8) * K, y * K), fill=fill, width=3 * K)
    d.polygon([((x1) * K, y * K), ((x1 - 12) * K, (y - 7) * K), ((x1 - 12) * K, (y + 7) * K)], fill=fill)


def save(im, name):
    im.save(OUT / name, optimize=True)
    print(name, im.size)


def loop():
    """The loop: trial, sample, analysis, dosed production, findings; analysis chooses the next trial."""
    steps = [([M("test-bench-icon.png")], "Trial", "a recipe with a dose"),
             ([M("sample-icon.png")], "Sample", "what the trial made"),
             ([M("station-icon.png")], "Analysis", "estimates and ranges"),
             ([M("hopper-icon.png"), V("assembling-machine-2.png")], "Dosed production", "the dose you trust"),
             ([icon(APP / "core/graphics/icons/mip/check-mark-green.png", size=32)], "Findings", "proven and produced")]
    W, H, gap = 1100, 300, 210
    im, d = canvas(W, H)
    text(d, W / 2, 34, "Research by experiment", size=24, fill=CAPTION)
    x0 = 80
    for i, (ics, title, sub) in enumerate(steps):
        cx = x0 + i * gap
        if len(ics) == 1:
            slot(im, d, cx - 32, 90, ics[0])
        else:
            slot(im, d, cx - 70, 90, ics[0]); slot(im, d, cx + 6, 90, ics[1])
        text(d, cx, 190, title, size=19, fill=CAPTION)
        text(d, cx, 216, sub, size=15, fill=DIM, font=FONT_R)
        if i < len(steps) - 1:
            arrow(d, cx + (78 if len(ics) > 1 else 46), 122, cx + gap - (84 if i + 1 == 3 else 46))
    # The return: what the analysis shows chooses the next trial.
    ax, bx, y = x0 + 2 * gap, x0, 258
    d.line((ax * K, 236 * K, ax * K, y * K), fill=ORANGE, width=3 * K)
    d.line((ax * K, y * K, bx * K, y * K), fill=ORANGE, width=3 * K)
    d.line((bx * K, y * K, bx * K, 236 * K), fill=ORANGE, width=3 * K)
    d.polygon([(bx * K, 228 * K), ((bx - 7) * K, 240 * K), ((bx + 7) * K, 240 * K)], fill=ORANGE)
    text(d, (ax + bx) / 2, y + 16, "what you learn chooses the next trial", size=15, fill=DIM, font=FONT_R)
    save(im, "loop.png")


def dosing():
    """A dosed machine: a hopper feeds it, it makes more of its product, and a residue leaves."""
    W, H = 900, 250
    im, d = canvas(W, H)
    text(d, W / 2, 34, "Dose a machine", size=24, fill=CAPTION)
    slot(im, d, 40, 90, M("hopper-icon.png")); slot(im, d, 130, 90, M("fluid-hopper-icon.png"))
    slot(im, d, 220, 90, V("copper-cable.png"), 40)
    text(d, 140, 190, "Hoppers", size=19, fill=CAPTION); text(d, 140, 214, "items or fluids, beside the machine", size=15, fill=DIM, font=FONT_R)
    arrow(d, 274, 122, 370)
    slot(im, d, 384, 90, V("assembling-machine-2.png"))
    text(d, 416, 190, "Dosed machine", size=19, fill=CAPTION); text(d, 416, 214, "any recipe the mod studies", size=15, fill=DIM, font=FONT_R)
    arrow(d, 462, 106, 600); arrow(d, 462, 138, 600)
    slot(im, d, 614, 76, V("iron-gear-wheel.png"), 40); slot(im, d, 664, 76, V("iron-gear-wheel.png"), 40)
    text(d, 760, 96, "more products", size=16, fill=TEXT, anchor="lm")
    slot(im, d, 614, 136, V("copper-ore.png", (0.45, 0.4, 0.35)), 40)  # metal dust, as the game draws it
    text(d, 710, 156, "a residue, out with them", size=16, fill=TEXT, anchor="lm")
    save(im, "dosing.png")


if __name__ == "__main__":
    OUT.mkdir(parents=True, exist_ok=True)
    loop(); dosing()
