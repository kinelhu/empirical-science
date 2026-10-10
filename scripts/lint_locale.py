"""Fail if the mod uses a locale key that locale.cfg does not define.

A missing key shows in game as 'Unknown key: "es.family-oil"', and nothing else catches it.
Keys are collected from the Lua sources: literal {"section.key"} strings, the "col-*" lists joined
to "es.", and the dynamically built families of keys listed in DYNAMIC (each expanded from shared.lua
or a fixed set). Run: python scripts/lint_locale.py <mod dir>
"""
import re
import sys
from pathlib import Path

mod = Path(sys.argv[1])
sections = {}
current = None
for line in (mod / "locale/en/locale.cfg").read_text().splitlines():
    line = line.strip()
    if line.startswith("[") and line.endswith("]"):
        current = line[1:-1]
    elif "=" in line and current and not line.startswith(";"):
        sections.setdefault(current, set()).add(line.split("=", 1)[0])
defined = {f"{s}.{k}" for s, keys in sections.items() for k in keys}

lua = {p: p.read_text() for p in mod.rglob("*.lua")}
shared = (mod / "shared.lua").read_text()
used = {}
for path, text in lua.items():
    for m in re.finditer(r'\{"((?:es|es-route|recipe-name|item-name|entity-name|technology-name)\.[a-z0-9-]+)"', text):
        if not m.group(1).endswith("-"):  # a prefix of a dynamically built key: see DYNAMIC
            used.setdefault(m.group(1), path.name)
    for m in re.finditer(r'"(col-[a-z-]+)"', text):
        used.setdefault("es." + m.group(1), path.name)

# Tips and tricks items (0.72, user: the section's title page showed "Unknown key"): each needs its name and,
# unless the prototype gives its own, its description; the title page too.
for path, text in lua.items():
    for m in re.finditer(r'type = "tips-and-tricks-item", name = "([a-z0-9-]+)"(.*?)\}', text, re.S):
        name, rest = m.group(1), m.group(2)
        used.setdefault("tips-and-tricks-item-name." + name, path.name)
        if "localised_description" not in rest:
            used.setdefault("tips-and-tricks-item-description." + name, path.name)
families = set(re.findall(r'family = "([a-z-]+)"', shared))
# Premix families are built ("premix-<a>-<b>") and shown as one label, es.family-premix.
families = {f for f in families if not f.startswith("premix-")} | {"premix", "blend", "slurry", "emulsion"}
routes = []
for target, block in re.findall(r'\n  (?:\["?)?([a-z-]+)"?\]? = \{\n(.*?)\n  \},', shared, re.S):
    routes += [f"{target}-{k}" for k in re.findall(r'key = "([a-z-]+)"', block)]
# The research branch (data.lua): names built as branch("<name>", ...), with name, description, effect.
branch = set(re.findall(r'branch\("([a-z-]+)"', (mod / "data.lua").read_text()))
# The staged reveal's technologies (shared.stages: tech = "es-..."), and the effect lines added to two
# branch technologies.
stage_techs = set(re.findall(r'tech = "(es-[a-z-]+)"', shared))
branch |= stage_techs
DYNAMIC = {
    "technology-name.": branch,
    "technology-description.": branch,
    "es-tech-effect.": branch | {"es-side-effects", "es-circuit-mode"},
    "es.family-": families,
    "es.model-": {"quadratic", "linear", "saturating", "threshold", "cliff"},
    "es.fit-": {"need-doses", "singular"},
    "es.mix-fit-": {"need-points", "singular"},
    "es.mix-": {"synergy", "antagonism", "unclear"},
    "es.effect-": {"yield", "speed", "pollution", "efficiency", "freshness", "quality"},
    "es.chart-y-": {"speed", "pollution"},
    # The answer key's shape column (0.62): the world's shapes, and inert or inhibitor.
    "es.ak-shape-": {"hump", "plateau", "threshold", "two_peak", "biphasic", "spike", "cliff", "inert", "inhibitor"},
    "es.ak-kind-": {"early", "tier1", "tier2", "residue", "living", "catalyst", "premix", "cat-premix", "agent"},
    "es.screen-sort-": {"list", "family", "samples", "yield", "data"},
    "es.progress-": {"samples", "packs", "efficiency", "settled", "findings", "dosed", "extra"},
    "es.progress-y-": {"samples", "packs", "efficiency", "settled", "findings", "dosed", "extra"},
    "es.progress-range-": {"hour", "hours", "all"},
}
for prefix, names in DYNAMIC.items():
    for name in names:
        used.setdefault(prefix + name, "(dynamic)")

# Prose (0.72: any text in the mod must read like vanilla's). Vanilla's locale
# has no semicolon and no em dash, and a number in a string is a parameter, never typed: fail on each.
# ALLOWED_DIGITS: numbers that are part of a name or a fixed convention, matched as written.
ALLOWED_DIGITS = ["95%", "0 uses", "Lab circuits 1", "Lab circuits 2", "Lab circuits 3", "pages 1 and 2", "Pages 1 and 2", "Page 0", "Page 1", "Page 2", "Page 3", "page 3", "at 3", "but 0",
                  "page 5", "at 5", "Page 0", "page 0", "1=band", "1=station", "1=sample", "1=finding", "1=target",
                  "Scrap forensics 1", "Scrap forensics 2", "tier 1", "tier 2", "Costs 1/", "Reviewer 2"]
prose = []
current = None
for n, line in enumerate((mod / "locale/en/locale.cfg").read_text().splitlines(), 1):
    if line.startswith("["):
        current = line
        continue
    if "=" not in line or line.startswith(";"):
        continue
    key, value = line.split("=", 1)
    if ";" in value:
        prose.append(f"line {n} {current} {key}: semicolon")
    if "\u2014" in value:
        prose.append(f"line {n} {current} {key}: em dash")
    bare = re.sub(r"__plural_for_parameter__\d+__\{[^}]*\}__|__\d+__|\[[^\]]*\]", "", value)
    for allowed in ALLOWED_DIGITS:
        bare = bare.replace(allowed, "")
    if re.search(r"\d", bare):
        prose.append(f"line {n} {current} {key}: typed number in {bare.strip()[:80]!r}")
if prose:
    for p in prose:
        print("prose:", p)
    sys.exit(1)

missing = sorted(k for k in used if k not in defined)
if missing:
    for k in missing:
        print(f"missing locale key {k} (used in {used[k]})")
    sys.exit(1)
print(f"locale ok ({len(used)} keys used, {len(families)} families)")
