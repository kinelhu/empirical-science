"""The field report's data: one seed's hidden world (ground truth and mixtures) condensed. Usage: build_data.py <ground truth dir> <work dir>; run from the repository root."""
import json, re, sys
GT, S = sys.argv[1], sys.argv[2]
d=json.load(open(GT+"/es-groundtruth.json")); P=json.load(open(GT+"/es-groundtruth-pairs.json"))
chains=json.load(open(S+"/chains.json"))
T={t["key"]:t for t in d["targets"]}
loc=open("empirical-science/locale/en/locale.cfg").read()
ES={m.group(1):m.group(2) for m in re.finditer(r"^(es-(?:spent|refined)-[a-z-]+)=(.+)$",loc,re.M)}
SPECIAL={"iron-gear-wheel":"Iron gear wheel","automation-science-pack":"Automation science","logistic-science-pack":"Logistic science",
 "chemical-science-pack":"Chemical science","production-science-pack":"Production science","utility-science-pack":"Utility science",
 "low-density-structure":"Low density structure","flying-robot-frame":"Flying robot frame","electric-engine-unit":"Electric engine",
 "engine-unit":"Engine","space-science-pack":"Space science","promethium-science-pack":"Promethium science",
 "agricultural-science-pack":"Agricultural science","metallurgic-science-pack":"Metallurgic science","uranium-235":"Uranium-235"}
def nice(n):
    if n in ES: return ES[n]
    if n in SPECIAL: return SPECIAL[n]
    if n.startswith("es-premix-"):
        body=n[len("es-premix-"):]
        # split into two known additive names
        names=sorted({r["name"] for t in T.values() for r in t["rows"] if not r["name"].startswith("es-premix-")},key=len,reverse=True)
        for a in names:
            if body.startswith(a+"-") and body[len(a)+1:] in names:
                return nice(a)+" + "+nice(body[len(a)+1:])
        return body
    s=n.replace("-"," "); return s[:1].upper()+s[1:]
def item_label(key): return nice(T[key]["result"])
def mixlabel(mix): return " + ".join(f"{nice(k)} ×{v}" for k,v in sorted(mix.items()))
RAW={"early","tier 1","tier 2","living"}  # raw additives (0.70: the early set is its own kind; living ones
# count at their best ripeness, below)
# A living additive's net ore at its best ripeness (answer_key net_state), where a player would dose it.
for _t in T.values():
    for _x in _t["rows"]:
        if _x.get("living") and _x.get("net_state") is not None and _x.get("best", {}).get("net"):
            if _x["net_state"] > _x["best"]["net"]["v"]:
                _x["best"]["net"] = {"v": _x["net_state"], "d": _x.get("net_state_d") or _x["best"]["net"]["d"]}
def best(key,r,kinds=None,n=1):
    rows=[x for x in T[key]["rows"] if x.get("best",{}).get(r) and (kinds is None or x["kind"] in kinds)]
    rows.sort(key=lambda x:-x["best"][r]["v"]); return rows[:n]
def at_dose(x,dd):
    bd=x["by_dose"]
    return bd[str(dd)] if isinstance(bd,dict) else bd[dd-1]
targets=[]
for t in d["targets"]:
    k=t["key"]; early=best(k,"net",RAW)[0]; top=best(k,"yield")[0]
    op=best(k,"net",{"early"})  # the early set's best (0.70: wood waits for Tree seeding)
    opener=op and {"add":nice(op[0]["name"]),"dose":op[0]["best"]["net"]["d"],"net":round(100*op[0]["best"]["net"]["v"],1)}
    st=[x for x in t["rows"] if x.get("at_state")]
    hot=max(st,key=lambda x:x["at_state"]) if st else None
    pr=P.get(k,{}).get("yield",[])
    targets.append({"key":k,"name":item_label(k),"resp":round(t["responsiveness"],2),"batch":t["batch"],
      "opener":opener,
      "early":{"add":nice(early["name"]),"dose":early["best"]["net"]["d"],"net":round(100*early["best"]["net"]["v"],1),"yield":round(100*at_dose(early,early["best"]["net"]["d"])["yield"],1)},
      "top":{"add":nice(top["name"]),"dose":top["best"]["yield"]["d"],"yield":round(100*top["best"]["yield"]["v"],1),"shape":top.get("shape")},
      "state":hot and {"add":nice(hot["name"]),"at":round(hot["state"],0) if not hot.get("living") else round(100*hot["state"]),"living":bool(hot.get("living")),"yield":round(100*hot["at_state"],1),"usual":round(100*hot["gain"],1)},
      "pair":pr and {"mix":mixlabel(pr[0]["mix"]),"v":round(100*pr[0]["v"],1),"alone":round(100*pr[0]["alone"],1)}})
fams=["carbon","mineral","metal","organic","sulfur","polymer","oil","aqueous","biological","catalyst","residue"]
chem=[[round(d["chemistry"][a][b],2) for b in fams] for a in fams]
# side effects: leaders on red, and (0.70, side effects by class) the speed and cleanliness leaders on one
# target of each process class
def leaders(r,k="red",n=3): return [{"add":nice(x["name"]),"dose":x["best"][r]["d"],"v":round(100*x["best"][r]["v"])} for x in best(k,r,None,n)]
side={"speed":leaders("speed"),"cleanliness":leaders("cleanliness"),"efficiency":leaders("efficiency"),
      "freshness":leaders("freshness","pentapod-egg"),"quality":leaders("quality","iron-plate"),
      "by_class":[{"class":c,"target":item_label(k),"speed":leaders("speed",k,1)[0],"cleanliness":leaders("cleanliness",k,1)[0]}
                  for c,k in (("metalwork","gear"),("electronics","circuit"),("chemistry","plastic")) if k in T]}
routes=[{"target":item_label(k),"routes":{rk:round(100*v,1) for rk,v in T[k]["routes"].items()}} for k in T if T[k]["routes"]]
# findings
th=open("empirical-science/scripts/dossier_standard.lua").read()
def tbl(name):
    blk=re.search(name+r" = \{(.*?)\n  \}",th,re.S).group(1)
    return {m.group(1):float(m.group(2)) for m in re.finditer(r'\["([a-z-]+)"\] = ([0-9.]+)',blk)}
exc, quota = tbl("exceptional"), tbl("quota")
# Standard bars per planet (0.70): ["nauvis"] = {["yield"] = 0.0960, ...}
stdp={m.group(1):{n.group(1):float(n.group(2)) for n in re.finditer(r'\["([a-z-]+)"\] = ([0-9.]+)',m.group(2))}
      for m in re.finditer(r'\["([a-z]+)"\] = \{([^}]*)\}',re.search(r"standard = \{.*?\n(.*?)\n  \}",th,re.S).group(1))}
std=stdp["nauvis"]
planets={m.group(1):re.findall(r'"([a-z-]+)"',m.group(2)) for m in re.finditer(r'\["([a-z]+)"\] = \{([^}]*)\}',re.search(r"planets = \{(.*?)\n  \}",th,re.S).group(1))}
PL=[]
for pl in ["nauvis","vulcanus","fulgora","gleba","aquilo","space"]:
    ks=[k for k in planets.get(pl,[]) if k in T]
    q=[]
    for k in ks:
        sp=stdp.get(pl,std)
        ok=any(x["best"][r]["v"]>=sp[r]+0.03 for r in sp for x in T[k]["rows"] if x.get("best",{}).get(r))
        if ok: q.append(item_label(k))
    PL.append({"planet":pl,"targets":len(ks),"quota":int(quota.get(pl,0)),"reachable":len(q)})
majors={}
for r,bar in exc.items():
    found=[]
    for k in T:
        for x in T[k]["rows"]:
            b=x.get("best",{}).get(r)
            if b and b["v"]>=bar: found.append((b["v"],item_label(k),nice(x["name"]),b["d"]))
    found.sort(reverse=True)
    majors[r]={"bar":round(100*bar,1),"count":len(found),"top":[{"v":round(100*v,1),"target":t,"add":a,"dose":dd} for v,t,a,dd in found[:3]]}
red_states=sorted([{"add":nice(x["name"]),"at":round(x["state"]),"yield":round(100*x["at_state"],1),"usual":round(100*x["gain"],1)}
   for x in T["red"]["rows"] if x.get("at_state") and not x.get("living")], key=lambda s:-s["yield"])
hottest=max([s for s in red_states if s["yield"]>=50] or red_states,key=lambda s:s["at"])
data={"nauvis":[k for k in planets.get("nauvis",[]) if k in T],"red_states":red_states[:6],"hottest":hottest,"seed":d["seed"],"targets":targets,"fams":fams,"chem":chem,"chains":chains,"side":side,"routes":routes,
      "findings":{"std":{k:round(100*v,1) for k,v in std.items()},"planets":PL,"majors":majors,"needed":4}}
for c in data["chains"]:
    c["name"]=nice(c["result"]); c["stages"]=[{"target":item_label(s[0]),"add":nice(s[1]),"dose":s[2],"net":s[3]} for s in c["stages"]]
data["bio"]=[nice(x["name"]) for x in T["red"]["rows"] if x.get("living")]
json.dump(data,open(S+"/report.json","w"))
print(json.dumps(data["findings"])[:1500]); print(len(json.dumps(data)))
