"""Writes the seed's field report page from report.json and the robot's run log (scripts/world_report.sh).
Usage: build_page.py <work dir> <output html>"""
import json, html, sys, os
WORK, OUT = sys.argv[1], sys.argv[2]
HERE = os.path.dirname(os.path.abspath(__file__))
D=json.load(open(os.path.join(WORK, "report.json")))
T={t["key"]:t for t in D["targets"]}
C={c["final"]:c for c in D["chains"]}
F=D["fams"]; chem=D["chem"]
def ch(a,b): return chem[F.index(a)][F.index(b)]
def p(x): return f"{x:+.1f}%"
def e(s): return html.escape(str(s))
red, gear, steel, green, batt = T["red"], T["gear"], T["steel"], T["green"], T["battery"]
side=D["side"]; fz=D["findings"]
import re as _re
log=open(os.path.join(WORK, "run.txt")).read()
def grab(pat, n=1): return _re.search(pat, log).group(n)
SCREEN, CONFIRM = grab(r"screen done at ([0-9.]+) min"), grab(r"confirm done at ([0-9.]+) min")
CONF = _re.search(r"confirm done .*? ([+-][0-9.]+)% \[([+-][0-9.]+), ([+-][0-9.]+)\]", log)
RESEARCHED, TOTAL = grab(r"researched at ([0-9.]+) min"), grab(r"took under an hour of game time\s+([0-9.]+) min")
FACTORY = grab(r"factory products per craft ([+-][0-9.]+)%")
SAMPLES, PACKS = grab(r"samples analysed (\d+), packs used (\d+)"), grab(r"samples analysed (\d+), packs used (\d+)", 2)
R = {x["target"]: x["routes"] for x in D["routes"]}
def pretty(n): return n.replace("-", " ").capitalize()
SC = _re.search(r"best cell (\S+) x(\d+)", log); CF = _re.search(r"confirm done at [0-9.]+ min: best (\S+) x(\d+)", log)
AD = _re.search(r"adopted (\S+) x(\d+): true gain ([+-][0-9.]+)% \((\d+)% of the best possible\)", log)
HOT = D["hottest"]
# measured run (robot playthrough, seed 12345)
RUN=[("0 min","A new game: one bench row, a station, red packs, nothing staged.",True),
     (f"{SCREEN} min",f"Screening done: every early additive at doses 2, 5 and 8 on automation science. Best cell: {pretty(SC.group(1))} ×{SC.group(2)}.",True),
     (f"{RESEARCHED} min","The research data those samples earned buys Process routes; two route trials open.",True),
     (f"{CONFIRM} min",f"Confirmation done: {e(pretty(CF.group(1)))} ×{CF.group(2)} measures {CONF.group(1)}%, 95% range {CONF.group(2)}% to {CONF.group(3)}%, against its control. {SAMPLES} samples analysed, {PACKS} packs spent.",True),
     (f"{TOTAL} min",f"{e(pretty(AD.group(1)))} ×{AD.group(2)} adopted on automation science. The factory makes {FACTORY}% products per craft; the true gain is {AD.group(3)}%, {AD.group(4)}% of the best an early additive can do here.",True)]
proj=[("Process routes",f"Lean advanced circuits {p(R['Advanced circuit']['lean'])}, brick-lined engines {p(R['Engine']['brick-lined'])}, carburised steel {p(R['Steel plate']['carburised'])}. Forged gears ({p(R['Iron gear wheel']['forged'])}) and ceramic circuits ({p(R['Electronic circuit']['ceramic'])}) cost yield."),
      ("Mixtures",f"Activated carbon with activated silica: {p(red['pair']['v'])} on automation science against {p(red['pair']['alone'])} for the better alone."),
      ("Thermal studies","Premixes have a best temperature, and on this seed most of them lie beyond Nauvis's 15 to 90 °C."),
      ("Vulcanus and Aquilo",f"The pressure heater and chilled twins reach the extremes: on automation science, {e(red['state']['add'])} peaks at {red['state']['at']:.0f} °C ({p(red['state']['yield'])} against {p(red['state']['usual'])} at its usual temperature)."),
      ("Fulgora",f"{e(side['quality'][0]['add'])} is the strongest quality agent: {side['quality'][0]['v']}% of iron plates come out a tier up at dose {side['quality'][0]['dose']}."),
      ("Gleba",f"{e(side['freshness'][0]['add'])} restores {side['freshness'][0]['v']}% of inherited spoilage on pentapod eggs."),
      ("Findings",f"Every planet's quota is within reach on this seed; the major findings need any {fz['needed']} of 6 effects past their bars.")]
tl="".join(f'<li><div class="when">{e(w)}<span class="tag meas">Measured</span></div>{e(t)}</li>' for w,t,_ in RUN)
tl+="".join(f'<li class="proj"><div class="when">{e(w)}<span class="tag proj">Projected</span></div>{t}</li>' for w,t in proj)
# Hypotheses, each derived from this seed's data (nothing in them is written for one seed).
from collections import Counter
NAUV=[k for k in D["nauvis"] if k in T]
# The opener: the early set only (coal, stone, stone brick, copper cable; wood waits for Tree seeding).
openers=Counter(T[k]["opener"]["add"] for k in NAUV if T[k]["opener"] and T[k]["opener"]["net"]>0)
OPEN, OPEN_N = openers.most_common(1)[0]
open_on=[k for k in NAUV if T[k]["opener"] and T[k]["opener"]["add"]==OPEN and T[k]["opener"]["net"]>0]
h1=("H1", f"Open with {OPEN}.",
 f"Among the early additives, {e(OPEN)} is the best net-ore dose on {OPEN_N} of Nauvis's {len(NAUV)} targets: " + ", ".join(f"{e(T[k]['name'])} ({p(T[k]['opener']['net'])})" for k in open_on[:6]) + ". One hopper chemistry covers much of the early factory.",
 "Early additives: coal, stone, stone brick and copper cable. Net ore: yield minus the ore of the dose, at the best dose for net ore.")
iron_skip = T["iron-plate"]["early"]["net"] <= 0 if "iron-plate" in T else False
bigs=sorted(D["chains"], key=lambda c: -(c["chain"]-c["single"]))[:3]
h2=("H2","Dose the chain, not the last step.",
 "Gains compound along a recipe chain. " + "; ".join(f"{e(c['name'])}: {p(c['single'])} for the final step alone, {p(c['chain'])} with every stage dosed by its best raw additive" for c in bigs) + "." + (" Iron plates are the stage to leave alone: no raw additive pays there." if iron_skip else ""),
 "Ore per product from the game's recipes; each dosed stage multiplies its inputs' ore by (1 − its net saving).")
RAWF=["carbon","mineral","metal","organic","sulfur","polymer","oil","aqueous","biological"]
pairs_f=sorted([(ch(a,b),a,b) for i,a in enumerate(RAWF) for b in RAWF[i+1:]], reverse=True)
(v1,a1,b1),(v2,a2,b2)=pairs_f[0],pairs_f[1]
foe=min(RAWF, key=lambda f: ch(f,a1)+ch(f,b1) if f not in (a1,b1) else 9)
h3=("H3", f"Mix {a1} with {b1}; keep {foe} away from them.",
 f"The strongest family alliance on this seed is {a1} and {b1} ({v1:+.2f}), then {a2} and {b2} ({v2:+.2f}). {foe.capitalize()} works against both ({ch(foe,a1):+.2f} and {ch(foe,b1):+.2f}). The best measured mixture on automation science is {e(red['pair']['mix'])}: {p(red['pair']['v'])} against {p(red['pair']['alone'])} for the better alone.",
 "Pair strength scales a mixture's synergy (+) or antagonism (−) at full presence; mixtures measured at each member's best dose.")
parts=Counter(x.strip() for t in D["targets"] for x in t["top"]["add"].split("+"))
ANCHOR, AN = parts.most_common(1)[0]
anch=[t for t in sorted(D["targets"], key=lambda t:-t["top"]["yield"]) if ANCHOR in t["top"]["add"]][:3]
h4=("H4", f"{ANCHOR} anchors the top yields.",
 f"{e(ANCHOR)} is part of the strongest yield on {AN} of {len(D['targets'])} targets: " + ", ".join(f"{e(t['top']['add'])} {p(t['top']['yield'])} on {e(t['name'])}" for t in anch) + ". Whatever makes it is this seed's late-game core.",
 "Yield at the best dose, at a premix's usual temperature.")
cold=min(D["red_states"], key=lambda s:s["at"])
h5=("H5","Temperature is the frontier.",
 f"On automation science, {e(red['state']['add'])} gives {p(red['state']['usual'])} at its usual temperature and {p(red['state']['yield'])} at {red['state']['at']:.0f} °C; {e(HOT['add'])} peaks at {HOT['at']} °C ({p(HOT['yield'])} against {p(HOT['usual'])}). Optima below freezing need Aquilo's chilling, above about 100 °C Vulcanus's pressure heater: plan to ship premixes between planets.",
 "Best temperature: the premix's hidden optimum; yield there at its best dose.")
BC=side["by_class"]
same_speed=len({c["speed"]["add"] for c in BC})==1
h6=("H6", "One speed additive carries across the factory." if same_speed else "Side effects follow the process.",
 ("Side effects lean by process class, but on this map one additive leads speed on every class: " if same_speed else
  "Side effects lean by process class, so the fastest additive depends on what the machine makes: ")
 + "; ".join(f"{e(c['speed']['add'])} on {e(c['target'])} ({p(c['speed']['v'])} speed, {c['class']})" for c in BC)
 + ". Cleanest: " + "; ".join(f"{e(c['cleanliness']['add'])} on {e(c['target'])} ({p(c['cleanliness']['v'])})" for c in BC)
 + ". A speed additive belongs on the slowest stage of a chain, and which additive that is depends on the stage's process.",
 "Speed and cleanliness at the full dose on one target of each process class.")
bio=set(D.get("bio",[]))
bio_wins=[t for t in D["targets"] if t["early"]["add"] in bio and t["early"]["net"]>0]
bio_pairs=[t for t in D["targets"] if t["pair"] and any(b in t["pair"]["mix"] for b in bio)]
best_bio_pair=max(bio_pairs, key=lambda t:t["pair"]["v"]) if bio_pairs else None
h7=("H7","Gleba's biologicals are cheap net winners." if bio_wins else "Gleba's biologicals pay in mixtures.",
 (f"A biological additive is the best net-ore dose on {len(bio_wins)} targets" if bio_wins else "No biological additive is the best net-ore dose alone on this map") + (": " + ", ".join(f"{e(t['early']['add'])} on {e(t['name'])} ({p(t['early']['net'])})" for t in sorted(bio_wins,key=lambda t:-t['early']['net'])[:3]) if bio_wins else "") + "." + (f" The strongest mixture with one: {e(best_bio_pair['pair']['mix'])}, {p(best_bio_pair['pair']['v'])} on {e(best_bio_pair['name'])}." if best_bio_pair else "") + " They spoil: fresh, or at their own ripeness.",
 "Net ore for raw additives; mixture yields at each member's best dose.") if bio else None
h8=("H8", f"Start quality at the furnace, with {side['quality'][0]['add'].lower()}.",
 f"{e(side['quality'][0]['add'])} ×{side['quality'][0]['dose']} upgrades {side['quality'][0]['v']}% of iron plates, ahead of {e(side['quality'][1]['add'])} ({side['quality'][1]['v']}%) and {e(side['quality'][2]['add'])} ({side['quality'][2]['v']}%). A dosed furnace, its uncommon plates sorted into a gear line dosed again, starts a quality cascade before the first recycler.",
 "Upgrade chance per product at the agent's best dose.")
H=[h for h in (h1,h2,h3,h4,h5,h6,h7,h8) if h]
hy="".join(f'<div class="hyp"><div class="id">{i}</div><div><h3>{e(t)}</h3><p>{body}</p><div class="ev">{e(ev)}</div></div></div>' for i,t,body,ev in H)
rows="".join(f"<tr><td>{e(t['name'])}</td><td class='r num'>{t['resp']:.2f}</td><td>{e(t['early']['add'])} ×{t['early']['dose']} <span class='num {'gain' if t['early']['net']>0 else 'loss'}'>{p(t['early']['net'])}</span></td><td>{e(t['top']['add'])} ×{t['top']['dose']} <span class='num gain'>{p(t['top']['yield'])}</span></td><td>"+(f"{e(t['state']['add'])} at {t['state']['at']:.0f}{'%' if t['state']['living'] else ' °C'} <span class='num gain'>{p(t['state']['yield'])}</span>" if t['state'] else "–")+"</td><td>"+(f"{e(t['pair']['mix'])} <span class='num gain'>{p(t['pair']['v'])}</span>" if t['pair'] else "–")+"</td></tr>" for t in sorted(D["targets"],key=lambda t:-t["resp"]))
std=fz["std"]
plan="".join(f"<tr><td>{'Space platforms' if x['planet']=='space' else x['planet'].capitalize()}</td><td class='r num'>{x['targets']}</td><td class='r num'>{x['quota']}</td><td class='r num'>{x['reachable']}</td></tr>" for x in fz["planets"])
maj="".join(f"<tr><td>{k.capitalize() if k!='quality' else 'Quality chance'}</td><td class='r num'>{v['bar']:+.1f}%</td><td class='r num'>{v['count']}</td><td>{e(v['top'][0]['add'])} on {e(v['top'][0]['target'])} <span class='num gain'>{v['top'][0]['v']:+.1f}%</span></td></tr>" for k,v in fz["majors"].items() if v["top"])
body=f'''
<div class="wrap">
<div class="eyebrow">Empirical Science · hidden world, map seed {D['seed']} · world strength standard</div>
<h1>Seed {D['seed']} Field Report</h1>
<p class="lede">What a competent scientist-engineer would find on stepping into this map: how a first run unfolds, what the hidden world looks like, and where the leverage is. Everything here is the map's truth, which a player only learns through experiments.</p>
<dl class="facts">
<div><dt>Targets</dt><dd class="num">{len(D['targets'])}</dd></div>
<div><dt>First discovery</dt><dd>{e(pretty(AD.group(1)))} ×{AD.group(2)}, automation science</dd></div>
<div><dt>Found in</dt><dd class="num">{CONFIRM} game-min</dd></div>
<div><dt>Best early lever</dt><dd>Dose whole chains</dd></div>
</dl>

<h2>A typical run</h2>
<p>The first entries come from the mod's robot playthrough on this seed: it screens, confirms and adopts like a careful player, using only what the station shows. The later entries are projected from this world's values, in the order the mod's technologies open them.</p>
<ol class="timeline">{tl}</ol>

<h2>The world at a glance</h2>
<p>Responsiveness scales every effect on a target: a value above 1 means additives move it more than usual. Simple products (gears, plates) respond least; science packs and Space Age products most.</p>
<div class="figure"><svg id="resp" role="img" aria-label="Responsiveness by target"></svg>
<div class="caption">Responsiveness per target, sorted. The line marks 1.0.</div></div>
<p>Families interact when mixed. The table shows each pair's strength: bluish green reinforces, vermillion antagonises.</p>
<div class="figure scroll"><svg id="chem" role="img" aria-label="Family pair strengths" style="min-width:560px"></svg>
<div class="caption">Pair strength between additive families (−0.25 to +0.25), symmetric.</div></div>

<h2>Leverage along recipe chains</h2>
<p>A dosed stage multiplies the ore of everything that flows into it. The bars compare dosing only the final product, dosing every stage of its chain with the best raw additive, and dosing every stage with the best additive of any kind.</p>
<div class="figure"><svg id="chains" role="img" aria-label="Ore saved by dosing strategy"></svg>
<div class="legend"><span><i style="background:var(--muted)"></i>Final step only</span><span><i style="background:var(--accent)"></i>Whole chain, raw additives</span><span><i style="background:var(--gain)"></i>Whole chain, any additive</span></div>
<div class="caption">Ore saved per product, at each stage's best dose for net ore (the dose's own ore paid).</div></div>

<h2>Hypotheses</h2>
<p>Read from the additive profiles as an engineer would read assay results: each claim names the numbers behind it, and each is something a player could set out to prove on this map.</p>
<div class="hyps">{hy}</div>

<h2>Target ledger</h2>
<p>Per target, sorted by responsiveness: the best raw additive by net ore (wood and oil-era additives included), the strongest yield of any kind, the best result at a premix's own temperature or a biological additive's ripeness, and the best two-additive mixture.</p>
<div class="figure scroll"><table><thead><tr><th>Target</th><th class="r">Resp.</th><th>Best raw dose (net ore)</th><th>Strongest yield</th><th>At its best state</th><th>Best pair</th></tr></thead><tbody>{rows}</tbody></table></div>

<h2>Findings on this seed</h2>
<p>A finding needs its effect proven above the bar (the lower end of the 95% range, so a true effect just at the bar is out of reach) and production with that dose. Each planet has its own finding bars; Nauvis's at standard strength: yield {std['yield']:+.1f}%, speed {std['speed']:+.1f}%, cleanliness {std['cleanliness']:+.1f}%, efficiency {std['efficiency']:+.1f}%.</p>
<div class="two">
<div class="figure scroll"><table style="min-width:0"><thead><tr><th>Planet</th><th class="r">Targets</th><th class="r">Quota</th><th class="r">With a finding</th></tr></thead><tbody>{plan}</tbody></table>
<div class="caption">Targets with some dose at least 3 points past a finding bar.</div></div>
<div class="figure scroll"><table style="min-width:480px"><thead><tr><th>Major</th><th class="r">Bar</th><th class="r">Doses past it</th><th>Strongest</th></tr></thead><tbody>{maj}</tbody></table>
<div class="caption">Any {fz['needed']} of the 6 complete the major findings.</div></div>
</div>

<h2>Method and limits</h2>
<p>The hidden world comes from the mod's own generator for this seed (the answer key's export), the run from its robot playthrough. Chain savings use the game's recipes and the balance model's ore costs, with each stage dosed at its best dose for net ore; they ignore machine time and power. Mixtures are measured on the true world, each member at its own best dose for the effect, among each target's eight best single additives. Temperatures and ripeness use each additive's hidden optimum; a player has to find those through trials, and the proof a finding needs means the true value must clear its bar with room.</p>
</div>
<script>
const DATA = {json.dumps(D)};
</script>
'''
js=open(os.path.join(HERE, "page_js.js")).read()
head=open(os.path.join(HERE, "page_head.html")).read().replace("Seed 12345 Field Report", f"Seed {D['seed']} Field Report")
open(OUT,"w").write(head+body+"<script>"+js+"</script>")
print("written", len(body))
