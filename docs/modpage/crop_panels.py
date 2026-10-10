"""Crops the measured panels for the mod page (run after scripts/guitest.sh and scripts/page_shots.sh panels).
Boxes are in pixels of a 1400-wide preview of each 3024-wide shot. Findings comes from the findings save and starts below
the report (its evidence is written, so the report compares it with the truth badly); the rest from the GUI test."""
from PIL import Image
import os
H = os.path.expanduser("~/Library/Application Support/")
GT, PS = H + "factorio-guitest/script-output/", H + "factorio-pageshots/script-output/"
k = 3024 / 1400  # boxes measured on the 1400-wide previews
shots = {  # (source, box in preview pixels: left, top, right, bottom)
    "screening": (GT + "es-panel-screening.png", (350, 70, 1048, 542)),
    "dose-response": (GT + "es-panel-gear.png", (350, 70, 1048, 668)),
    "mixtures": (GT + "es-panel-mixtures.png", (350, 70, 1048, 570)),
    "coverage": (GT + "es-panel-coverage.png", (350, 70, 1048, 488)),
    "findings": (PS + "es-page-dossiers.png", (358, 500, 1040, 676)),
}
for name, (src, box) in shots.items():
    im = Image.open(src).crop(tuple(round(v * k) for v in box))
    im.save(f"docs/modpage/images/{name}.png", optimize=True)
    print(name, im.size)
