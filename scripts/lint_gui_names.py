"""Fail if a GUI element is named like a LuaGuiElement property or method.

Such a name cannot be created (LuaGuiElement.add raises "Invalid name"), and the GUI is not
exercised by the headless test, so this is checked statically against the version-matched API.
"""
import json
import re
import sys
from pathlib import Path

api = Path(sys.argv[1])
mod = Path(sys.argv[2])
classes = json.loads(api.read_text())["classes"]
gui = next(c for c in classes if c["name"] == "LuaGuiElement")
reserved = {x["name"] for key in ("attributes", "methods") for x in gui[key]}
bad = []
for f in sorted(mod.rglob("*.lua")):
    for n, line in enumerate(f.read_text().splitlines(), 1):
        for name in re.findall(r'\bname\s*=\s*"([A-Za-z_0-9]+)"', line):
            if name in reserved and (".add" in line or "type =" in line):
                bad.append(f"{f.relative_to(mod.parent)}:{n}: GUI element name '{name}' is a LuaGuiElement member")
print("\n".join(bad) if bad else f"gui names ok ({len(reserved)} reserved names checked)")
sys.exit(1 if bad else 0)
