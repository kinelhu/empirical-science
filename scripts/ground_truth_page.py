import json, os, re, html, sys
SEED = sys.argv[1] if len(sys.argv) > 1 else "777"
d = json.load(open(os.path.expanduser('~/Library/Application Support/factorio-groundtruth/script-output/es-groundtruth.json')))
loc = open(os.path.expanduser('~/Dev/factorio-mods/empirical-science/locale/en/locale.cfg')).read()
sec, names = None, {}
for line in loc.split("\n"):
    if line.startswith("["): sec = line.strip("[]"); continue
    if "=" in line and sec in ("item-name", "fluid-name", "es-route"):
        k, v = line.split("=", 1); names[(sec, k)] = v
def nice(i):
    for s in ("item-name", "fluid-name"):
        if (s, i) in names and "__" not in names[(s, i)]: return names[(s, i)]
    return i.replace("-", " ").capitalize()
def label(r):
    if r.get("premix_of"):
        a, b = r["premix_of"]
        return f"{nice(a)} + {nice(b)}"
    return nice(r["name"])
KIND_ORDER = ["tier 1", "tier 2", "residue", "activated catalyst", "premix", "catalyst premix", "quality agent"]
KIND_CLASS = {k: "k" + str(i) for i, k in enumerate(KIND_ORDER)}
DEEP = ("activated catalyst", "premix", "catalyst premix")
RAW = ("tier 1", "tier 2", "residue")
def pct(x, sign=True): return (f"{x*100:+.1f}%" if sign else f"{x*100:.1f}%")
def heat(x, cap=0.3):
    a = max(-1, min(1, x / cap))
    return f"--h:{abs(a):.2f}", ("pos" if a >= 0 else "neg")
def chip(kind): return f'<span class="chip {KIND_CLASS[kind]}">{html.escape(kind)}</span>'
def esc(s): return html.escape(s)

targets = d["targets"]
# Summary rows
summary = []
for t in targets:
    rows = t["rows"]
    def best(kinds, key="net"):
        c = [r for r in rows if r["kind"] in kinds]
        return max(c, key=lambda r: r[key]) if c else None
    br, bd = best(RAW), best(DEEP)
    agents = [r for r in rows if r["kind"] == "quality agent"]
    qa = max(agents, key=lambda r: r["quality"] or 0) if agents else None
    overall = max(rows, key=lambda r: r["net"])
    summary.append((t, br, bd, qa, overall))

def cell_net(r):
    if not r: return '<td class="num">–</td>'
    style, cls = heat(r["net"])
    return (f'<td class="pick"><div class="who">{esc(label(r))}</div>'
            f'<div class="meta"><span class="v {cls}" style="{style}">{pct(r["net"])}</span> net, '
            f'{pct(r["gain"])} yield at dose {r["net_dose"]}</div></td>')

parts = []
parts.append(f"""<title>Hidden World, Seed {SEED}</title>
<link rel="preconnect" href="https://fonts.googleapis.com"><link rel="preconnect" href="https://fonts.gstatic.com" crossorigin>
<link rel="stylesheet" href="https://fonts.googleapis.com/css2?family=Barlow+Semi+Condensed:wght@500;600;700&family=IBM+Plex+Sans:wght@400;500;600&family=IBM+Plex+Mono:wght@400;500&display=swap">
<style>
/* Layout: a lab notebook for one map. Summary first, then the full heat map, then per-target detail. */
:root {{
  --bg: #eef1f1; --panel: #ffffff; --fg: #1c2326; --muted: #5d6a70; --rule: #d3dadc;
  --accent: #b8661c; --pos: #00845f; --neg: #c65300;
  --k0: #3d6f8f; --k1: #6b5a8e; --k2: #7a6a55; --k3: #b8661c; --k4: #2f7d6d; --k5: #9b3f5c; --k6: #4d6b2f;
  --display: "Barlow Semi Condensed", "Arial Narrow", system-ui, sans-serif;
  --body: "IBM Plex Sans", system-ui, -apple-system, sans-serif;
  --mono: "IBM Plex Mono", ui-monospace, Menlo, monospace;
}}
@media (prefers-color-scheme: dark) {{ :root:not([data-theme="light"]) {{
  --bg: #171c1e; --panel: #1f2629; --fg: #e2e7e8; --muted: #98a6ab; --rule: #33403f;
  --accent: #e0954a; --pos: #3fbf95; --neg: #f07a3a;
  --k0: #7fb0cf; --k1: #a998cc; --k2: #b8a88f; --k3: #e0954a; --k4: #6cc0ad; --k5: #d47a96; --k6: #96b86e; color-scheme: dark }} }}
:root[data-theme="dark"] {{
  --bg: #171c1e; --panel: #1f2629; --fg: #e2e7e8; --muted: #98a6ab; --rule: #33403f;
  --accent: #e0954a; --pos: #3fbf95; --neg: #f07a3a;
  --k0: #7fb0cf; --k1: #a998cc; --k2: #b8a88f; --k3: #e0954a; --k4: #6cc0ad; --k5: #d47a96; --k6: #96b86e; color-scheme: dark }}
body {{ background: var(--bg); color: var(--fg); font: 15px/1.55 var(--body); }}
.wrap {{ max-width: 1180px; margin: 0 auto; padding-inline: 16px; padding-block: 28px 64px; display: grid; gap: 34px; }}
header {{ display: grid; gap: 10px; }}
.eyebrow {{ font: 600 12px/1 var(--display); letter-spacing: .14em; text-transform: uppercase; color: var(--accent); }}
h1 {{ font: 700 clamp(30px, 5vw, 46px)/1.05 var(--display); margin: 0; text-wrap: balance; }}
h2 {{ font: 600 24px/1.2 var(--display); margin: 0 0 6px; text-wrap: balance; }}
p {{ margin: 0; max-width: 68ch; }}
.lede {{ color: var(--muted); }}
section {{ display: grid; gap: 12px; min-width: 0; }}
.scroll {{ overflow-x: auto; background: var(--panel); border: 1px solid var(--rule); border-radius: 6px; }}
table {{ border-collapse: collapse; width: 100%; font-variant-numeric: tabular-nums; }}
th, td {{ padding: 8px 10px; border-bottom: 1px solid var(--rule); text-align: left; vertical-align: top; }}
th {{ font: 600 12px/1.2 var(--display); letter-spacing: .06em; text-transform: uppercase; color: var(--muted); background: var(--panel); position: sticky; top: 0; }}
td.num {{ font-family: var(--mono); font-size: 13px; white-space: nowrap; }}
.tname {{ font-weight: 600; white-space: nowrap; }}
.tmeta {{ color: var(--muted); font: 12px/1.3 var(--mono); }}
.pick .who {{ font-weight: 500; }}
.pick .meta {{ color: var(--muted); font-size: 12.5px; }}
.v {{ font-family: var(--mono); font-weight: 500; padding: 1px 5px; border-radius: 3px; }}
.v.pos {{ background: color-mix(in srgb, var(--pos) calc(var(--h) * 38%), transparent); }}
.v.neg {{ background: color-mix(in srgb, var(--neg) calc(var(--h) * 38%), transparent); }}
.chip {{ display: inline-block; font: 600 11px/1.6 var(--display); letter-spacing: .05em; text-transform: uppercase; padding: 0 7px; border-radius: 3px; border: 1px solid currentColor; white-space: nowrap; }}
{"".join(f".k{i} {{ color: var(--k{i}); }}" for i in range(7))}
.legend {{ display: flex; flex-wrap: wrap; gap: 8px 14px; align-items: center; color: var(--muted); font-size: 13px; }}
.heat td, .heat th {{ padding: 4px 6px; text-align: center; font: 12px/1.2 var(--mono); }}
.heat th.rot {{ writing-mode: vertical-rl; transform: rotate(180deg); height: 120px; white-space: nowrap; text-align: left; font: 500 12px/1 var(--body); text-transform: none; letter-spacing: 0; color: var(--fg); }}
.heat td.c.pos {{ background: color-mix(in srgb, var(--pos) calc(var(--h) * 70%), transparent); }}
.heat td.c.neg {{ background: color-mix(in srgb, var(--neg) calc(var(--h) * 70%), transparent); }}
.heat td.rowh {{ text-align: left; font: 600 13px/1.2 var(--body); white-space: nowrap; position: sticky; left: 0; background: var(--panel); }}
details {{ background: var(--panel); border: 1px solid var(--rule); border-radius: 6px; }}
summary {{ cursor: pointer; padding: 10px 14px; display: flex; gap: 12px; align-items: baseline; flex-wrap: wrap; }}
summary:focus-visible {{ outline: 2px solid var(--accent); outline-offset: 2px; }}
summary .tname {{ font: 600 17px/1.2 var(--display); }}
details .scroll {{ border: 0; border-top: 1px solid var(--rule); border-radius: 0; }}
.chem td.c {{ min-width: 48px; }}
.note {{ color: var(--muted); font-size: 13px; }}
</style>
<div class="wrap">
<header>
  <div class="eyebrow">Empirical Science · answer key</div>
  <h1>Hidden world, map seed {d["seed"]}</h1>
  <p class="lede">What a long game on this map would uncover, read straight from the generator with the rules as of version 0.45. Net is the yield gain minus the dose's ore over the batch's ore: what dosing saves per product. Doses are units per batch (fluids per 10 units).</p>
  <div class="legend">{"".join(chip(k) for k in KIND_ORDER)}</div>
</header>
""".replace("·", "·"))
# remove middot per user preference
parts[-1] = parts[-1].replace("Empirical Science · answer key", "Empirical Science answer key")

# Summary table
rows_html = []
for t, br, bd, qa, overall in summary:
    q = f'<td class="num">{pct(qa["quality"], False)} <span class="tmeta">{esc(nice(qa["name"]))} x{qa["gain_dose"]}</span></td>' if qa else '<td class="num">–</td>'
    routes = ", ".join(f'{esc(names.get(("es-route", t["key"] + "-" + k), k))} {pct(v)}' for k, v in t["routes"].items()) or "–"
    win = overall["kind"]
    rows_html.append(f'<tr><td><div class="tname">{esc(nice(t["result"]))}</div><div class="tmeta">resp. {t["responsiveness"]:.2f}, batch {t["batch"]} ({t["batch_ore"]:.0f} ore)</div></td>'
                     f'{cell_net(br)}{cell_net(bd)}<td>{chip(win)}</td>{q}<td class="pick"><div class="meta">{routes}</div></td></tr>')
parts.append(f"""<section><h2>Best choice per target</h2>
<p class="lede">Raw: tier 1, tier 2 and residues. Deep: activated catalysts, premixes and catalyst premixes. Winner: the kind of the single best net choice.</p>
<div class="scroll"><table><thead><tr><th>Target</th><th>Best raw (by net)</th><th>Best deep (by net)</th><th>Winner</th><th>Best quality chance</th><th>Alternative recipes</th></tr></thead>
<tbody>{''.join(rows_html)}</tbody></table></div></section>""")

# Heat map: base additives (not premixes, not agents)
base = [r for r in targets[0]["rows"] if r["kind"] in ("tier 1", "tier 2", "residue", "activated catalyst")]
base_names = [r["name"] for r in base]
head = "".join(f'<th class="rot">{esc(label(r))}</th>' for r in base)
body = []
for t in targets:
    by = {r["name"]: r for r in t["rows"]}
    cells = []
    for n in base_names:
        r = by[n]
        style, cls = heat(r["gain"])
        tip = f'{label(r)} on {nice(t["result"])}: yield {pct(r["gain"])} at {r["gain_dose"]}; net {pct(r["net"])} at {r["net_dose"]}; speed {pct(r["speed"])}; cleanliness {pct(r["pollution"])}; efficiency {pct(r.get("efficiency", 0))}'
        cells.append(f'<td class="c {cls}" style="{style}" title="{esc(tip)}">{r["gain"]*100:.0f}</td>')
    body.append(f'<tr><td class="rowh">{esc(nice(t["result"]))}</td>{"".join(cells)}</tr>')
parts.append(f"""<section><h2>Yield at the best dose, every additive</h2>
<p class="lede">Percent of a normal batch, raw additives and activated catalysts. Hover a cell for net, speed and cleanliness.</p>
<div class="scroll"><table class="heat"><thead><tr><th></th>{head}</tr></thead><tbody>{''.join(body)}</tbody></table></div></section>""")

# Detail per target
det = []
for t in targets:
    rows = sorted(t["rows"], key=lambda r: -r["net"])[:15]
    trs = []
    for r in rows:
        s1, c1 = heat(r["net"]); s2, c2 = heat(r["gain"])
        q = pct(r["quality"], False) if r.get("quality") else "–"
        fe = pct(r["full_early"]) if r.get("full_early") is not None else "–"
        fl = pct(r["full_late"]) if r.get("full_late") is not None else "–"
        trs.append(f'<tr><td>{esc(label(r))}</td><td>{chip(r["kind"])}</td><td class="num"><span class="v {c1}" style="{s1}">{pct(r["net"])}</span> @{r["net_dose"]}</td>'
                   f'<td class="num"><span class="v {c2}" style="{s2}">{pct(r["gain"])}</span> @{r["gain_dose"]}</td><td class="num">{pct(r["speed"])}</td><td class="num">{pct(r["pollution"])}</td>'
                   f'<td class="num">{pct(r.get("efficiency", 0))}</td><td class="num">{fe}</td><td class="num">{fl}</td><td class="num">{q}</td></tr>')
    det.append(f"""<details><summary><span class="tname">{esc(nice(t["result"]))}</span><span class="tmeta">responsiveness {t["responsiveness"]:.2f}, batch ore {t["batch_ore"]:.0f}</span></summary>
<div class="scroll"><table><thead><tr><th>Additive</th><th>Kind</th><th>Net (dose)</th><th>Yield (dose)</th><th>Speed</th><th>Cleanliness</th><th>Efficiency</th><th>Full cost, early</th><th>Full cost, late</th><th>Quality</th></tr></thead><tbody>{''.join(trs)}</tbody></table></div></details>""")
parts.append(f"""<section><h2>Top fifteen per target</h2><p class="lede">Every kind, ranked by net. Speed, cleanliness and efficiency at the yield's best dose. Full cost: the share of the product's whole cost (ore, machine time, power, pollution) the best dose saves, at early and late prices.</p>{''.join(det)}</section>""")

# Chemistry
fams = [f for f in d["chemistry"] if f not in ("catalyst", "residue")]
ch = "".join(f'<th>{esc(f)}</th>' for f in fams)
crow = []
for f1 in fams:
    cells = []
    for f2 in fams:
        v = d["chemistry"][f1][f2]
        if f1 == f2: cells.append('<td class="num">same</td>'); continue
        style, cls = heat(v, 0.25)
        cells.append(f'<td class="num c {cls}" style="{style}">{v*100:+.0f}</td>')
    crow.append(f'<tr><td class="rowh">{esc(f1)}</td>{"".join(cells)}</tr>')
parts.append(f"""<section><h2>Family chemistry</h2>
<p class="lede">Synergy (positive) or antagonism between two fully present additives of these families, in percent of a batch. Residues and activated catalysts mix as their family.</p>
<div class="scroll"><table class="heat chem"><thead><tr><th></th>{ch}</tr></thead><tbody>{''.join(crow)}</tbody></table></div>
<p class="note">Generated from the mod's own generator (scripts/ground_truth.sh {SEED}); never shown in game.</p></section></div>""")
out = os.path.join(os.path.dirname(__file__), "groundtruth", "index.html")
open(out, "w").write("\n".join(parts))
print(out, os.path.getsize(out))
