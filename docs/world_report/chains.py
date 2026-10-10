"""Ore saved along recipe chains when every stage is dosed. Usage: chains.py <ground truth json> <data dump json> <out json>"""
import json, sys, re
gt=json.load(open(sys.argv[1])); dump=json.load(open(sys.argv[2]))
T={t["key"]:t for t in gt["targets"]}
RES={t["result"]:t["key"] for t in gt["targets"]}
recipes={}
for n,r in dump["recipe"].items():
    for p in r.get("results") or []:
        if p["name"]==n: recipes[n]=r
RAW={"iron-ore","copper-ore","stone","coal","wood"}
FW=0.1
memo={}
def raw(i):
    if i in RAW: return 1.0
    if i in memo: return memo[i]
    if i in dump["fluid"]: return FW
    if i not in recipes: return 1.0
    memo[i]=1.0; r=recipes[i]; out=next(p["amount"] for p in r["results"] if p["name"]==i)
    c=sum(raw(x["name"])*x["amount"] for x in r["ingredients"])/out; memo[i]=c; return c
RAWKINDS={"early","tier 1","tier 2"}
def best_net(key, kinds=None):
    rows=[r for r in T[key]["rows"] if r.get("best",{}).get("net") and (kinds is None or r["kind"] in kinds)]
    b=max(rows,key=lambda r:r["best"]["net"]["v"]); return b["name"], b["best"]["net"]["d"], b["best"]["net"]["v"]
def net_of(key, name):
    for r in T[key]["rows"]:
        if r["name"]==name and r.get("best",{}).get("net"): return r["best"]["net"]["v"], r["best"]["net"]["d"]
    return None
def eff(item, policy, depth=0):
    # ore per unit of item when each target recipe in the chain is dosed by policy(key) -> net or None
    if item in RAW or item in dump["fluid"] or item not in recipes: return raw(item)
    r=recipes[item]; out=next(p["amount"] for p in r["results"] if p["name"]==item)
    c=sum(eff(x["name"],policy,depth+1)*x["amount"] for x in r["ingredients"])/out
    key=RES.get(item); n=policy(key) if key else None
    return c*(1-n) if n is not None else c
finals=["red","green","engine","blue","advanced-circuit","purple","yellow","processing-unit","lds","electric-engine","robot-frame"]
out=[]
for f in finals:
    item=T[f]["result"]; base=raw(item)
    only=best_net(f,RAWKINDS); s_only=1-eff(item, lambda k: only[2] if k==f else None)/base
    chain=1-eff(item, lambda k: max(0,best_net(k,RAWKINDS)[2]) if k else None)/base
    wood=1-eff(item, lambda k: max(0,(net_of(k,"wood") or (0,))[0]) if k else None)/base
    late=1-eff(item, lambda k: max(0,best_net(k)[2]) if k else None)/base
    # which stages participate
    stages=[]
    def walk(i):
        if i in recipes and i not in RAW:
            k=RES.get(i)
            if k and k not in [s[0] for s in stages]:
                bn=best_net(k,RAWKINDS); stages.append((k,bn[0],bn[1],round(100*bn[2],1)))
            for x in recipes[i]["ingredients"]: walk(x["name"])
    walk(item)
    out.append({"final":f,"result":item,"ore":round(base,1),"single":round(100*s_only,1),"single_add":only[0],"single_dose":only[1],
      "chain":round(100*chain,1),"wood":round(100*wood,1),"late":round(100*late,1),"stages":stages})
    print(f, base, "single", round(100*s_only,1), only[0], "| chain raw", round(100*chain,1), "| wood-only", round(100*wood,1), "| all kinds", round(100*late,1), "| stages", stages)
json.dump(out,open(sys.argv[3],"w"))
