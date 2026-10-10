-- The hidden, per-map truth. Effects follow from hidden traits, so findings generalize:
-- additives of one family resemble each other, a derived item resembles its parent, and an
-- additive's affinity for a process class applies to every recipe of that class. The shape of an
-- additive's dose-response curve is a trait too, shared within a family more often than not.
local shared = require("shared")

local truth = {}

local function normal(rng)
  return math.sqrt(-2 * math.log(1 - rng())) * math.cos(2 * math.pi * rng())
end
truth.normal = normal

local function clamp(x, lo, hi) return math.max(lo, math.min(hi, x)) end

-- Activator shapes and how often each is drawn.
truth.shapes = {"hump", "plateau", "threshold", "two_peak", "biphasic", "spike"}
local shape_weights = {hump = 3, plateau = 2, threshold = 1.5, two_peak = 1, biphasic = 1, spike = 0.5}

local function draw_shape(rng)
  local total = 0
  for _, w in pairs(shape_weights) do total = total + w end
  local x = rng() * total
  for _, s in ipairs(truth.shapes) do
    x = x - shape_weights[s]
    if x <= 0 then return s end
  end
  return "hump"
end

local function generate_traits(rng)
  local families, traits = {}, {}
  for _, a in ipairs(shared.additives) do
    if not a.late and not families[a.family] then
      local f = {shape = draw_shape(rng)}
      for _, class in ipairs(shared.process_classes) do f[class] = normal(rng) end
      -- Specialists (0.47, one family led 19 of 20 targets on the playtest map): a
      -- family's affinities sum to zero across the classes, so strong at one means weak at another.
      -- Rescaled so each class keeps unit variance. Same draws, same order: the streams do not shift.
      local k, mean = #shared.process_classes, 0
      for _, class in ipairs(shared.process_classes) do mean = mean + f[class] / k end
      for _, class in ipairs(shared.process_classes) do f[class] = (f[class] - mean) * math.sqrt(k / (k - 1)) end
      families[a.family] = f
    end
  end
  for _, a in ipairs(shared.additives) do
    if a.late then goto continue end
    local parent = a.parent and traits[a.parent]
    local base = parent and parent.affinity or families[a.family]
    local spread = parent and 0.2 or truth.member_spread
    local affinity = {}
    for _, class in ipairs(shared.process_classes) do affinity[class] = base[class] + spread * normal(rng) end
    local shape, follows
    if parent then
      shape, follows = parent.shape, parent.follows
    else
      -- The same draw as ever (three in four take the family's shape); the family law of new worlds
      -- (truth.shape_of) reads the same number with a wider bar, so no stream moves.
      local u = rng()
      if u < 0.75 then shape = families[a.family].shape else shape = draw_shape(rng) end
      follows = u < 0.9
    end
    local potency = parent and clamp(parent.potency + 0.1 * normal(rng), 0, 1) or rng()
    traits[a.name] = {affinity = affinity, potency = potency, shape = shape, follows = follows}
    ::continue::
  end
  return traits
end

-- An activator's peak rises with its score at this slope, up to this cap (before responsiveness;
-- docs/balance.md, payoff spread).
truth.activator_slope = 0.15
truth.activator_cap = 0.28

-- Quirks (0.48, one additive still led 12 of 20 targets when it suited the dominant
-- process class): each additive has a hidden quirk on each target, added to its score, so family and
-- class set a tendency without deciding alone. A hash of (map seed, additive, target), not a stream:
-- no draw order to shift, and a world without t.quirk_seed (older saves) has none.
truth.quirk_sd = 0.4
-- How far a family member's affinities stray from its family's (pacing rule P4, 0.59: 0.4 let one
-- additive lead over 40% of a map's targets on 14% of worlds; raising the quirks instead blurred the
-- families). Drawn into each world's stored traits: old worlds keep theirs.
truth.member_spread = 0.25
-- World strength (0.57): how a score becomes a response. The same draws read
-- differently: the activator threshold, the peak's start, slope and cap, and hump sharpness. Set from
-- the map's strength (control.lua) before anything is drawn; standard is the values above.
truth.spike = {threshold = 0.8, base = 0.1, slope = truth.activator_slope, cap = truth.activator_cap, sharp = 1}
function truth.set_strength(name)
  local ws = shared.world_strength[name or "standard"]
  truth.spike = {threshold = ws.threshold, base = ws.base, slope = ws.slope, cap = ws.cap, sharp = ws.sharp,
    window = ws.window}
end
local function fnv(str)
  local h = 2166136261
  for i = 1, #str do
    h = bit32.bxor(h, str:byte(i))
    -- x 16777619 (2^24 + 403) mod 2^32, in two exact parts: one product would pass 2^53 and lose bits.
    h = bit32.band(h * 403 + bit32.lshift(h, 24), 0xFFFFFFFF)
  end
  return h
end
truth.fnv = fnv
function truth.quirk(t, additive, target_key)
  if not t.quirk_seed then return 0 end
  -- A premix: the mean of its members' quirks, as with its planet sensitivities (no roll of its own).
  local a = shared.additive(additive)
  if a and a.premix_of then
    return (truth.quirk(t, a.premix_of[1], target_key) + truth.quirk(t, a.premix_of[2], target_key)) / 2
  end
  -- An activated catalyst is its parent's chemistry, quirks included (no second roll of the dice).
  if additive:sub(1, 11) == "es-refined-" then additive = additive:sub(12) end
  local key = t.quirk_seed .. ":" .. additive .. ":" .. target_key
  local u1, u2 = (fnv(key .. ":1") + 0.5) / 4294967296, (fnv(key .. ":2") + 0.5) / 4294967296
  return truth.quirk_sd * math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
end

-- Response of one target recipe to one additive. `quirk` is added to the score (not for residues:
-- their faint hints follow the family).
local function response(rng, trait, target, peak_cap, faint, quirk)
  -- The score is normalised by the length of the target's process vector, so a target mixing several
  -- processes varies as much as a pure one (7c: unnormalised, mixed targets responded less).
  local s, norm = 0, 0
  for class, w in pairs(target.process) do s = s + w * trait.affinity[class]; norm = norm + w * w end
  s = s / math.sqrt(math.max(norm, 1e-9))
  if not faint then s = s + (quirk or 0) end
  local r = {score = s, shape = trait.shape,
             opt = clamp(1.5 + 6 * (1 - trait.potency) + (rng() - 0.5), 1.5, 8),
             k = (2 + 4 * rng()) * truth.spike.sharp,  -- sharpness of a hump
             tox = 0.25 / 9 * rng()}   -- toxicity: at most a quarter of the peak lost by dose 9
  if faint then
    -- Residues are degraded: most harm the recipe (so dumping them into production has a cost), and
    -- only where the residue still suits the target strongly does a faint gain remain: the hint of a
    -- discovery chain.
    if s > 0.35 then
      r.kind, r.peak = "activator", clamp(0.04 + 0.1 * (s - 0.35), 0.04, 0.15)
    else
      r.kind, r.peak = "inhibitor", clamp(0.04 + 0.05 * (0.35 - s), 0.04, 0.15)
    end
    return r
  end
  local sp = truth.spike
  if s > sp.threshold then
    r.kind, r.peak = "activator", clamp(sp.base + sp.slope * (s - sp.threshold), sp.base, peak_cap or sp.cap)
  elseif s < -1.2 then
    r.kind, r.peak = "inhibitor", clamp(0.1 + 0.2 * (-s - 1.2), 0.1, 0.5)
  else
    r.kind, r.peak = "inert", 0.03 * s   -- tiny: detectable only with very large samples
  end
  return r
end

function truth.generate(rng, quirk_seed)
  local traits = generate_traits(rng)
  -- shape_law (0.58): new worlds read shapes by family and process class (truth.shape_of).
  -- temp_axis (0.61): new worlds' fluid optima may lie beyond Nauvis's reach (truth.generate_fluid_temps).
  -- side_law (0.70): new worlds' side effects lean by the target's process classes (truth.side_base).
  -- frontier_law (0.70): temperature lifts an effect at most truth.frontier_max times (truth.temp_factor).
  -- early_law (0.70): wood is not early; a target whose only classic activator is wood gets one from the
  -- early set (truth.promote_early). The guarantee below still scans the classic five, so no draw moves.
  local t = {traits = traits, targets = {}, quirk_seed = quirk_seed, shape_law = true, temp_axis = true,
    side_law = true, early_law = true, frontier_law = true}
  for _, target in ipairs(shared.targets) do
    -- Targets added later are drawn by extend_targets (its own stream), so the main stream is unchanged.
    if target.extended or target.registered or target.own_stream then goto next_target end
    local by_additive, best = {}, nil
    for _, a in ipairs(shared.additives) do
      if a.late then goto next_additive end
      by_additive[a.name] = response(rng, traits[a.name], target, nil, nil, truth.quirk(t, a.name, target.key))
      if a.tier == 1 and (not best or by_additive[a.name].score > by_additive[best].score) then best = a.name end
      ::next_additive::
    end
    -- Every target has at least one real activator among Tier 1, so there is something to find.
    if by_additive[best].kind ~= "activator" then
      -- Modest (+5 to +15% before responsiveness) and at a findable dose, so a big find stays rare.
      local r = by_additive[best]
      r.kind, r.peak = "activator", truth.spike.base * (0.5 + rng())  -- (standard: 0.05 to 0.15)
      r.opt = 3 + 3 * rng()
    end
    t.targets[target.key] = by_additive
    ::next_target::
  end
  t.chem = truth.generate_chemistry(rng)  -- drawn after the singles, so their truths are unchanged
  t.routes = truth.generate_routes(t, rng)
  truth.extend(t, rng)
  truth.promote_early(t)
  return t
end

-- The early set (0.70): in a world with `early_law`,
-- every target with an activator among the classic five but none among the early set (wood its only one)
-- has its best-scoring early member made an activator, modest and at a findable dose as the guarantee's,
-- by a hash of the map and target (no stream). Run after every pass that adds targets; a target already
-- holding an early activator is left alone, so it runs once per target.
function truth.promote_early(t)
  if not (t.early_law and t.quirk_seed) then return end
  for key, by in pairs(t.targets) do
    local any, early, best = false, false, nil
    for _, a in ipairs(shared.additives) do
      local r = by[a.name]
      if a.tier == 1 and r then
        if r.kind == "activator" then any = true; if not a.unlock then early = true end end
        if not a.unlock and (not best or r.score > by[best].score) then best = a.name end
      end
    end
    if any and not early and best then
      local r = by[best]
      local h = t.quirk_seed .. ":early:" .. key
      r.kind, r.peak = "activator", truth.spike.base * (0.5 + (fnv(h .. ":peak") + 0.5) / 4294967296)
      r.opt = 3 + 3 * (fnv(h .. ":opt") + 0.5) / 4294967296
      t.promoted = t.promoted or {}
      t.promoted[key] = best
    end
  end
end

-- Discovery chains: traits and responses of the "late" additives (residues, refined catalysts), drawn
-- after everything else (and added the same way to older saves), so no existing truth changes.
-- A residue echoes its parent at 10-50% strength plus noise; a refined catalyst takes its residue's
-- direction, amplified to a strong effect, potent (low optimal doses) and allowed peaks up to +80%.
truth.refined_strength = 3.2  -- magnitude of a refined catalyst's hidden affinity (docs/balance.md)
truth.premix_strength = 1.9   -- magnitude of a premix's hidden affinity, x1.5 when its families are aligned

-- Also fills any other additive a truth lacks (saves made before it existed): from its parent, else
-- the mean of its family's members already present, else a fresh family draw.
local function fill_classic(t, a, rng)
  local base, spread, shape, potency = nil, 0.4, nil, nil
  local parent = a.parent and t.traits[a.parent]
  if parent then
    base, spread, shape = parent.affinity, 0.2, parent.shape
    potency = clamp(parent.potency + 0.1 * normal(rng), 0, 1)
  else
    local sum, count = {}, 0
    for _, other in ipairs(shared.additives) do
      local tr = other.family == a.family and t.traits[other.name]
      if tr then
        count = count + 1
        shape = shape or tr.shape
        for _, class in ipairs(shared.process_classes) do sum[class] = (sum[class] or 0) + tr.affinity[class] end
      end
    end
    base = {}
    for _, class in ipairs(shared.process_classes) do
      base[class] = count > 0 and sum[class] / count or normal(rng)
    end
    -- A new family (0.62, the biological one): a specialist like the others (centred, unit variance).
    if count == 0 then
      local k, mean = #shared.process_classes, 0
      for _, class in ipairs(shared.process_classes) do mean = mean + base[class] / k end
      for _, class in ipairs(shared.process_classes) do base[class] = (base[class] - mean) * math.sqrt(k / (k - 1)) end
    end
    shape = shape or draw_shape(rng)
    potency = rng()
  end
  local affinity = {}
  for _, class in ipairs(shared.process_classes) do affinity[class] = base[class] + spread * normal(rng) end
  -- Living additives follow the family shape law (0.62) as classic additives do, nine in ten.
  local follows = a.fill_late and rng() < 0.9 or nil
  return {affinity = affinity, potency = potency, shape = shape, follows = follows}
end

function truth.extend(t, rng)
  for _, a in ipairs(shared.additives) do
    if (not a.late or a.fill_late) and not t.traits[a.name] then
      t.traits[a.name] = fill_classic(t, a, rng)
      -- Targets the world does not have yet are filled whole by extend_targets (afterwards), so the
      -- draws for existing targets stay in their old order.
      for _, target in ipairs(shared.targets) do
        if t.targets[target.key] and not target.registered then  -- (registered: extend_registered)
          t.targets[target.key][a.name] = response(rng, t.traits[a.name], target, nil, nil, truth.quirk(t, a.name, target.key))
        end
      end
    end
    if a.late and not a.fill_late and not t.traits[a.name] and a.stable_name then
      -- A volatile premix is its stable twin's chemistry (listed just before it).
      t.traits[a.name] = t.traits[a.stable_name]
      for _, target in ipairs(shared.targets) do
        if t.targets[target.key] then t.targets[target.key][a.name] = t.targets[target.key][a.stable_name] end
      end
    elseif a.late and not a.fill_late and not t.traits[a.name] then
      local affinity, potency, shape = {}, nil, nil
      if a.premix_of then
        -- Premix: its two additives' directions combined, amplified, more when their families'
        -- chemistry is aligned (the synergy that unlocks it); potent.
        local dir, norm = {}, 0
        for _, class in ipairs(shared.process_classes) do
          dir[class] = t.traits[a.premix_of[1]].affinity[class] + t.traits[a.premix_of[2]].affinity[class]
          norm = norm + dir[class] ^ 2
        end
        norm = math.max(math.sqrt(norm), 0.3)
        local fa, fb = shared.additive(a.premix_of[1]).family, shared.additive(a.premix_of[2]).family
        local align = t.chem and t.chem[fa] and t.chem[fb] and math.cos(t.chem[fa] - t.chem[fb]) or 0
        local strength = truth.premix_strength * (1 + 0.5 * math.max(0, align))
        for _, class in ipairs(shared.process_classes) do affinity[class] = dir[class] / norm * strength end
        potency, shape = 0.85 + 0.15 * rng(), draw_shape(rng)
      elseif a.spent_of then
        -- A family residue (0.39) echoes its family: the mean of its members' directions.
        local parent = t.traits[a.spent_of]
        local mean, count = {}, 0
        for _, m in ipairs(shared.additives) do
          if m.family == (a.residue_of or parent and shared.additive(a.spent_of).family) and not m.late and not m.fluid
              and t.traits[m.name] then
            count = count + 1
            for _, class in ipairs(shared.process_classes) do mean[class] = (mean[class] or 0) + t.traits[m.name].affinity[class] end
          end
        end
        local echo = 0.1 + 0.4 * rng()
        for _, class in ipairs(shared.process_classes) do
          local base = count > 0 and mean[class] / count or parent.affinity[class]
          affinity[class] = base * echo + 0.25 * normal(rng)
        end
        potency, shape = parent.potency, parent.shape
      else
        local src = t.traits[a.refined_from]
        local norm = 0
        for _, class in ipairs(shared.process_classes) do norm = norm + src.affinity[class] ^ 2 end
        norm = math.max(math.sqrt(norm), 0.3)
        for _, class in ipairs(shared.process_classes) do affinity[class] = src.affinity[class] / norm * truth.refined_strength end
        potency, shape = 0.7 + 0.3 * rng(), draw_shape(rng)
      end
      t.traits[a.name] = {affinity = affinity, potency = potency, shape = shape}
      for _, target in ipairs(shared.targets) do
        if t.targets[target.key] and not target.registered then
          t.targets[target.key][a.name] = response(rng, t.traits[a.name], target, a.tier >= 3 and 0.8 or 0.6,
            a.spent_of ~= nil, truth.quirk(t, a.name, target.key))
        end
      end
    end
    if t.chem and not t.chem[a.family] then t.chem[a.family] = 2 * math.pi * rng() end
  end
end

local function bump(x, centre, width) return math.exp(-((x - centre) ^ 2) / (2 * width ^ 2)) end
-- A bump shifted to be 0 at dose 0 and rescaled to reach 1 at its centre.
local function bump0(x, centre, width)
  local b0 = bump(0, centre, width)
  return (bump(x, centre, width) - b0) / (1 - b0)
end
local function rise(x, scale) return 1 - math.exp(-3 * math.max(x, 0) / scale) end

-- Activator curves: zero at dose 0, reaching about `peak`.
local curve = {
  hump = function(r, d)
    local x = d / r.opt
    return x ^ r.k * math.exp(r.k * (1 - x))
  end,
  plateau = function(r, d) return rise(d, r.opt) end,
  threshold = function(r, d)
    local at = clamp(r.opt - 1, 2, 7)
    local function step(x) return 1 / (1 + math.exp(-4 * (x - at + 0.5))) end
    return (step(d) - step(0)) / (1 - step(0))
  end,
  two_peak = function(r, d)
    local trap = r.opt >= 5 and r.opt - 3.5 or math.min(r.opt + 3.5, 9)
    return bump0(d, r.opt, 0.9) + 0.45 * bump0(d, trap, 0.7)
  end,
  biphasic = function(r, d)
    local b = clamp(0.3 * r.opt, 1, 3)
    local dip = d < 2 * b and -0.4 * math.sin(math.pi * d / (2 * b)) or 0
    return dip + rise(d - b, math.max(r.opt - b, 1))
  end,
  spike = function(r, d)
    local at = clamp(math.floor(r.opt + 0.5), 2, 8)
    return bump0(d, at, 0.45)
  end,
  -- Cliff (0.58): saturates toward the optimum, then collapses to well below zero past a cliff 60% beyond
  -- it, never past dose 8.5. Only the family law of new worlds gives it (truth.shape_of).
  cliff = function(r, d)
    local o = math.min(r.opt, 6)
    local at = math.min(1.6 * o, 8.5)
    return rise(d, o) - 2 / (1 + math.exp(-4 * (d - at)))
  end,
}

-- Family-set shapes (0.58): in a world with `shape_law`, an
-- activator whose additive follows its family takes its family's shape on the target's main process
-- class, picked by a hash of the map, family and class (no stream), from today's weights plus the cliff.
-- Activated catalysts follow their parent. Other worlds, and individualists, keep their drawn shape.
local law_weights = {hump = 3, plateau = 2, threshold = 1.5, two_peak = 1, biphasic = 1, spike = 0.5, cliff = 1}
local law_order = {"hump", "plateau", "threshold", "two_peak", "biphasic", "spike", "cliff"}
local function main_class(process)
  local best, bw = shared.process_classes[1], -1
  for _, c in ipairs(shared.process_classes) do
    local w = process and process[c] or 0
    if w > bw then best, bw = c, w end
  end
  return best
end
function truth.shape_of(t, target_key, additive, r)
  if r.kind ~= "activator" then return "hump" end
  if not t.shape_law then return r.shape end
  local a = shared.additive(additive)
  local base = a and a.refined_from or additive
  local tr = t.traits[base]
  if not (tr and tr.follows) then return r.shape end
  local sub = shared.target(target_key)
  local key = t.quirk_seed .. ":shape:" .. tostring(shared.mix_family(base)) .. ":" .. main_class(sub and sub.process)
  local total = 0
  for _, s in ipairs(law_order) do total = total + law_weights[s] end
  local x = (fnv(key) + 0.5) / 4294967296 * total
  for _, s in ipairs(law_order) do
    x = x - law_weights[s]
    if x <= 0 then return s end
  end
  return "hump"
end

-- True yield gain (fraction of the batch) for target, additive, dose. Control (no additive) is 0.
-- Doses are in the additive's own units; the curves see them on the item scale (0 to max_dose).
-- Responsiveness (7c): how strongly a target reacts to additives. A lawful base from the recipe (more
-- ingredient kinds and longer crafts respond more; computed from prototypes in control.lua) times a
-- per-map lognormal. Worlds made before 0.16 have none and keep their responses unchanged.
truth.responsiveness_sd = 0.2
function truth.generate_responsiveness(base, rng)
  local out = {}
  for _, t in ipairs(shared.all_targets_all) do  -- retired routes too: draws unchanged
    if not t.registered and not t.own_stream then  -- (other mods' targets and own-stream ones: extend_registered)
      out[t.key] = (base[t.key] or 1) * math.exp(truth.responsiveness_sd * normal(rng))
    end
  end
  return out
end

-- An additive's largest effect on any target, whatever the target's responsiveness.
local function cap_of(additive)
  local a = shared.additive(additive)
  if a.spent_of then return 0.15 end
  if a.tier >= 3 then return 0.8 end
  return 0.6
end

-- The factor a response is scaled by on a target: its responsiveness, within the additive's cap.
-- The matching law (decided 2026-10-02): deeper additives answer recipe complexity more strongly. An
-- additive's depth: raw 0, an activated catalyst or a premix 1, a premix with a catalyst 2; its
-- responsiveness on a target is the target's raised to (1 + depth x depth_exponent), so on simple
-- recipes (below 1) deep additives are weaker and on complex ones stronger (docs/balance.py's rules).
truth.depth_exponent = 0.35
function truth.depth(additive)
  local a = shared.additive(additive)
  if not a then return 0 end
  if a.premix_of then
    return (shared.additive(a.premix_of[1]).refined_from or shared.additive(a.premix_of[2]).refined_from) and 2 or 1
  end
  return a.refined_from and 1 or 0
end
local function responsiveness_of(t, target_key, additive)
  local base = t.responsiveness and t.responsiveness[target_key] or 1
  local d = truth.depth(additive)
  return d > 0 and base ^ (1 + d * truth.depth_exponent) or base
end
truth.responsiveness_of = responsiveness_of

function truth.scale(t, target_key, additive)
  local r = t.targets[target_key][additive]
  local k = responsiveness_of(t, target_key, additive)
  if r.peak ~= 0 then k = math.min(k, cap_of(additive) / math.abs(r.peak)) end
  return k
end

-- Planet conditions (decided 2026-09-30): each family and each process class has hidden sensitivities
-- to gravity, pressure and magnetic field. On a surface, an additive's yield effect is multiplied by
-- exp(sum over properties of (family + target's classes) sensitivity x log(value / Nauvis value)).
-- Nauvis is neutral (every log is zero), so Nauvis play and existing worlds are unchanged. Lawful: the
-- same family behaves alike under the same physics, on every target.
truth.conditions_sd = 0.35
truth.condition_props = {"gravity", "pressure", "magnetic-field"}

-- Science richness (0.72): per map, how much empirical science a
-- settled question still pays on each process class, as a standard normal; a target's own is its process mix of
-- them (research.floor_of). Its own stream: every other draw is unchanged.
function truth.generate_science_richness(t, rng)
  if t.richness then return end
  t.richness = {}
  for _, c in ipairs(shared.process_classes) do t.richness[c] = normal(rng) end
end

function truth.generate_conditions(t, rng)
  t.cond = t.cond or {family = {}, class = {}}
  local function draw(into, key)
    if into[key] then return end
    local v = {}
    for _, p in ipairs(truth.condition_props) do v[p] = truth.conditions_sd * normal(rng) end
    into[key] = v
  end
  for _, class in ipairs(shared.process_classes) do draw(t.cond.class, class) end
  for _, a in ipairs(shared.additives) do if not a.premix_of then draw(t.cond.family, a.family) end end
end

-- Each additive's own sensitivities on top of its family's (decided 2026-10-01: a planet then changes
-- which additive is best more often; the family laws still hold on average). Own stream.
function truth.generate_additive_conditions(t, rng)
  t.cond = t.cond or {family = {}, class = {}}
  t.cond.additive = t.cond.additive or {}
  for _, a in ipairs(shared.additives) do
    if not a.premix_of and not t.cond.additive[a.name] then
      local v = {}
      for _, p in ipairs(truth.condition_props) do v[p] = truth.conditions_sd * normal(rng) end
      t.cond.additive[a.name] = v
    end
  end
end

-- A surface's condition: {property = log(value / Nauvis value)}; nil on Nauvis (or anything identical).
function truth.condition_of(values)
  local c, any = {}, false
  local nauvis = {gravity = 10, pressure = 1000, ["magnetic-field"] = 90}
  for _, p in ipairs(truth.condition_props) do
    local v = values[p] or nauvis[p]
    c[p] = math.log(math.max(v, 0.25 * nauvis[p]) / nauvis[p])  -- vacuum and zero-g floor at a quarter
    if math.abs(c[p]) > 1e-9 then any = true end
  end
  return any and c or nil
end

-- An additive's sensitivities: its family's plus its own. A premix: the mean of its two members'.
local function family_sens(t, additive)
  local a = shared.additive(additive)
  if a.premix_of then
    local x, y = family_sens(t, a.premix_of[1]), family_sens(t, a.premix_of[2])
    local v = {}
    for _, p in ipairs(truth.condition_props) do v[p] = ((x and x[p] or 0) + (y and y[p] or 0)) / 2 end
    return v
  end
  local f = t.cond.family[a.family] or {}
  local own = t.cond.additive and t.cond.additive[a.name] or {}
  local v = {}
  for _, p in ipairs(truth.condition_props) do v[p] = (f[p] or 0) + (own[p] or 0) end
  return v
end

function truth.condition_factor(t, target_key, additive, cond)
  if not (cond and t.cond) then return 1 end
  local target = shared.target(target_key)
  local process = (target.parent or target).process or target.process or {}
  local f = family_sens(t, additive) or {}
  local sum = 0
  for _, p in ipairs(truth.condition_props) do
    local s = f[p] or 0
    for class, w in pairs(process) do s = s + w * ((t.cond.class[class] or {})[p] or 0) end
    sum = sum + s * (cond[p] or 0)
  end
  -- Within a third and three times: a planet changes how much an additive does, not what it is.
  return math.max(1 / 3, math.min(3, math.exp(sum)))
end

-- Liquid premixes (0.27): each works best at a hidden temperature between how it is made (cold) and
-- how steam heats it (hot); away from it the effect falls to a quarter at worst (a Gaussian of width
-- premix_temp_width). Temperature replaces volatility for them: fluids cannot spoil.
truth.premix_temp_width = 20
function truth.generate_premix_temps(t, rng)
  t.premix_temp = t.premix_temp or {}
  local P = shared.premix
  for _, a in ipairs(shared.premixes) do
    if a.fluid and not t.premix_temp[a.name] then
      local v = P.cold + (P.hot - P.cold) * rng()
      -- The temperature axis (0.61): on new maps a premix's best may lie beyond reach, by the fluids' law.
      if t.temp_axis then
        local u = (fnv((t.quirk_seed or 0) .. ":ptemp:" .. a.name .. ":side") + 0.5) / 4294967296
        local far = (fnv((t.quirk_seed or 0) .. ":ptemp:" .. a.name .. ":far") + 0.5) / 4294967296
        if u < 0.15 then v = P.hot + 400 * far ^ 1.5 elseif u < 0.30 then v = P.cold - 150 * far end
      end
      t.premix_temp[a.name] = v
    end
  end
end
-- Every fluid additive (decided 2026-10-01): a hidden best temperature, its family's base plus its own
-- offset (lawful: oils like the same warmth, roughly). Drawn within the heaters' reach. Own stream.
-- The temperature axis (0.61): in a new world (`temp_axis`) a fluid family's best temperature may
-- lie beyond Nauvis's reach: hot (to 490, mostly below 300) on 12.5% of families, cold (to -135) on 12.5%, by a
-- hash of the map and family (no stream: the draws below are unchanged). Old worlds keep 15 to 90.
local function family_hash(t, family, tag)
  return (fnv((t.quirk_seed or 0) .. ":temp:" .. family .. ":" .. tag) + 0.5) / 4294967296
end
function truth.generate_fluid_temps(t, rng)
  t.fluid_temp = t.fluid_temp or {}
  local base = {}
  local P = shared.premix
  for _, a in ipairs(shared.additives) do
    if a.fluid and not a.premix_of and not t.fluid_temp[a.name] then
      if not base[a.family] then
        base[a.family] = P.cold + (P.hot - P.cold) * rng()
        if t.temp_axis then
          local u = family_hash(t, a.family, "side")
          -- (12.5% each way: a member's own offset carries some edge families out too; at 15% each way
          -- fluid additives were out of reach on 37%, over the rule's 35%.)
          if u < 0.125 then base[a.family] = P.hot + 400 * family_hash(t, a.family, "far") ^ 1.5
          elseif u < 0.25 then base[a.family] = P.cold - 150 * family_hash(t, a.family, "far") end
        end
      end
      local v = base[a.family] + 10 * normal(rng)
      local lo, hi = P.cold, P.hot
      if t.temp_axis then lo, hi = shared.temp_axis.min + 15, shared.temp_axis.max - 10 end
      t.fluid_temp[a.name] = math.max(lo, math.min(hi, v))
    end
  end
end

-- The effect at a temperature, relative to the fluid's usual one (its prototype's default: a premix is
-- made at 15): at the usual temperature nothing changes, so Nauvis balance holds; heating reveals a
-- gain or a loss. Up to four times, down to a quarter, before the additive's ceiling.
-- A best temperature beyond Nauvis's reach is broader (0.61): the width grows with its distance beyond,
-- so the reachable curve still slopes toward it. Within reach the width is truth.premix_temp_width.
local function width_of(best)
  local beyond = math.max(0, best - shared.premix.hot, shared.premix.cold - best)
  return truth.premix_temp_width + 0.4 * beyond
end
truth.temp_width_of = width_of
local function curve_at(best, temp) return 0.25 + 0.75 * math.exp(-((temp - best) / width_of(best)) ^ 2) end
-- Ripeness (0.62): a living additive's best spoil fraction, from a hash (no
-- stream), anywhere from fresh to 0.9; its effect over ripeness the temperature curve's shape, relative to
-- fresh (ripeness 0).
function truth.ripe_best(t, additive)
  return 0.9 * (fnv((t.quirk_seed or 0) .. ":ripe:" .. additive) + 0.5) / 4294967296
end
local function ripe_curve(best, r) return 0.25 + 0.75 * math.exp(-((r - best) / shared.ripe.width) ^ 2) end
function truth.ripe_factor(t, additive, r)
  local best = truth.ripe_best(t, additive)
  return ripe_curve(best, r) / ripe_curve(best, 0)
end
-- The frontier's ceiling (0.70): set by the model.
truth.frontier_max = 3  -- (by the model: frontier over usual had a 95th percentile of 3.1 at 4)
function truth.temp_factor(t, additive, temp)
  local a = shared.additive(additive)
  if a and a.living then
    if not temp then return 1 end
    return truth.ripe_factor(t, additive, temp)  -- (a living additive's "temperature" is its ripeness)
  end
  local best = (t.premix_temp and t.premix_temp[additive]) or (t.fluid_temp and t.fluid_temp[additive])
  if not (best and temp) then return 1 end
  local usual = shared.usual_temp(additive)
  if math.abs(temp - usual) < 1e-6 then return 1 end
  local f = curve_at(best, temp) / curve_at(best, usual)
  if t.frontier_law and f > truth.frontier_max then f = truth.frontier_max end
  return f
end

function truth.gain(t, target_key, additive, dose, cond, temp)
  if not additive or dose == 0 then return 0 end
  local tf = truth.temp_factor(t, additive, temp)
  if tf ~= 1 then
    local cap = cap_of(additive) * responsiveness_of(t, target_key, additive)
    return math.max(-cap, math.min(cap, tf * truth.gain(t, target_key, additive, dose, cond)))
  end
  local factor = truth.condition_factor(t, target_key, additive, cond)
  if factor ~= 1 then
    -- Never beyond the additive's usual ceiling on this target (its cap x the target's responsiveness).
    local cap = cap_of(additive) * responsiveness_of(t, target_key, additive)
    return math.max(-cap, math.min(cap, factor * truth.gain(t, target_key, additive, dose)))
  end
  dose = dose * shared.max_dose / shared.additive(additive).max_dose
  local r = t.targets[target_key][additive]
  local k = truth.scale(t, target_key, additive)
  if r.kind == "inhibitor" then return -k * r.peak * (1 - math.exp(-dose / 2.5)) end
  local shape = truth.shape_of(t, target_key, additive, r)
  local c = curve[shape](r, dose)
  -- World strength: a harsh world's activators sit in a dose window around their optimum.
  if r.kind == "activator" and truth.spike.window then c = c * math.exp(-((dose - r.opt) / truth.spike.window) ^ 2) end
  return k * (r.peak * c - r.tox * math.abs(r.peak) * dose)
end

-- Alternate routes: each route's real yield relative to its recipe. With a lever additive, it follows
-- how that additive's hidden traits suit the target (lawful); otherwise its own draw. Some are duds.
function truth.generate_routes(t, rng)
  local routes = {}
  for _, target in ipairs(shared.targets) do
    routes[target.key] = {}
    for _, route in ipairs(shared.routes_all[target.key] or {}) do  -- retired routes too: draws unchanged
      local g
      if route.lever then
        local s = 0
        for class, w in pairs(target.process) do s = s + w * t.traits[route.lever].affinity[class] end
        g = 0.12 * s + 0.12 * normal(rng)
      else
        g = -0.02 + 0.15 * normal(rng)
      end
      routes[target.key][route.key] = math.max(-0.6, math.min(0.4, g))
    end
  end
  return routes
end

function truth.route_gain(t, target_key, route_key) return t.routes[target_key][route_key] end

-- Additives on routes (7b): each route is a sub-target (shared.subtargets) with its own process
-- profile; its responses come from the same hidden traits, drawn on their own stream (control.lua)
-- after every trait exists, so nothing else changes.
function truth.generate_route_responses(t, rng)
  for _, sub in ipairs(shared.subtargets_all) do  -- retired routes too: draws unchanged
    if not t.targets[sub.key] then
      local by = {}
      for _, a in ipairs(shared.additives) do
        if a.stable_name then
          by[a.name] = by[a.stable_name]
        else
          by[a.name] = response(rng, t.traits[a.name], sub, a.late and (a.tier >= 3 and 0.8 or 0.6) or nil,
            a.spent_of ~= nil, truth.quirk(t, a.name, sub.key))
        end
      end
      t.targets[sub.key] = by
    end
  end
end

-- Yield gain of a composition (possibly empty) on a target or route sub-target, relative to the
-- recipe's nominal output: on a route, the route's own gain times the composition's on the route.
-- Quality agents: for each agent and target, a dose curve of the chance
-- a product comes out one quality tier up (hump or plateau, best dose drawn), its strength from the
-- agent's rarity (about 5-15% at the best dose), and a cost: speed, like a quality module (1.5-2.5x
-- the chance), and for the strongest also yield. From its own stream (map seed + 101), so nothing else
-- in the world changes. Agents stay out of family chemistry: their own effects add to a mix's.
local function draw_agent(rng, a)
  local peak = clamp(0.05 + 0.10 * a.rarity + 0.03 * normal(rng), 0.03, 0.18)
  return {peak = peak, shape = rng() < 0.6 and "hump" or "plateau",
    opt = clamp(2 + 5 * rng(), 2, 8), k = 2 + 3 * rng(),
    speed = -(1.5 + rng()) * peak, yield = -1.5 * math.max(0, peak - 0.11)}
end
function truth.generate_quality(t, rng)
  t.quality = t.quality or {}
  -- One pass per batch of targets: the first ones, then each batch added later (`extended` = 1, 2, ...),
  -- agent by agent, so an agent's draws on earlier targets do not move when a batch is added (one pass
  -- shifted every later agent, 0.50; one pass for all later batches did the same to the plates, 0.52).
  local last = 0
  for _, tg in ipairs(shared.targets) do last = math.max(last, tg.extended or 0) end
  for pass = 0, last do
  for _, a in ipairs(shared.agents) do
    local by = t.quality[a.name] or {}
    t.quality[a.name] = by
    for _, target in ipairs(shared.targets) do
      if not by[target.key] and not target.registered and not target.own_stream and (target.extended or 0) == pass then
        by[target.key] = draw_agent(rng, a)
      end
    end
  end
  end
end
-- An agent's curve at a dose, 0 to 1 of its peak (the yield curves' shapes, no toxicity).
local function agent_curve(r, dose)
  if dose <= 0 then return 0 end
  return math.max(0, curve[r.shape](r, dose))
end
local function agent_of(t, name, key)
  local sub = shared.target(key)
  local tk = sub and sub.route and sub.parent.key or key
  return t.quality and t.quality[name] and t.quality[name][tk]
end
-- The chance a product of `key` made with `mix` comes out one tier up (agents act independently).
function truth.quality_chance(t, key, mix)
  local stay = 1
  for name, dose in pairs(mix) do
    if shared.is_agent(name) then
      local r = agent_of(t, name, key)
      if r then stay = stay * (1 - r.peak * agent_curve(r, dose)) end
    end
  end
  return 1 - stay
end
-- A mix without its agents, and the agents' own effect (yield or speed) on `key`.
local function split_agents(mix)
  local plain, has = {}, false
  for name, dose in pairs(mix) do
    if shared.is_agent(name) then has = true else plain[name] = dose end
  end
  return plain, has
end
local function agents_effect(t, key, mix, effect)
  local total = 0
  for name, dose in pairs(mix) do
    if shared.is_agent(name) then
      local r = agent_of(t, name, key)
      if r and r[effect] then total = total + r[effect] * agent_curve(r, dose) end
    end
  end
  return total
end

function truth.gain_on(t, key, mix, cond, temps)
  local sub = shared.target(key)
  local plain, has = split_agents(mix)
  local g = next(plain) and truth.gain_mix(t, key, plain, cond, temps) or 0
  if has then g = g + agents_effect(t, key, mix, "yield") end
  if sub.route then return (1 + truth.route_gain(t, sub.parent.key, sub.route.key)) * (1 + g) - 1 end
  return g
end

-- Mixtures (4b). Each family has a hidden "chemistry" direction; two families interact in
-- proportion to how aligned their directions are (synergy) or opposed (antagonism), the same on
-- every target: lawful, so one pair's behaviour hints at others from the same families.
truth.interaction = 0.25     -- largest synergy or antagonism of two fully present additives
truth.overlap = 0.3          -- same family: the weaker positive effect counts only this much
truth.stack_cap = 0.3        -- a mixture adds at most about this much over its best single effect

function truth.generate_chemistry(rng)
  local chem = {}
  for _, a in ipairs(shared.additives) do
    if not a.late and not chem[a.family] then chem[a.family] = 2 * math.pi * rng() end
  end
  return chem
end

-- How present an additive is at a dose (0 at none, near 1 well above its scale): what interacts.
local function presence(name, dose)
  local x = dose * shared.max_dose / shared.additive(name).max_dose
  return 1 - math.exp(-x / 3)
end

-- Synergy (+) or antagonism (-) between two families, at full presence.
function truth.pair_strength(t, family_a, family_b)
  if family_a == family_b then return 0 end
  return truth.interaction * math.cos(t.chem[family_a] - t.chem[family_b])
end

-- Yield gain of a mixture {name = dose}. A single additive is exactly truth.gain.
function truth.gain_mix(t, target_key, mix, cond, temps)
  local items, best = {}, 0
  for name, dose in pairs(mix) do
    local g = truth.gain(t, target_key, name, dose, cond, temps and temps[name])
    table.insert(items, {family = shared.mix_family(name), g = g, p = presence(name, dose)})
    if g > best then best = g end
  end
  if #items <= 1 then return items[1] and items[1].g or 0 end
  -- Same family: redundant, the strongest positive effect counts fully, the others by `overlap`.
  local total, by_family = 0, {}
  for _, it in ipairs(items) do
    local f = by_family[it.family] or {max = 0, rest = 0}
    if it.g > 0 then
      if it.g > f.max then f.rest, f.max = f.rest + f.max, it.g else f.rest = f.rest + it.g end
    else
      total = total + it.g
    end
    by_family[it.family] = f
  end
  for _, f in pairs(by_family) do total = total + f.max + truth.overlap * f.rest end
  -- Different families: pairwise synergy or antagonism, scaled by how present both are, and like every
  -- effect by the target's responsiveness (a target that barely responds gets small synergies too).
  local k = t.responsiveness and t.responsiveness[target_key] or 1
  for i = 1, #items do
    for j = i + 1, #items do
      total = total + k * truth.pair_strength(t, items[i].family, items[j].family) * items[i].p * items[j].p
    end
  end
  -- Stacking has diminishing returns above the best single effect.
  local cap = k * truth.stack_cap
  if total > best then return best + cap * (1 - math.exp(-(total - best) / cap)) end
  return total
end

-- Side effects (7d): speed and pollution. Each additive has a cost direction drawn so that the
-- stronger its best yield affinity, the likelier it costs something (no free lunch, correlation
-- side_rho), partly shared by its family, and split between speed and pollution by a family angle in
-- the first quadrant (so a cost lands on one axis, the other, or both, never a free gain on both).
-- "Good is positive": speed = crafts per unit time; pollution = less emitted per craft. Every target
-- feels them scaled by its responsiveness. Own random stream (control.lua); yield is untouched.
truth.side_rho = 0.5
truth.speed_scale, truth.speed_cap = 0.15, 0.3
truth.pollution_scale, truth.pollution_min, truth.pollution_max = 0.3, -0.8, 0.4

function truth.generate_side(t, rng)
  truth.clear_side_cache(t)
  t.side = t.side or {}
  t.side_family = t.side_family or {}
  for _, a in ipairs(shared.additives) do
    local f = t.side_family[a.family]
    if not f then
      f = {theta = 0.5 * math.pi * rng(), bias = normal(rng)}
      t.side_family[a.family] = f
    end
    local tr = t.traits[a.name]
    if a.stable_name and t.side[a.stable_name] and not t.side[a.name] then
      t.side[a.name] = t.side[a.stable_name]
    elseif tr and not t.side[a.name] then
      local strongest = -math.huge
      for _, v in pairs(tr.affinity) do strongest = math.max(strongest, v) end
      local own = 0.5 * f.bias + math.sqrt(0.75) * normal(rng)
      local c = -truth.side_rho * strongest + math.sqrt(1 - truth.side_rho ^ 2) * own
      t.side[a.name] = {
        speed = clamp(truth.speed_scale * c * math.cos(f.theta), -truth.speed_cap, truth.speed_cap),
        pollution = clamp(truth.pollution_scale * c * math.sin(f.theta), truth.pollution_min, truth.pollution_max)}
    end
  end
end

-- A composition's effect of one kind on a target or route sub-target: "yield" as gain_on; "speed" and
-- "pollution" sum each additive's side effect, weighted by how present it is at its dose, scaled by
-- the target's responsiveness, and kept within bounds.
-- Efficiency (2026-10-02): how much less power a machine draws
-- while it works with this additive (positive is less, like cleanliness). Per additive from its own
-- stream (map seed + 109), with a lawful pull: what speeds a machine up tends to cost power, as speed
-- modules do. Quality agents have none.
truth.efficiency_scale, truth.efficiency_cap = 0.12, 0.4
function truth.generate_efficiency(t, rng)
  truth.clear_side_cache(t)
  t.efficiency = t.efficiency or {}
  for _, a in ipairs(shared.all_additives) do
    if not t.efficiency[a.name] then
      if a.agent then
        t.efficiency[a.name] = 0
      elseif a.stable_name and t.efficiency[a.stable_name] then
        t.efficiency[a.name] = t.efficiency[a.stable_name]
      else
        local sp = t.side and t.side[a.name] and t.side[a.name].speed or 0
        t.efficiency[a.name] = clamp(-0.8 * sp + truth.efficiency_scale * normal(rng), -truth.efficiency_cap, truth.efficiency_cap)
      end
    end
  end
end

-- Side effects by class (0.70): in a world with
-- `side_law`, an additive's speed and pollution on a target add its family's leaning on the target's
-- process classes, hashed per map, family, effect and class (no stream), centred per family so that fast
-- on one class means slower on the others. Residues and catalysts lean as their family, a premix as the
-- mean of its members', agents not at all. Efficiency follows the realised speed, its own noise kept.
-- Worlds without the law keep one value per additive.
truth.side_lambda = {speed = 0.075, pollution = 0.15}  -- (by the model: S4 broke at 0.1 / 0.2)
local leans = {}
local function family_lean(t, family, effect)
  local key = t.quirk_seed .. ":side:" .. family .. ":" .. effect
  if leans[key] then return leans[key] end
  local v, k, mean = {}, #shared.process_classes, 0
  for _, class in ipairs(shared.process_classes) do
    local u1 = (fnv(key .. ":" .. class .. ":1") + 0.5) / 4294967296
    local u2 = (fnv(key .. ":" .. class .. ":2") + 0.5) / 4294967296
    v[class] = math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2)
    mean = mean + v[class] / k
  end
  for _, class in ipairs(shared.process_classes) do v[class] = (v[class] - mean) * math.sqrt(k / (k - 1)) end
  leans[key] = v
  return v
end
local function lean_on(t, key, name, effect)
  local a = shared.additive(name)
  if not a or a.agent then return 0 end
  if a.premix_of then
    return (lean_on(t, key, a.premix_of[1], effect) + lean_on(t, key, a.premix_of[2], effect)) / 2
  end
  local family = shared.mix_family(name)
  local sub = shared.target(key)
  local process = sub and (sub.process or (sub.parent and sub.parent.process))
  if not (family and process) then return 0 end
  local lean, s, norm = family_lean(t, family, effect), 0, 0
  for _, class in ipairs(shared.process_classes) do
    local w = process[class] or 0
    s = s + w * lean[class]; norm = norm + w * w
  end
  return s / math.sqrt(math.max(norm, 1e-9))
end
truth.lean_on = lean_on

-- An additive's speed, pollution and efficiency on a target at full presence, before responsiveness.
-- Cached per world table, target and additive (0.70: every dosed craft reads it; the perf scenario went from
-- 0.2 to 0.35 ms a tick). Not saved: a world's side effects are fixed once drawn, and the cache starts empty
-- on load. Weak keys: a world table no longer used (the sampler's, the tests') goes with its cache.
local side_cache = setmetatable({}, {__mode = "k"})
function truth.clear_side_cache(t) side_cache[t] = nil end
function truth.side_base(t, key, name)
  local by_t = side_cache[t]
  if not by_t then by_t = {}; side_cache[t] = by_t end
  local by_key = by_t[key]
  if not by_key then by_key = {}; by_t[key] = by_key end
  local c = by_key[name]
  if not c then c = {truth.side_base_uncached(t, key, name)}; by_key[name] = c end
  return c[1], c[2], c[3]
end
function truth.side_base_uncached(t, key, name)
  local sd = t.side and t.side[name]
  local sp, po = sd and sd.speed or 0, sd and sd.pollution or 0
  local ef = t.efficiency and t.efficiency[name] or 0
  if t.side_law and t.quirk_seed then
    local dsp = truth.side_lambda.speed * lean_on(t, key, name, "speed")
    sp = sp + dsp
    po = po + truth.side_lambda.pollution * lean_on(t, key, name, "pollution")
    ef = ef - 0.8 * dsp
  end
  return sp, po, ef
end

-- Freshness (0.52, decided 2026-10-02/03): a dosed craft's products come out fresher than the spoilage
-- they inherit from their ingredients, by a fraction (0 to truth.freshness_cap). Per additive: a family
-- component and its own, positive part only (about half the additives do nothing), from its own stream
-- (map seed + 131). Agents none; a volatile premix its stable twin's; a residue half its family's.
truth.freshness_scale = 0.18  -- median best restoration 15% at 0.15 fell just short of the rule
truth.freshness_cap = 0.6
function truth.generate_freshness(t, rng)
  t.freshness = t.freshness or {}
  t.fresh_family = t.fresh_family or {}
  -- Two passes (families, then additives) over every additive drawn before 0.62; the living additives
  -- after both, in a pass of their own: a new family in the first pass would have moved every additive's
  -- own draw in the second (a freshness test on one seed caught it).
  for _, a in ipairs(shared.all_additives) do
    if not a.fill_late and not t.fresh_family[a.family] then t.fresh_family[a.family] = normal(rng) end
  end
  local function own(a)
    if not t.freshness[a.name] then
      if a.agent then
        t.freshness[a.name] = 0
      elseif a.stable_name and t.freshness[a.stable_name] then
        t.freshness[a.name] = t.freshness[a.stable_name]
      else
        local fam = t.fresh_family[a.residue_of or a.family] or t.fresh_family[a.family]
        local z = 0.7 * fam + 0.7 * normal(rng)
        if a.spent_of then z = 0.5 * z end
        t.freshness[a.name] = clamp(truth.freshness_scale * z, 0, truth.freshness_cap)
      end
    end
  end
  for _, a in ipairs(shared.all_additives) do if not a.fill_late then own(a) end end
  for _, a in ipairs(shared.all_additives) do
    if a.fill_late then
      if not t.fresh_family[a.family] then t.fresh_family[a.family] = normal(rng) end
      own(a)
    end
  end
end
-- Whether a target's product spoils (freshness acts only there; control stage).
local spoils = {}
function truth.spoilable(key)
  if spoils[key] == nil then
    local tg = shared.target(key)
    local base = tg and (tg.route and tg.parent or tg)
    local item = base and prototypes.item[base.result]
    spoils[key] = item ~= nil and (item.get_spoil_ticks() or 0) > 0
  end
  return spoils[key]
end

function truth.effect_on(t, key, mix, effect)
  if effect == "freshness" then
    if not (t.freshness and truth.spoilable(key)) then return 0 end
    local k = t.responsiveness and t.responsiveness[key] or 1
    local total = 0
    for name, dose in pairs(mix) do
      local f = t.freshness[name]
      if f and dose > 0 then total = total + f * presence(name, dose) end
    end
    return clamp(k * total, 0, 0.9)
  end
  if effect == "efficiency" then
    if not t.efficiency then return 0 end
    local k = t.responsiveness and t.responsiveness[key] or 1
    local total = 0
    for name, dose in pairs(mix) do
      local _, _, e = truth.side_base(t, key, name)
      if e ~= 0 and dose > 0 then total = total + e * presence(name, dose) end
    end
    return clamp(k * total, -0.5, 0.5)
  end
  if effect == "yield" or not effect then return truth.gain_on(t, key, mix) end
  if not t.side then return 0 end
  local k = t.responsiveness and t.responsiveness[key] or 1
  local total = 0
  for name, dose in pairs(mix) do
    local sp, po = truth.side_base(t, key, name)
    local v = effect == "speed" and sp or po
    if v ~= 0 and dose > 0 then total = total + v * presence(name, dose) end
  end
  total = k * total + agents_effect(t, key, mix, effect)  -- an agent's speed cost (none on pollution)
  if effect == "speed" then return clamp(total, -0.5, 0.5) end
  return clamp(total, -0.9, 0.6)
end

-- Premix volatility per map: likelier volatile when the pair's chemistry is aligned (the potent ones).
-- Only matters where spoiling exists (control.lua picks the item).
-- Targets added after a world was made (0.25: fluid-fed and planet targets): their responses to every
-- additive, from their own stream, with the same guarantee as generate (a real Tier 1 activator) and a
-- responsiveness drawn like a new world's. Nothing already in the truth changes.
function truth.extend_targets(t, rng, base)
  local made = {}
  for _, target in ipairs(shared.targets) do
    if not t.targets[target.key] and not target.registered and not target.own_stream then
      local by, best = {}, nil
      table.insert(made, target)
      for _, a in ipairs(shared.additives) do
        if a.fill_late then
          -- (Living additives: in their own pass below, after every target; drawn here they moved the
          -- next targets' draws, 0.62.)
        elseif a.stable_name then
          by[a.name] = by[a.stable_name]
        elseif t.traits[a.name] then
          by[a.name] = response(rng, t.traits[a.name], target, a.late and (a.tier >= 3 and 0.8 or 0.6) or nil,
            a.spent_of ~= nil, truth.quirk(t, a.name, target.key))
          if a.tier == 1 and (not best or by[a.name].score > by[best].score) then best = a.name end
        end
      end
      if best and by[best].kind ~= "activator" then
        local r = by[best]
        r.kind, r.peak = "activator", truth.spike.base * (0.5 + rng())  -- (standard: 0.05 to 0.15)
        r.opt = 3 + 3 * rng()
      end
      t.targets[target.key] = by
      if t.responsiveness and not t.responsiveness[target.key] then
        t.responsiveness[target.key] = (base[target.key] or 1) * math.exp(truth.responsiveness_sd * normal(rng))
      end
    end
  end
  for _, target in ipairs(made) do
    for _, a in ipairs(shared.additives) do
      if a.fill_late and t.traits[a.name] and not t.targets[target.key][a.name] then
        t.targets[target.key][a.name] = response(rng, t.traits[a.name], target, nil, nil, truth.quirk(t, a.name, target.key))
      end
    end
  end
  truth.promote_early(t)
end

-- Other mods' targets (0.55): every draw from a stream of its own,
-- `rng_for(name)` seeded by the map and the target's key (one per additive, the activator guarantee,
-- responsiveness and each quality agent), so a registered target's world is the same whatever else is
-- loaded and never moves another target's. Fills only what the world lacks (additives added later too).
function truth.extend_registered(t, rng_for, base)
  for _, target in ipairs(shared.targets) do
    if target.registered or target.own_stream then  -- (and the mod's own later targets, 0.63)
      local fresh = not t.targets[target.key]
      local by, best = t.targets[target.key] or {}, nil
      t.targets[target.key] = by
      for _, a in ipairs(shared.additives) do
        if not by[a.name] then
          if a.stable_name then
            by[a.name] = by[a.stable_name]
          elseif t.traits[a.name] then
            by[a.name] = response(rng_for(target.key .. ":" .. a.name), t.traits[a.name], target,
              a.late and (a.tier >= 3 and 0.8 or 0.6) or nil, a.spent_of ~= nil, truth.quirk(t, a.name, target.key))
          end
        end
        if a.tier == 1 and by[a.name] and (not best or by[a.name].score > by[best].score) then best = a.name end
      end
      if fresh and best and by[best].kind ~= "activator" then
        local rng = rng_for(target.key .. ":activator")
        local r = by[best]
        r.kind, r.peak = "activator", truth.spike.base * (0.5 + rng())  -- (standard: 0.05 to 0.15)
        r.opt = 3 + 3 * rng()
      end
      if t.responsiveness and not t.responsiveness[target.key] then
        t.responsiveness[target.key] = (base[target.key] or 1)
          * math.exp(truth.responsiveness_sd * normal(rng_for(target.key .. ":responsiveness")))
      end
      if t.quality then
        for _, a in ipairs(shared.agents) do
          t.quality[a.name] = t.quality[a.name] or {}
          if not t.quality[a.name][target.key] then
            t.quality[a.name][target.key] = draw_agent(rng_for(target.key .. ":quality:" .. a.name), a)
          end
        end
      end
    end
  end
  truth.promote_early(t)
end

function truth.generate_premix_volatility(t, rng)
  t.premix_volatile = t.premix_volatile or {}
  for _, a in ipairs(shared.premixes) do
    if t.premix_volatile[a.name] == nil and not a.fluid then
      local fa, fb = shared.additive(a.premix_of[1]).family, shared.additive(a.premix_of[2]).family
      local align = t.chem and t.chem[fa] and t.chem[fb] and math.cos(t.chem[fa] - t.chem[fb]) or 0
      t.premix_volatile[a.name] = rng() < 0.15 + 0.4 * (align + 1) / 2
    end
  end
end

return truth
