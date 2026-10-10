-- Research data: what a sample is worth to the force's knowledge. A question
-- is target x additive (or x the set of additives of a mixture): is the net gain (gain minus the
-- break-even gain that pays for the dose) above zero? A sample is paid floor + (1 - floor) x how open its
-- question still is, times the share of the remaining uncertainty its own cell can reduce, computed
-- before the sample is added. docs/balance.py simulates the same rule; keep the two in step.
local shared = require("shared")
local stats = require("scripts.stats")

local research = {}

local Z = 1.96
local RAW = {["iron-ore"] = true, ["copper-ore"] = true, stone = true, coal = true, wood = true}
research.ITEM = "es-research-data"

-- Standard normal CDF (Abramowitz and Stegun 7.1.26, error below 1.5e-7).
local function phi(x)
  local t = 1 / (1 + 0.3275911 * math.abs(x) / math.sqrt(2))
  local y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t
    * math.exp(-x * x / 2)
  return x >= 0 and 0.5 * (1 + y) or 0.5 * (1 - y)
end
research.phi = phi

-- Ore-equivalents per unit of an item, from the recipe named after it: the model's rules (an item with
-- no recipe of its own name is one raw unit, and so is a recipe loop; fluids weigh shared.data.fluid_ore).
-- Cached only when no recipe loop was met below it, or for the item the costing started from (review 0.68:
-- an inner item cached with a loop's provisional 1 made the result depend on which item was costed first,
-- which can differ between a host and a joining client).
local raw_memo, in_progress, loop_met = {}, {}, false
local function raw_cost(name)
  if RAW[name] then return 1 end
  if raw_memo[name] then return raw_memo[name] end
  if in_progress[name] then loop_met = true; return 1 end  -- a loop back to this item counts it as raw
  -- A fluid weighs shared.data.fluid_ore a unit, except the mod's own (liquid premixes): from their recipe.
  if prototypes.fluid[name] and not name:find("^es%-") then return shared.data.fluid_ore end
  local r = prototypes.recipe[name]
  -- An activated catalyst's recipe is named for its activation, not after it (0.40: it had cost 1 ore).
  local a = not r and shared.additive(name)
  if a and a.refined_from then r = prototypes.recipe[shared.refine_recipe(shared.additive(a.refined_from).spent_of)] end
  if not r then return 1 end
  local out = 0
  for _, p in pairs(r.products) do if p.name == name then out = p.amount or 1 end end
  if out <= 0 then return 1 end
  local root = next(in_progress) == nil
  if root then loop_met = false end
  in_progress[name] = true
  local cost = 0
  for _, ing in pairs(r.ingredients) do cost = cost + raw_cost(ing.name) * ing.amount end
  in_progress[name] = nil
  local value = cost / out
  if root or not loop_met then raw_memo[name] = value end
  return value
end
research.raw_cost = raw_cost

-- Ore in one batch of a target: its control trial's ingredients (the batch the dose is per).
local batch_memo = {}
local function batch_ore(target_key)
  if batch_memo[target_key] then return batch_memo[target_key] end
  local r = prototypes.recipe[shared.control_trial(target_key)]
  local ore = 0
  if r then for _, ing in pairs(r.ingredients) do ore = ore + raw_cost(ing.name) * ing.amount end end
  batch_memo[target_key] = math.max(ore, 1)
  return batch_memo[target_key]
end

-- A target's floor (0.72): what a sample of a settled question
-- still pays. In proportion to the ore its trial loses (inputs less survivors, plus its share of a science pack),
-- anchored on the cheapest trial, which keeps shared.data.floor, and at most shared.data.floor_cap_x floors; times
-- the map's science richness for the target's process mix, its spread chosen by docs/balance.py.
local RICHNESS = {standard = require("scripts.richness_standard"), harsh = require("scripts.richness_harsh")}
local lost_memo, lost_ref = {}, nil
local function lost_ore(target_key)
  if lost_memo[target_key] then return lost_memo[target_key] end
  local t = shared.target(target_key)
  local result = t and (t.result or (t.parent and t.parent.result))
  local r = prototypes.recipe[shared.control_trial(target_key)]
  local survivors = 0
  if r and result then for _, p in pairs(r.products) do if p.name == result then survivors = p.amount or 0 end end end
  local pack = storage.target_pack and storage.target_pack[target_key] or shared.pack
  local v = batch_ore(target_key) - (result and raw_cost(result) * survivors or 0) + raw_cost(pack) / shared.samples_per_pack
  lost_memo[target_key] = math.max(v, 1e-6)
  return lost_memo[target_key]
end
research.lost_ore = lost_ore
function research.floor_of(target_key)
  local D = shared.data
  if not lost_ref then
    lost_ref = math.huge
    -- (The mod's own targets only, as docs/balance.py anchors it: a cheap target another mod registers would
    -- otherwise raise every floor. The integration test's own pipe target did, doubling them.)
    for _, t in ipairs(shared.targets) do
      if not t.registered and prototypes.recipe[shared.control_trial(t.key)] then
        lost_ref = math.min(lost_ref, lost_ore(t.key))
      end
    end
  end
  local f = math.min(D.floor_cap_x * D.floor, D.floor * lost_ore(target_key) / lost_ref)
  local truth = storage.truth
  local z = truth and truth.richness
  local sd = (RICHNESS[truth and truth.strength or "standard"] or RICHNESS.standard).sd
  if z and sd > 0 then
    local t = shared.target(target_key)
    local process = t and (t.process or (t.parent and t.parent.process)) or {}
    local sum = 0
    for c, share in pairs(process) do sum = sum + share * (z[c] or 0) end
    f = f * math.exp(sd * sum)
  end
  return f
end

-- Break-even gain of a composition {name = dose} on a target, in per mille: the dose's ore over the
-- batch's (the whole dose is spent: residues are not reclaimed, 0.39).
function research.tau(target_key, mix)
  local ore = 0
  for name, dose in pairs(mix) do ore = ore + raw_cost(name) * dose end
  return ore / batch_ore(target_key) * 1000
end


-- The full cost a dose saves: the fraction of the vanilla product's cost (ore +
-- machine time + power + pollution, priced by P: shared.prices or a player's own) saved, given the dose's
-- effects (yield g, speed sp, cleanliness cl, efficiency ef, as fractions). One formula for the balance
-- model's sampler and the Dose-response chart. nil when the target has no recipe of its own name.
-- What full_saving reads from the game, per target and machine (the prices apply after): prototype
-- reads cross into the engine, and the balance sampler prices every dose of every additive.
local machine_memo = {}
local function machine_terms(target_key, P)
  local key = target_key .. "|" .. P.machine .. "|" .. (P.speed_factor or 1)
  local m = machine_memo[key]
  if m ~= nil then return m or nil end
  local base = shared.target(target_key)
  local recipe = prototypes.recipe[shared.target_recipe(base)]
  local product = recipe and recipe.products[1]
  if not (product and product.amount) then machine_memo[key] = false; return nil end
  local e = prototypes.entity[P.machine]
  local speed = e.get_crafting_speed() * (P.speed_factor or 1)
  m = {base = base, watts = e.energy_usage * 60,
       emit = e.emissions_per_second and e.emissions_per_second.pollution or 0,
       batch_ore = 1000 / research.tau(base.key, {coal = 1}),
       t0 = recipe.energy / speed / product.amount}
  machine_memo[key] = m
  return m
end

function research.full_saving(target_key, mix, g, sp, cl, ef, P)
  local m = machine_terms(target_key, P)
  if not m then return nil end
  local base, watts, emit, batch_ore, t0 = m.base, m.watts, m.emit, m.batch_ore, m.t0
  local c0 = batch_ore / base.batch + t0 * P.machine_second + watts * t0 / 1e6 * P.mj + emit * t0 * P.pollution
  local dose_ore = next(mix) and research.tau(base.key, mix) / 1000 * batch_ore or 0
  local t1 = t0 / ((1 + sp) * (1 + g))
  local c1 = (batch_ore + dose_ore) / (base.batch * (1 + g)) + t1 * P.machine_second
    + watts * (1 - ef) * t1 / 1e6 * P.mj + emit * t0 * (1 / (1 + sp) - cl) / (1 + g) * P.pollution
  return (c0 - c1) / c0
end

-- Prices on a planet (the per-planet mask decided with the full cost, built 0.50): pollution is not
-- priced where the planet has no pollutant (Vulcanus, Fulgora, Aquilo, platforms); at late prices,
-- whose power is solar, power costs Nauvis's sunlight over the planet's, never more than the early
-- (fuel) price, since any planet can burn fuel. Early prices are fuel and do not change; a player's own
-- prices keep their power. Returns the prices and what changed: {pollution = true, power = factor}.
function research.price_on(P, skey)
  local out, changed = shared.copy(P), {}
  local loc = prototypes.space_location[skey]
  local surf = loc or prototypes.surface[skey]
  if not (loc and loc.pollutant_type) and (out.pollution or 0) > 0 then out.pollution, changed.pollution = 0, true end
  if P.preset == "late" and surf then
    local default = prototypes.surface_property["solar-power"].default_value
    local function solar(props) return props and props["solar-power"] or default end
    local nauvis = prototypes.space_location.nauvis and solar(prototypes.space_location.nauvis.surface_properties) or default
    local here = math.max(solar(surf.surface_properties), 1e-6)
    local mj = math.min(P.mj * nauvis / here, shared.prices.early.mj)
    if math.abs(mj - P.mj) > 1e-12 then out.mj, changed.power = mj, mj / P.mj end
  end
  return out, changed
end

-- A sample key ("coal:3", "coal:3+stone:2", "control") -> its question ("coal", "coal+stone") and mix.
local function parse(key)
  if key == "control" then return nil end
  local names, mix = {}, {}
  for part in key:gmatch("[^+]+") do
    local name, dose = part:match("^(.+):(%d+)$")
    if not name then return nil end
    name = shared.split_band(name)  -- every temperature band of a liquid premix: one question
    table.insert(names, name)
    mix[name] = tonumber(dose)
  end
  table.sort(names)
  return table.concat(names, "+"), mix
end
research.question_of = function(key) return (parse(key)) end

-- (0.72) A product's results indexed once, until evidence changes (stats.add bumps the version): each
-- question's keys, each additive's tested doses, the questions with a dose sampled twice alone. Before, the
-- screen scanned every result once per additive, band and effect, and some counts did so once per result: a
-- save with many results froze the game for a minute on opening the screen. Runtime only:
-- rebuilt after a load.
local INDEX = setmetatable({}, {__mode = "k"})
function research.index(obs)
  local v = storage.evidence_version or 0
  local ix = INDEX[obs]
  if ix and ix.v == v then return ix end
  ix = {v = v, questions = {}, doses = {}, alone = {}}
  for key, acc in pairs(obs) do
    if key ~= "control" then
      local q = parse(key)
      if q then
        local list = ix.questions[q]
        if not list then list = {}; ix.questions[q] = list end
        table.insert(list, key)
      end
      local name, dose = key:match("^([^+]+):(%d+)$")
      if name and acc.n > 0 then
        local d = ix.doses[name]
        if not d then d = {}; ix.doses[name] = d end
        table.insert(d, tonumber(dose))
        if acc.n >= 2 then ix.alone[q] = true end
      end
    end
  end
  for _, d in pairs(ix.doses) do table.sort(d) end
  INDEX[obs] = ix
  return ix
end

-- How open a question is on a target's observations, and the best cell by lower confidence bound.
-- Returns openness (0..1), best cell key, and the pieces of the answer (net, se) for the tooltip.
function research.question_state(obs, target_key, question)
  local c = obs.control and stats.summary(obs.control)
  if not (c and c.var) then return 1 end
  local best
  -- (0.72) The question's doses tested once, pooled: a sweep that never
  -- repeats a dose no longer keeps a question fully open (it paid the full rate on every sample). Repeated
  -- doses and scrap samples are left out: a careful study earns what it did.
  local pooled_n, pooled_net = 0, 0
  for _, key in ipairs(research.index(obs).questions[question] or {}) do
    local acc = obs[key]
    if acc.n >= 1 then
      local _, mix = parse(key)
      do
        local tau = research.tau(target_key, mix)
        if acc.n - (acc.scrap_n or 0) == 1 and acc.n == 1 then
          pooled_n = pooled_n + 1
          pooled_net = pooled_net + acc.sum - (c.mean + tau)
        end
        if acc.n >= 2 then
          local s = stats.summary(acc)
          local se = math.max(math.sqrt(s.var / s.n + c.var / c.n), 1e-9)
          local net = s.mean - c.mean - tau
          if not best or net - Z * se > best.net - Z * best.se then
            best = {key = key, net = net, se = se, n = s.n}
          end
        end
      end
    end
  end
  local band = shared.data.band * 1000
  local o = 1
  if best then o = math.min(1, (Z * best.se / band) ^ 2) * (1 - phi(-best.net / best.se)) end
  if pooled_n >= 2 then
    local se = math.max(math.sqrt(c.var / pooled_n + c.var / c.n), 1e-9)
    local net = pooled_net / pooled_n
    o = math.min(o, math.min(1, (Z * se / band) ^ 2) * (1 - phi(-net / se)))
  end
  if not best then return o end
  return o, best.key, best
end

-- Premixes by evidence (slice 3; 0.72, moved here so the Mixtures tab can show it): a two-additive mixture of
-- one member of each of two classic families unlocks that pair's premix (its volatile item where spoiling
-- exists and the map made it volatile, else its stable one) once its 2x2 interaction on yield is a synergy
-- (positive, p < 0.05) with at least shared.premix.discovery_n samples in each of the four groups.
-- Returns nil when the pair has no premix; else {recipe, counts = {mixture, a alone, b alone, control},
-- a, b, ready}, ready when every group has enough samples.
local additive_index
function research.premix_gate(force, obs, key)
  local a1, d1, a2, d2 = key:match("^([^+:]+):(%d+)%+([^+:]+):(%d+)$")
  if not a1 then return nil end
  -- (0.72) A member may carry its temperature or ripeness band ("water@3"): the additive is its base name, and
  -- its group alone is at the same band (each band a design of its own; before, a banded mixture never unlocked).
  local b1, b2 = shared.split_band(a1), shared.split_band(a2)
  local A, B = shared.additive(b1), shared.additive(b2)
  if not (A and B) or A.agent or B.agent then return nil end  -- quality agents stay out of chemistry
  if A.family == B.family or A.spent_of or B.spent_of or A.premix_of or B.premix_of then return nil end
  if not additive_index then
    additive_index = {}
    for i, a in ipairs(shared.additives) do additive_index[a.name] = i end
  end
  local f1, f2 = b1, b2
  if additive_index[f1] > additive_index[f2] then f1, f2 = f2, f1 end
  local stable = shared.premix_name(f1, f2)
  -- Liquid premixes (fluids) have no volatile twin: temperature instead.
  local volatile = script.feature_flags.spoiling and not shared.additive(stable).fluid and storage.truth.premix_volatile
    and storage.truth.premix_volatile[stable]
  local recipe = force.recipes[shared.premix_recipe(f1, f2, volatile)]
  if not recipe then return nil end
  local groups = {obs[key], obs[a1 .. ":" .. d1], obs[a2 .. ":" .. d2], obs.control}
  local counts, ready = {}, true
  for i = 1, 4 do
    counts[i] = groups[i] and groups[i].n or 0
    if counts[i] < shared.premix.discovery_n then ready = false end
  end
  return {recipe = recipe, counts = counts, groups = groups, a = a1, b = a2, da = tonumber(d1), db = tonumber(d2),
    stable = stable, f1 = f1, f2 = f2,
    ready = ready}
end

-- An additive's most open tested dose (the port's Screening page, for the selected additive, 0.72): the dose alone whose own result is furthest from
-- settled, by question_state's arithmetic on that cell; a dose sampled once counts fully open. Ties go to
-- fewer samples, then the lower dose. Only what was tested: nil before the first sample.
function research.most_open_dose(obs, target_key, additive)
  local c = obs.control and stats.summary(obs.control)
  local band = shared.data.band * 1000
  local best_d, best_o, best_n
  for _, d in ipairs(research.index(obs).doses[additive] or {}) do
    local acc = obs[additive .. ":" .. d]
    local o = 1
    if acc.n >= 2 and c and c.var then
      local s = stats.summary(acc)
      local se = math.max(math.sqrt(s.var / s.n + c.var / c.n), 1e-9)
      local net = s.mean - c.mean - research.tau(target_key, {[additive] = d})
      o = math.min(1, (Z * se / band) ^ 2) * (1 - phi(-net / se))
    end
    if not best_d or o > best_o or (o == best_o and acc.n < best_n) then best_d, best_o, best_n = d, o, acc.n end
  end
  return best_d
end

-- The best tested composition on a target (the port's Best composition page, 0.49): over every single or mixture tested at
-- least twice, the highest lower bound of net gain, by the same arithmetic as
-- question_state. Returns {key, mix, net, se, n} or nil. Only what was tested: never a fitted optimum.
function research.best_composition(obs, target_key)
  local c = obs.control and stats.summary(obs.control)
  if not (c and c.var) then return nil end
  local best
  for key, acc in pairs(obs) do
    if key ~= "control" and acc.n >= 2 then
      local q, mix = parse(key)
      if q and mix then
        local s = stats.summary(acc)
        local se = math.max(math.sqrt(s.var / s.n + c.var / c.n), 1e-9)
        local net = s.mean - c.mean - research.tau(target_key, mix)
        if not best or net - Z * se > best.net - Z * best.se then
          best = {key = key, mix = mix, net = net, se = se, n = s.n}
        end
      end
    end
  end
  return best
end
research.Z = Z

-- The force's memory of each question: the lowest openness it ever reached. Clearing a target or
-- rebuilding stations does not re-pay what was settled.
-- `peek`: read without writing (the screen only looks; review 0.68: looking lowered later pay).
local function remembered(force_index, target_key, question, o, skey, peek)
  local id = (skey or "nauvis") .. "|" .. target_key .. "|" .. question  -- a question per planet
  if peek then
    local m = storage.data_memory and storage.data_memory[force_index] and storage.data_memory[force_index][id]
    return m and m < o and m or o
  end
  storage.data_memory = storage.data_memory or {}
  local mem = storage.data_memory[force_index] or {}
  storage.data_memory[force_index] = mem
  if mem[id] and mem[id] < o then o = mem[id] end
  -- (0.72) The first time a question settles, for the achievements (control.lua sets the callback).
  if o < shared.data.settled and not (mem[id] and mem[id] < shared.data.settled) and research.on_settled then
    research.on_settled(force_index, question)
  end
  mem[id] = o
  return o
end

-- Quality agents (decided 2026-10-02): a sample of an agent alone is paid on its quality question, how
-- precisely the upgrade rate at that dose is known: (Wilson half-width / quality band)^2, capped at 1.
-- `qual` is the pool's quality counts for the target ({key = {k, b}}).
function research.quality_openness(q)
  if not q or q.b <= 0 then return 1 end
  local _, lo, hi = stats.wilson(q.k, q.b)
  return math.min(1, ((hi - lo) / 2 / shared.data.quality_band) ^ 2)
end
local function single_agent(key)
  local name = key:match("^([^+:]+):%d+$")
  return name and shared.is_agent(name) and name or nil
end

-- Data a sample under `key` is worth, before it is added to the pool's observations `obs` of its target.
function research.rate(force_index, obs, target_key, key, skey, qual, peek)
  local floor = research.floor_of(target_key)
  if qual and single_agent(key) then
    local o = remembered(force_index, target_key, "quality:" .. key, research.quality_openness(qual[key]), skey, peek)
    return floor + (1 - floor) * o
  end
  local c = obs.control
  local nc = c and c.n or 0
  if key == "control" then
    -- A control serves the target's most open question, in the share it can reduce.
    local best_o, tested = 0, false
    for q in pairs(research.index(obs).questions) do
      do
        tested = true
        local o, _, b = research.question_state(obs, target_key, q)
        o = remembered(force_index, target_key, q, o, skey, peek)
        if b and nc > 0 then o = o * (1 / nc) / (1 / b.n + 1 / nc) end
        if o > best_o then best_o = o end
      end
    end
    if not tested then best_o = nc < shared.data.control_free and 1 or 0 end
    return floor + (1 - floor) * best_o
  end
  local q = research.question_of(key)
  if not q then return floor end
  -- (0.72) A set of additives pays the floor until each member has two samples of one dose alone here: a
  -- pair farm (every pair a new question) paid the full rate without end.
  if q:find("+", 1, true) then
    local alone = research.index(obs).alone
    for name in q:gmatch("[^+]+") do
      if not alone[name] then return floor end
    end
  end
  local o, best_key, b = research.question_state(obs, target_key, q)
  o = remembered(force_index, target_key, q, o, skey, peek)
  if b and key == best_key and nc > 0 then o = o * (1 / b.n) / (1 / b.n + 1 / nc) end
  return floor + (1 - floor) * o
end

-- Samples until a question is settled for the player (0.67): the net
-- gain's interval clears break-even (it pays, or it does not), or is pinned within shared.data.band of it.
-- The same exits as "clearly pays" and the research data's settled questions. With k more
-- samples in the current cell:control proportion and means held, se_k = se * sqrt(n / (n + k)).
-- (Research data keeps its own openness: a paying dose stays worth refining.)
function research.settled(net, se)
  return net - Z * se > 0 or net + Z * se < 0 or Z * se < shared.data.band * 1000
end
function research.samples_to_settle(b, nc)
  if research.settled(b.net, b.se) then return 0 end
  local n = b.n + nc
  local band = shared.data.band * 1000
  local k_band = n * ((Z * b.se / band) ^ 2 - 1)
  local k_net = math.abs(b.net) > 1e-9 and n * ((Z * b.se / math.abs(b.net)) ^ 2 - 1) or math.huge
  return math.max(1, math.ceil(math.min(k_band, k_net)))
end
-- Controls to add so the control's share of the spread matches the cell's (the balanced design): for the
-- target's most open question. nil when there is nothing to balance against yet.
function research.controls_needed(obs, target_key)
  local c = obs.control and stats.summary(obs.control)
  if not (c and c.var and c.var > 0) then return nil end
  local best_o, best
  for q in pairs(research.index(obs).questions) do
    do
      local o, _, b = research.question_state(obs, target_key, q)
      if b and (not best_o or o > best_o) then best_o, best = o, b end
    end
  end
  if not best then return nil end
  local s = stats.summary(obs[best.key])
  if not (s and s.var and s.var > 0) then return nil end
  return math.max(0, math.ceil(s.n * math.sqrt(c.var / s.var)) - c.n)
end

-- For the Screening grid: a single additive's question on a target, as the next sample at its best cell
-- would be paid, its state (open or settled) and the samples left to settle it.
function research.row(force_index, obs, target_key, additive, skey, qual, at_key)
  if not obs then return nil end
  if qual and shared.is_agent(additive) then
    -- An agent: its best dose by upgrade rate, as the next sample there would be paid.
    local best_key, best_q
    for key, q in pairs(qual) do
      if single_agent(key) == additive and q.b > 0 and (not best_q or q.k / q.b > best_q.k / best_q.b) then
        best_key, best_q = key, q
      end
    end
    local o = research.quality_openness(best_q)
    local mem = storage.data_memory and storage.data_memory[force_index]
    local m = best_key and mem and mem[(skey or "nauvis") .. "|" .. target_key .. "|quality:" .. best_key]
    if m and m < o then o = m end
    local floor = research.floor_of(target_key)
    local rate = floor + (1 - floor) * o
    -- Openness falls as 1 / units rolled: units to settle, then samples at this dose's units per sample.
    local left
    if best_q and o >= shared.data.settled then
      local units = best_q.b * (o / shared.data.settled - 1)
      left = math.ceil(units / math.max(best_q.b / math.max(best_q.n, 1), 1))
    end
    return {rate = rate, state = o < shared.data.settled and "settled" or "open", best = best_key, quality = true,
      left = left}
  end
  local o, best_key, b = research.question_state(obs, target_key, additive)
  local mem = storage.data_memory and storage.data_memory[force_index]
  local m = mem and mem[(skey or "nauvis") .. "|" .. target_key .. "|" .. additive]
  if m and m < o then o = m end
  local floor = research.floor_of(target_key)
  local rate = floor + (1 - floor) * o
  -- (0.72, user: the Net column read at a dose the Best dose column did not show) The gain after cost at
  -- the cell asked for, the best yield's, by question_state's arithmetic. The rate stays the question's.
  if at_key then
    b = nil
    local c = obs.control and stats.summary(obs.control)
    local acc = obs[at_key]
    if c and c.var and acc and acc.n >= 2 then
      local _, mix = parse(at_key)
      local s = stats.summary(acc)
      local se = math.max(math.sqrt(s.var / s.n + c.var / c.n), 1e-9)
      b = {key = at_key, net = s.mean - c.mean - research.tau(target_key, mix), se = se, n = s.n}
    end
  end
  local nc = obs.control and obs.control.n or 0
  local left = b and nc >= 2 and b.n >= 2 and research.samples_to_settle(b, nc) or nil
  return {rate = rate, state = left == 0 and "settled" or "open", best = best_key, net = b and b.net,
    half = b and Z * b.se, left = left ~= 0 and left or nil}
end

return research
