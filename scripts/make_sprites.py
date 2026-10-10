"""Recolour vanilla sprites into the mod's own graphics (empirical-science/graphics/).

Run: uv run --with pillow --with numpy --with scipy scripts/make_sprites.py [--sheet out.png]

Factorio's `tint` multiplies every pixel, darkening steel and shadows along with the paint, which
looks flat. Here only the painted parts are recoloured: pixels in a hue band (the paint) get a new
hue, with a soft edge at the band's borders; steel, brass, rust and shadows are left alone.
Only the first frame of each building is kept (the mod's buildings are static), except the test
bench, which is a real assembling machine and keeps its whole animation sheet.
"""
import sys
from pathlib import Path

import numpy as np
from PIL import Image

BASE = Path.home() / "Library/Application Support/Steam/steamapps/common/Factorio/factorio.app/Contents/data/base/graphics"
OUT = Path(__file__).resolve().parent.parent / "empirical-science" / "graphics"


def rgb_to_hsv(rgb):
    r, g, b = rgb[..., 0], rgb[..., 1], rgb[..., 2]
    mx, mn = rgb.max(-1), rgb.min(-1)
    d = mx - mn
    h = np.zeros_like(mx)
    nz = d > 1e-9
    rm, gm, bm = nz & (mx == r), nz & (mx == g) & (mx != r), nz & (mx == b) & (mx != r) & (mx != g)
    h[rm] = ((g - b)[rm] / d[rm]) % 6
    h[gm] = (b - r)[gm] / d[gm] + 2
    h[bm] = (r - g)[bm] / d[bm] + 4
    s = np.where(mx > 1e-9, d / np.where(mx > 1e-9, mx, 1), 0)
    return np.stack([h * 60, s, mx], -1)


def hsv_to_rgb(hsv):
    h, s, v = hsv[..., 0] / 60, hsv[..., 1], hsv[..., 2]
    i = np.floor(h) % 6
    f = h - np.floor(h)
    p, q, t = v * (1 - s), v * (1 - s * f), v * (1 - s * (1 - f))
    out = np.zeros(hsv.shape)
    for k, (a, b, c) in enumerate([(v, t, p), (q, v, p), (p, v, t), (p, q, v), (t, p, v), (v, p, q)]):
        m = i == k
        out[..., 0][m], out[..., 1][m], out[..., 2][m] = a[m], b[m], c[m]
    return out


def hue_distance(h, centre):
    return np.abs((h - centre + 180) % 360 - 180)


def recolour(img, band_centre, band_half, new_hue, sat_min=0.0, sat_max=1.0, sat_gain=1.0, feather=12.0,
             frame=None, keep=None, lift=0.0):
    """Move pixels whose hue is within band_half of band_centre (and saturation in range) to new_hue.
    Weight falls off linearly over `feather` degrees past the band edge; saturation is scaled.
    `keep` = (x0, y0, x1, y1) inside each `frame` = (w, h) of the sheet is left untouched. `lift` moves the
    value that share of the way to white (a pastel)."""
    a = np.asarray(img.convert("RGBA")).astype(float) / 255
    hsv = rgb_to_hsv(a[..., :3])
    dist = hue_distance(hsv[..., 0], band_centre)
    w = np.clip((band_half + feather - dist) / feather, 0, 1)
    w *= (hsv[..., 1] >= sat_min) & (hsv[..., 1] <= sat_max) & (a[..., 3] > 0)
    if keep:
        ys, xs = np.mgrid[0:a.shape[0], 0:a.shape[1]]
        fx, fy = xs % frame[0], ys % frame[1]
        w *= ~((fx >= keep[0]) & (fx < keep[2]) & (fy >= keep[1]) & (fy < keep[3]))
    new = hsv.copy()
    new[..., 0] = new_hue
    new[..., 1] = np.clip(hsv[..., 1] * sat_gain, 0, 1)
    new[..., 2] = hsv[..., 2] * (1 - lift) + lift
    rgb = hsv_to_rgb(new) * w[..., None] + a[..., :3] * (1 - w[..., None])
    out = np.concatenate([rgb, a[..., 3:]], -1)
    return Image.fromarray((np.clip(out, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")


# The test bench's deck ("a cleaner, sciency look"): the assembler's tan deck and
# rails, inside the machinery region of each frame, turned a light cool steel. Only warm pixels in
# smooth areas (low local contrast) change, blended in RGB toward a neutral of their own brightness, so
# gears keep their detail, copper keeps its colour and the shading stays (chosen from three variants).
DECK = dict(std_max=0.32, gain=1.55, blur=3.0, tint=(0.93, 0.96, 1.0), frame=(214, 226), region=(40, 0, 172, 152))


def whiten_deck(img, std_max, gain, blur, tint, frame, region):
    from PIL import ImageFilter
    a = np.asarray(img).astype(float) / 255
    hsv = rgb_to_hsv(a[..., :3])
    h, s = hsv[..., 0], hsv[..., 1]
    lum = a[..., :3] @ np.array([0.3, 0.59, 0.11])

    def blurred(x, r):
        return np.asarray(Image.fromarray((np.clip(x, 0, 1) * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(r))).astype(float) / 255
    std = np.sqrt(np.clip(blurred(lum ** 2, 2) - blurred(lum, 2) ** 2, 0, 1))
    ys, xs = np.mgrid[0:a.shape[0], 0:a.shape[1]]
    fx, fy = xs % frame[0], ys % frame[1]
    inside = (fx >= region[0]) & (fx < region[2]) & (fy >= region[1]) & (fy < region[3])
    w = ((h >= 8) & (h <= 50) & inside & (a[..., 3] > 0.5)).astype(float)
    w *= np.clip((std_max - std) / (std_max * 0.5), 0, 1) * np.clip((0.8 - s) / 0.2, 0, 1)
    w = blurred(w, blur) * ((h >= 5) & (h <= 55)) * inside
    grey = np.minimum(lum * gain, 0.9)[..., None] * np.array(tint)
    rgb = a[..., :3] * (1 - w[..., None]) + grey * w[..., None]
    return Image.fromarray((np.clip(np.concatenate([rgb, a[..., 3:]], -1), 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")


def load(rel):
    return Image.open(BASE / rel).convert("RGBA")


# Paint recipes. Assembler 1's panels are a low-saturation grey-green; assembler 2's are blue.
# Assembler 1: only the outer frame and front panels; its machinery shares the panels' grey-green.
TEAL = dict(band_centre=110, band_half=60, new_hue=178, sat_min=0.04, sat_max=0.45, sat_gain=3.0,
            frame=(214, 226), keep=(40, 0, 172, 152))

# The empirical science pack (0.72, user: the teal red-science flask read as chemical science; a late-game
# base, a tint no pack uses; chosen from candidate sheets): the metallurgic flask, its orange liquid a pale
# mint (the glass and highlights keep their colours). Lilac first: at a cost list's size it read as a pale
# production science, which every endless technology lists beside it.
DATA = dict(band_centre=30, band_half=35, new_hue=150, sat_min=0.06, sat_max=1.0, sat_gain=0.4, lift=0.25)

# Fluid heaters: the boiler's and heat exchanger's grey-green body in the test bench's teal (the copper
# pipes are another hue and stay).
HEATER = dict(band_centre=110, band_half=60, new_hue=178, sat_min=0.04, sat_max=0.45, sat_gain=3.0)
# The fluid chiller (0.71): the boiler in water's hue (vanilla's water colour, as the fluid hopper's face).
CHILLER = dict(HEATER, new_hue=float(np.degrees(np.arctan2(np.sqrt(3) * (0.34 - 0.6), 2 * 0 - 0.34 - 0.6)) % 360))
CHILLER_FILES = [f"boiler/boiler-{d}-idle.png" for d in "NESW"]
# The pressure heater (0.72, user: it looked exactly like the fluid heater): the boiler in crimson, hot beside the
# heater's teal and the chiller's blue (rust, ember and brick ran into the copper pipework; candidate sheet).
PRESSURE = dict(HEATER, new_hue=355, sat_gain=3.0)
HEATER_FILES = ([f"boiler/boiler-{d}-idle.png" for d in "NESW"]
                + [f"heat-exchanger/heatex-{d}-{k}.png" for d in "NESW" for k in ("idle", "heated")])

# The icon without the entity sheet's frame and kept deck (0.70, user: the icon stayed vanilla; the deck
# region, sized for a 214x226 frame, covered most of a 64-pixel icon).
TEAL_ICON = {k: v for k, v in TEAL.items() if k not in ("frame", "keep")}

JOBS = [
    # (output, source, crop box or None for the whole sheet, recipe)
    ("test-bench.png", "entity/assembling-machine-1/assembling-machine-1.png", None, TEAL),
]

# The analysis station (0.70, user): the lab's idle frame with its golden struts in the test bench's teal and
# its base ring painted in it, as the bench's skirt is; the glass untouched. The icon is the frame, shrunk.
STRUTS = dict(band_centre=35, band_half=25, new_hue=178, sat_min=0.12, sat_max=1.0, sat_gain=1.2)
LAB_FRAME, LAB_BASE_ROW = (0, 0, 194, 174), 118


def icon_from(img, name):
    """An icon from an entity frame: its drawn part, centred on a square, at 64 pixels."""
    dome = img.crop(img.getbbox())
    side = max(dome.size)
    square = Image.new("RGBA", (side, side), (0, 0, 0, 0))
    square.alpha_composite(dome, ((side - dome.size[0]) // 2, (side - dome.size[1]) // 2))
    square.resize((64, 64), Image.LANCZOS).save(OUT / name, optimize=True)


# The test bench's icon from its own recoloured frame (0.70, user: the icon stayed vanilla; assembler 1's icon
# is drawn in rust browns, so no recolour of it reaches the bench's teal).
def make_bench_icon():
    icon_from(Image.open(OUT / "test-bench.png").convert("RGBA").crop((0, 0, 214, 226)), "test-bench-icon.png")
    print("test-bench-icon.png (from the frame)")


def station_paint(frame):
    """The lab's struts in the bench's teal, its base tinted toward it: one lab frame as the station."""
    out = np.asarray(recolour(frame, **STRUTS)).astype(float) / 255
    f = out[LAB_BASE_ROW:, :, :3]
    lum = f.mean(-1, keepdims=True)
    out[LAB_BASE_ROW:, :, :3] = np.clip(lum * TEAL_RGB * 1.3, 0, 1) * 0.65 + f * 0.35
    return Image.fromarray((np.clip(out, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")


def make_station(made):
    frame = load("entity/lab/lab.png").crop(LAB_FRAME)
    img = station_paint(frame)
    img.save(OUT / "station.png", optimize=True)
    icon_from(img, "station-icon.png")
    made.append(("station.png", frame, img))
    print("station.png, station-icon.png")
    # The working animation (0.72, user: no animation was a lost chance): every frame of the lab's sheet,
    # painted as the station. The script draws it while the station analyses.
    sheet = load("entity/lab/lab.png")
    w, h = LAB_FRAME[2], LAB_FRAME[3]
    out = Image.new("RGBA", sheet.size, (0, 0, 0, 0))
    for y in range(0, sheet.size[1], h):
        for x in range(0, sheet.size[0], w):
            out.paste(station_paint(sheet.crop((x, y, x + w, y + h))), (x, y))
    out.save(OUT / "station-working.png", optimize=True)
    print("station-working.png")


# The sample (0.70, user: a flask read as a science pack): a report, vanilla's blueprint book in paper grey,
# with a sigma (spread, what samples measure) on its cover in the game's own Noto Sans.
def make_sample_icon():
    from PIL import ImageDraw, ImageFont
    book = load("icons/blueprint-book.png").crop((0, 0, 64, 64))
    a = np.asarray(book).astype(float) / 255
    g = a.copy()
    g[..., :3] = np.clip(a[..., :3].mean(-1, keepdims=True) * 1.25, 0, 1)
    img = Image.fromarray((g * 255 + 0.5).astype(np.uint8), "RGBA")
    d = ImageDraw.Draw(img)
    font = ImageFont.truetype(str(BASE.parent.parent / "core/fonts/NotoSans-Bold.ttf"), 30)
    bb = d.textbbox((0, 0), "σ", font=font)
    x, y = 34 - (bb[0] + bb[2]) / 2, 26 - (bb[1] + bb[3]) / 2
    d.text((x + 1, y + 1), "σ", font=font, fill=(235, 235, 235, 200))
    d.text((x, y), "σ", font=font, fill=(70, 70, 75, 255))
    img.save(OUT / "sample-icon.png", optimize=True)
    # The cover left blank (0.72, user: samples of every tier looked alike): the data stage draws the pack
    # the sample needs on it.
    Image.fromarray((g * 255 + 0.5).astype(np.uint8), "RGBA").save(OUT / "sample-cover.png", optimize=True)
    print("sample-icon.png, sample-cover.png")


TEAL_RGB = None                    # the test bench's paint, set in make_hopper()


def teal_of_bench():
    """The test bench's paint: the median colour of its recoloured pixels (hue near 178)."""
    img = recolour(load("entity/assembling-machine-1/assembling-machine-1.png").crop((0, 0, 214, 226)), **TEAL)
    a = np.asarray(img).astype(float) / 255
    hsv = rgb_to_hsv(a[..., :3])
    m = (hue_distance(hsv[..., 0], 178) < 8) & (hsv[..., 1] > 0.3) & (a[..., 3] > 0.9)
    c = np.median(a[..., :3][m], 0)
    return c / max(c.max(), 1e-9)


# The hopper (0.71, user: the steel chest felt low-tech): vanilla's requester chest, its hatch open (it reads as
# a funnel you feed), its paint moved to the bench's teal (steel and shading kept). Chosen from sketches of the
# five logistic chests and three hatch states.
REQUESTER_FRAME = (66, 74)   # one frame of logistic-chest/requester-chest.png; frame 6 is the hatch open


def make_hopper(made):
    global TEAL_RGB
    TEAL_RGB = teal_of_bench()
    w, h = REQUESTER_FRAME
    sheet = load("entity/logistic-chest/requester-chest.png")
    frame = sheet.crop((6 * w, 0, 7 * w, h))
    out = recolour(frame, band_centre=195, band_half=40, new_hue=178, sat_min=0.2)
    out.save(OUT / "hopper.png", optimize=True)
    icon = recolour(load("icons/requester-chest.png").crop((0, 0, 64, 64)), band_centre=195, band_half=40,
                    new_hue=178, sat_min=0.2)
    icon.save(OUT / "hopper-icon.png", optimize=True)
    made.append(("hopper.png", frame, out))
    print(f"hopper.png: {out.size[0]}x{out.size[1]} (requester chest, hatch open, teal)")



# The hoppers' animations: the iris of the requester chest closes and opens again when a hopper hands out a
# dose, and the fluid hopper's pump turns while it supplies (drawn by script over the still picture). Each
# sheet keeps only the box of pixels that change between frames, so the rest of the entity (its circuit
# connector, its marks) is never covered; the boxes go to graphics_frames.lua for the data stage.
def changing_box(frames):
    stack = np.stack([np.asarray(f).astype(int) for f in frames])
    moving = (stack != stack[0:1]).any(axis=(0, 3))
    ys, xs = np.nonzero(moving)
    return int(xs.min()), int(ys.min()), int(xs.max()) + 1, int(ys.max()) + 1


def sheet_of(frames, box, line_length):
    w, h = box[2] - box[0], box[3] - box[1]
    rows = -(-len(frames) // line_length)
    out = Image.new("RGBA", (w * min(line_length, len(frames)), h * rows))
    for i, f in enumerate(frames):
        out.paste(f.crop(box), ((i % line_length) * w, (i // line_length) * h))
    return out


def make_hopper_animations():
    boxes = {}
    w, h = REQUESTER_FRAME
    sheet = load("entity/logistic-chest/requester-chest.png")
    frames = [recolour(sheet.crop((i * w, 0, (i + 1) * w, h)), band_centre=195, band_half=40, new_hue=178,
                       sat_min=0.2) for i in range(7)]
    box = changing_box(frames)
    sheet_of(frames, box, 7).save(OUT / "hopper-iris.png", optimize=True)
    boxes["iris"] = (box, (w, h))
    for d, (w, h) in PUMP_FRAMES.items():
        src = load(f"entity/pump/pump-{d}.png")
        frames = [paint_casing(src.crop(((i % 8) * w, (i // 8) * h, (i % 8 + 1) * w, (i // 8 + 1) * h)))
                  for i in range(32)]
        box = changing_box(frames)
        sheet_of(frames, box, 8).save(OUT / f"fluid-hopper-{d}-anim.png", optimize=True)
        boxes[d] = (box, (w, h))
    lines = ["-- Generated by scripts/make_sprites.py: do not edit. Per animation, the box of its frame kept (pixels",
             "-- that change between frames) and the full frame's size, for the shift.", "return {"]
    for k, ((x0, y0, x1, y1), (fw, fh)) in boxes.items():
        lines.append(f"  [\"{k}\"] = {{x = {x0}, y = {y0}, width = {x1 - x0}, height = {y1 - y0}, frame_width = {fw}, frame_height = {fh}}},")
    lines.append("}")
    (OUT.parent / "graphics_frames.lua").write_text("\n".join(lines) + "\n")
    print("hopper animations: " + ", ".join(f"{k} {b[2] - b[0]}x{b[3] - b[1]}" for k, (b, _) in boxes.items()))

# The fluid hopper (0.71, user: one entity a chest, the other a fluid input; then: the chest looked poor for
# fluids, vanilla's pump instead): the pump's first frame in each direction, its casing painted the bench's teal.
# Painted by smoothed regions, not pixel by pixel (the pump's rusty texture mixes hues within a few pixels:
# per-pixel selection came out blotchy, user), as the hopper's face is painted (the metal's light in the
# paint), and the highlights left their own light (user: recoloured glints look bad). Chosen from three.
PUMP_FRAMES = {"north": (103, 164), "east": (130, 109), "south": (114, 160), "west": (131, 111)}


def paint_casing(img, blur=4.0, cut=0.4, hi_lo=0.62, hi_hi=0.85, strength=0.7, gain=1.35):
    from PIL import ImageFilter
    a = np.asarray(img.convert("RGBA")).astype(float) / 255
    hsv = rgb_to_hsv(a[..., :3])
    raw = ((hsv[..., 1] >= 0.12) & (hsv[..., 1] <= 0.40) & (hue_distance(hsv[..., 0], 25) < 35)
           & (a[..., 3] > 0.8)).astype(float)
    m = np.asarray(Image.fromarray((raw * 255).astype(np.uint8)).filter(ImageFilter.GaussianBlur(blur))).astype(float) / 255
    m = np.clip((m - cut) / 0.25, 0, 1) * (a[..., 3] > 0.8)
    m *= 1 - np.clip((a[..., :3].max(-1) - hi_lo) / (hi_hi - hi_lo), 0, 1)
    m *= strength   # (softer: at full strength it read cyan in the game's light, user)
    lum = a[..., :3].mean(-1, keepdims=True)
    painted = np.clip(lum * TEAL_RGB * gain, 0, 1) * 0.8 + a[..., :3] * 0.2
    out = a.copy()
    out[..., :3] = a[..., :3] * (1 - m[..., None]) + painted * m[..., None]
    return Image.fromarray((np.clip(out, 0, 1) * 255 + 0.5).astype(np.uint8), "RGBA")


def make_fluid_hopper(made):
    for d, (w, h) in PUMP_FRAMES.items():
        frame = load(f"entity/pump/pump-{d}.png").crop((0, 0, w, h))
        out = paint_casing(frame)
        out.save(OUT / f"fluid-hopper-{d}.png", optimize=True)
        made.append((f"fluid-hopper-{d}.png", frame, out))
    icon = paint_casing(load("icons/pump.png").crop((0, 0, 64, 64)), blur=1.5)
    icon.save(OUT / "fluid-hopper-icon.png", optimize=True)
    for old in ("fluid-hopper.png",):  # (the chest version, before the pump)
        (OUT / old).unlink(missing_ok=True)
    print("fluid hopper: the pump in 4 directions, casing teal")


# The fluid chiller (0.72, user: the blue boiler read as a reskinned heater): Space Age's heating tower, a
# burner as the chiller is, its mauve body in the chiller's blue and its fire a cold glow. Its pipes stay copper
# and its tanks brass: they are found as shapes (strongly coloured pixels, specks dropped, widened over their
# highlights) and kept, since a recolour by saturation alone streaked their highlights blue (user, candidates).
TOWER = Path(BASE).parent.parent / "space-age" / "graphics"


def keep_shapes(a, hsv, centre, half, sat_min, min_area, grow):
    from scipy import ndimage
    h, s, v = hsv[..., 0], hsv[..., 1], hsv[..., 2]
    core = (a[..., 3] > 0) & (s > sat_min) & (v > 0.25) & (hue_distance(h, centre) <= half)
    lab, n = ndimage.label(core)
    sizes = ndimage.sum(core, lab, range(1, n + 1))
    keep = np.isin(lab, np.nonzero(sizes >= min_area)[0] + 1)
    return ndimage.binary_dilation(ndimage.binary_closing(keep, iterations=2), iterations=grow)


def make_chiller_tower():
    blue = float(CHILLER["new_hue"])
    src = Image.open(TOWER / "entity/heating-tower/heating-tower-main.png").convert("RGBA")
    a = np.asarray(src).astype(float) / 255
    hsv = rgb_to_hsv(a[..., :3])
    kept = keep_shapes(a, hsv, 12, 16, 0.45, 60, 3) | keep_shapes(a, hsv, 42, 14, 0.30, 60, 2)  # pipes, brass
    body = np.asarray(recolour(src, band_centre=350, band_half=35, new_hue=blue, sat_min=0.04, sat_max=0.34,
                               sat_gain=2.4, feather=8)).copy()
    body[kept] = np.asarray(src)[kept]
    # The pipes from the tower's red-orange to copper.
    main = recolour(Image.fromarray(body), band_centre=8, band_half=14, new_hue=22, sat_min=0.36, sat_gain=0.9, feather=6)
    (OUT / "chiller").mkdir(exist_ok=True)
    main.save(OUT / "chiller" / "tower-main.png", optimize=True)
    for name in ("working-fire", "working-light"):
        img = Image.open(TOWER / f"entity/heating-tower/heating-tower-{name}.png").convert("RGBA")
        recolour(img, band_centre=30, band_half=60, new_hue=195, sat_min=0.0, sat_gain=0.85, feather=10).save(
            OUT / "chiller" / f"tower-{name}.png", optimize=True)
    # The icon: the tower itself, a frame of its cold fire on it (vanilla's icon draws the tower working, in
    # colours of its own a recolour of the body misses), scaled into the icon's square.
    fire = Image.open(OUT / "chiller" / "tower-working-fire.png").convert("RGBA").crop((0, 0, 160, 184))
    ic = Image.new("RGBA", (main.width, main.height), (0, 0, 0, 0))
    ic.alpha_composite(main)
    base = np.asarray(ic).astype(float)
    layer = Image.new("RGBA", ic.size, (0, 0, 0, 0))
    layer.alpha_composite(fire, (int(main.width / 2 - 80), int(main.height / 2 + 2 * (-74.5 + 22.5) - 92)))
    f = np.asarray(layer).astype(float)
    base[..., :3] = np.clip(base[..., :3] + f[..., :3] * f[..., 3:] / 255, 0, 255)
    ic = Image.fromarray(base.astype(np.uint8), "RGBA").crop(Image.fromarray(base.astype(np.uint8)).getbbox())
    k = 62 / max(ic.size)
    ic = ic.resize((max(1, round(ic.width * k)), max(1, round(ic.height * k))), Image.LANCZOS)
    icon = Image.new("RGBA", (64, 64), (0, 0, 0, 0))
    icon.alpha_composite(ic, ((64 - ic.width) // 2, (64 - ic.height) // 2))
    icon.save(OUT / "chiller-icon.png", optimize=True)
    for old in CHILLER_FILES:  # (the blue boiler, before the tower)
        (OUT / "chiller" / old.split("/")[1]).unlink(missing_ok=True)
    print("chiller: the heating tower, body blue, pipes copper, fire cold")


def make_data_icon():
    """The empirical science pack: the metallurgic flask in mint, with the vanilla search icon as a badge
    (the mod's own pack at a glance). 64x64, no mipmaps."""
    flask = recolour(Image.open(BASE.parent.parent / "space-age/graphics/icons/metallurgic-science-pack.png")
                     .convert("RGBA").crop((0, 0, 64, 64)), **DATA)
    badge = Image.open(BASE.parent.parent / "core/graphics/icons/search.png").convert("RGBA").resize((30, 30), Image.LANCZOS)
    flask.alpha_composite(badge, (34, 34))
    flask.save(OUT / "research-data-icon.png", optimize=True)
    print("research-data-icon.png: 64x64")


# Achievement icons (0.72, user: more achievements, Factorio in flavour): vanilla's bronze gear ring (from its
# tech-maniac art, whose scene stays inside the ring), its painted scene replaced by a dark disc and the mod's or vanilla's icon.
DATA_ROOT = BASE.parent.parent
ACHIEVEMENT_ICONS = {
    "lab-rat": [OUT / "sample-icon.png"],
    "statistically-significant": [DATA_ROOT / "core/graphics/icons/mip/check-mark-green.png"],
    "fieldwork": [DATA_ROOT / "space-age/graphics/icons/starmap-planet-fulgora.png"],
    "reviewer-2": [OUT / "station-icon.png"],
    "replication-crisis": [DATA_ROOT / "core/graphics/icons/alerts/danger-icon.png"],
    "sum-of-parts": [BASE / "icons/coal.png", BASE / "icons/stone.png"],
    "waste-not": [BASE / "icons/copper-ore.png"],
    "cold-case": [DATA_ROOT / "space-age/graphics/icons/scrap.png"],
    "publish-or-perish": [OUT / "research-data-icon.png"],
    "gold-standard": [DATA_ROOT / "quality/graphics/icons/quality-legendary.png"],
    "large-numbers": [OUT / "sample-icon.png", OUT / "sample-icon.png", OUT / "sample-icon.png"],
    "brute-force": [OUT / "test-bench-icon.png"],
}


def make_achievements():
    ring = Image.open(BASE / "achievement/tech-maniac.png").convert("RGBA").crop((0, 0, 128, 128))
    size = ring.size[0]
    yy, xx = np.mgrid[0:size, 0:size]
    r = np.hypot(xx - (size - 1) / 2, yy - (size - 1) / 2)
    inner = size * 0.36
    a = np.asarray(ring).astype(float)
    disc = r < inner
    # The disc: the ring's own darkest bronze, shaded toward the edge.
    shade = np.clip(0.18 + 0.10 * (r / inner), 0, 1)
    for c, v in enumerate((60, 48, 38)):
        a[..., c] = np.where(disc, v * shade / 0.28, a[..., c])
    a[..., 3] = np.where(disc, 255, a[..., 3])
    base = Image.fromarray(np.clip(a, 0, 255).astype(np.uint8), "RGBA")
    (OUT / "achievement").mkdir(exist_ok=True)
    for name, srcs in ACHIEVEMENT_ICONS.items():
        img = base.copy()
        k = len(srcs)
        side = int(inner * (1.5 if k == 1 else 1.1))
        for i, src in enumerate(srcs):
            ic = Image.open(src).convert("RGBA")
            if ic.size[0] > ic.size[1]:  # an icon file with its smaller sizes beside it: the first square
                ic = ic.crop((0, 0, ic.size[1], ic.size[1]))
            ic = ic.resize((side, side), Image.LANCZOS)
            off = (i - (k - 1) / 2) * side * 0.55
            img.alpha_composite(ic, (int(size / 2 - side / 2 + off), int(size / 2 - side / 2 + off * 0.3)))
        img.save(OUT / "achievement" / f"{name}.png", optimize=True)
    print(f"achievements: {len(ACHIEVEMENT_ICONS)} icons")


def make_thumbnail():
    """Mod portal thumbnail (144x144, the mod's root): the test bench (its first frame) with research data
    as a badge, on the dark background the portal shows thumbnails on. Vanilla art, recoloured."""
    bench = Image.open(OUT / "test-bench.png").convert("RGBA").crop((0, 0, 214, 226))
    # The sprite's baked soft shadow (dark, semi-transparent edge pixels) reads as a grey halo on light
    # backgrounds: drop it, keep everything solid.
    a = np.asarray(bench).astype(float)
    lum = a[..., :3].mean(-1)
    a[..., 3] = np.where((a[..., 3] < 200) & (lum < 70), 0, a[..., 3])
    bench = Image.fromarray(a.astype(np.uint8), "RGBA")
    bench = bench.crop(bench.getbbox())
    bench.thumbnail((132, 132), Image.LANCZOS)
    thumb = Image.new("RGBA", (144, 144), (0, 0, 0, 0))
    thumb.alpha_composite(bench, ((144 - bench.width) // 2, (144 - bench.height) // 2 - 4))
    badge = Image.open(OUT / "research-data-icon.png").convert("RGBA").resize((56, 56), Image.LANCZOS)
    thumb.alpha_composite(badge, (144 - 58, 144 - 58))
    thumb.save(OUT.parent / "thumbnail.png", optimize=True)
    print("thumbnail.png: 144x144")


def main():
    OUT.mkdir(parents=True, exist_ok=True)
    made = []
    for name, src, box, recipe in JOBS:
        img = load(src)
        if box:
            img = img.crop(box)
        out = recolour(img, **recipe)
        if name == "test-bench.png":
            out = whiten_deck(out, **DECK)
        out.save(OUT / name, optimize=True)
        made.append((name, img, out))
        print(f"{name}: {out.size[0]}x{out.size[1]}")
    make_hopper(made)
    make_fluid_hopper(made)
    make_hopper_animations()
    make_bench_icon()
    make_station(made)
    make_sample_icon()
    make_data_icon()
    (OUT / "heater").mkdir(exist_ok=True)
    for f in HEATER_FILES:
        recolour(load("entity/" + f), **HEATER).save(OUT / "heater" / f.split("/")[1], optimize=True)
    print(f"heaters: {len(HEATER_FILES)} sheets")
    make_chiller_tower()
    (OUT / "pressure").mkdir(exist_ok=True)
    for f in CHILLER_FILES:
        recolour(load("entity/" + f), **PRESSURE).save(OUT / "pressure" / f.split("/")[1], optimize=True)
    print(f"pressure heater: {len(CHILLER_FILES)} sheets, hue {PRESSURE['new_hue']:.0f}")
    make_thumbnail()
    make_achievements()
    if "--sheet" in sys.argv:  # before/after contact sheet of the building frames, for review
        path = sys.argv[sys.argv.index("--sheet") + 1]
        frames = [(n, b.crop((0, 0, 214, 226)) if n == "test-bench.png" else b, a.crop((0, 0, 214, 226))
                   if n == "test-bench.png" else a) for n, b, a in made if not n.endswith("icon.png")]
        sheet = Image.new("RGBA", (len(frames) * 240, 480), (40, 40, 40, 255))
        for i, (_, before, after) in enumerate(frames):
            sheet.paste(before, (i * 240, 0), before)
            sheet.paste(after, (i * 240, 240), after)
        sheet.resize((sheet.width * 2, sheet.height * 2)).save(path)


if __name__ == "__main__":
    main()
