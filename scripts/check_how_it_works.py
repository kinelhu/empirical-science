"""Keep docs/how-it-works.md honest (a maintained diagram of the mod).

Forward: every file, storage key, shared constant, truth function and es- name the document cites must
exist. Reverse: every script module, placeable entity and mod circuit signal must be named in it, so a
new one cannot land without the map. Exits 1 with each miss named.
"""
import re
import sys
from pathlib import Path

REPO = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parent.parent
MOD = REPO / "empirical-science"
doc = (REPO / "docs/how-it-works.md").read_text()
code = "\n".join(p.read_text() for p in [*MOD.glob("*.lua"), *MOD.glob("scripts/*.lua")])
data = (MOD / "data.lua").read_text()
shared = (MOD / "shared.lua").read_text()
truth = (MOD / "scripts/truth.lua").read_text()
locale = "\n".join(p.read_text() for p in MOD.glob("locale/*/*.cfg"))
misses = []

# Forward: files and directories in backticks.
for tok in re.findall(r"`([^`\s]+)`", doc):
    if re.search(r"\.(lua|sh|py|md)$", tok) or tok.startswith("tests/"):
        if not ((REPO / tok).exists() or (MOD / tok).exists() or (MOD / "scripts" / tok).exists()):
            misses.append(f"file {tok} does not exist")
# storage keys, shared constants, truth functions (anywhere: diagrams too).
for key in sorted(set(re.findall(r"storage\.([a-z_]+)", doc))):
    if f"storage.{key}" not in code:
        misses.append(f"storage.{key} is not used in the code")
for key in sorted(set(re.findall(r"\bshared\.([a-z_]+)\b(?!\.)", doc)) - {"lua"}):
    # Defined as shared.key = ..., or as a field of the table shared.lua opens with.
    if not re.search(rf"\bshared\.{key}\b|^\s+{key}\s*=", shared, re.M):
        misses.append(f"shared.{key} is not defined in shared.lua")
for fn in sorted(set(re.findall(r"\btruth\.([a-z_]+)\b(?!\.)", doc)) - {"lua"}):
    if not re.search(rf"\btruth\.{fn}\b", truth):
        misses.append(f"truth.{fn} is not in truth.lua")
# es- names: a trailing "-*" means a family of names sharing the prefix.
for name in sorted(set(re.findall(r"\bes-[a-z0-9-]+\*?", doc))):
    base = name.rstrip("*")
    pool = data + shared + code + locale
    if (REPO / "tests" / base).is_dir():
        continue  # a test mod's folder, cited as tests/<name>
    if name.endswith("*"):
        if base not in pool:
            misses.append(f"no name starts with {base}")
    elif not re.search(rf"\b{re.escape(base)}\b", pool):
        misses.append(f"{name} is not a prototype, signal or command")

# Reverse: modules, placeable entities, the mod's signals.
for mod in sorted(MOD.glob("scripts/*.lua")):
    if f"scripts/{mod.name}" not in doc:
        misses.append(f"module scripts/{mod.name} is not described")
placeable = set(re.findall(r'place_result = "(es-[a-z0-9-]+)"', data))
heaters = re.findall(r'\{name = "(es-[a-z-]*heater)"', shared)
for name in sorted(placeable | set(heaters)):
    if name not in doc:
        misses.append(f"placeable entity {name} is not named")
block = re.search(r"for i, sig in ipairs\(\{(.*?)\}\) do", data, re.S)
for name in re.findall(r'\{"(es-[a-z-]+)", "[A-Z]"\}', block.group(1) if block else ""):
    if name not in doc:
        misses.append(f"circuit signal {name} is not named")

if misses:
    print("docs/how-it-works.md is out of date:")
    for m in misses:
        print("  - " + m)
    sys.exit(1)
print(f"how-it-works ok ({len(re.findall(r'```mermaid', doc))} diagrams)")
