"""The mod page preview (preview.html) from description.md, in preview.template.html.
Run: uv run --with markdown docs/modpage/build_preview.py"""
from pathlib import Path
import markdown

HERE = Path(__file__).resolve().parent
md = (HERE / "description.md").read_text()
# Numbers come from the balance model (docs/balance.py writes world_size.json): none is typed on the page.
import json
def words(n):
    for unit, name in ((1e9, "billion"), (1e6, "million"), (1e3, "thousand")):
        if n >= unit:
            v = n / unit
            return f"about {v:.0f} {name}" if v >= 10 else f"about {v:.1g} {name}"
    return f"about {round(n, -2):.0f}"
ws = json.loads((HERE / "world_size.json").read_text())
values = {"trials_all": words(ws["trials_all"]), "trials_theory": f"{round(ws['trials_theory'], -2):,.0f}",
          "theory_cover": f"{ws['theory_cover']:.0%}", "targets": str(ws["targets"]), "additives": str(ws["additives"])}
for k, v in values.items():
    md = md.replace("{{" + k + "}}", v)
if "{{" in md:
    raise SystemExit("description.md has a placeholder world_size.json does not fill")
# The text for the mod portal: its images from the public repository (the portal shows no relative path).
IMAGES = "https://raw.githubusercontent.com/kinelhu/empirical-science/main/docs/modpage/images/"
portal = md.replace("](images/", "](" + IMAGES)
if "](images/" in portal:
    raise SystemExit("description.portal.md still links an image by a relative path")
(HERE / "description.portal.md").write_text(portal)
title, rest = md.split("\n", 1)
body = markdown.markdown(rest)
# A paragraph holding only an image becomes a figure; its alt text is the caption, except for the diagrams.
import re
def figure(m):
    alt, src = m.group(1), m.group(2)
    cap = "" if src.endswith(("loop.png", "dosing.png", "scene.jpg")) else f"<figcaption>{alt}</figcaption>"
    cls = ' class="hero"' if src.endswith("scene.jpg") else ""
    return f'<figure{cls}><img src="{src}" alt="{alt}">{cap}</figure>'
body = re.sub(r'<p><img alt="([^"]*)" src="([^"]*)" ?/?></p>', figure, body)
# The first paragraph is the lede.
body = body.replace("<p>", '<p class="lede">', 1)
out = (HERE / "preview.template.html").read_text().replace("{title}", title.lstrip("# ")).replace("{body}", body)
(HERE / "preview.html").write_text(out)
print("preview.html", len(out))
