-- Constants shared by the data and control stages.
local shared = {
  max_dose = 9,            -- additive units per trial: 1..max_dose (0 = control recipe)
  noise_sd = 0.12,         -- per-trial yield noise, as a fraction of the batch (docs/balance.md)
  noise_speed = 0.10,      -- per-trial noise on the measured speed (fraction of nominal)
  noise_pollution = 0.30,  -- per-trial noise on the measured emissions: pollution is hard to measure
  noise_freshness = 0.03,  -- error on a sample's spoil reading (absolute): fresh inputs leave nothing to see
  pack = "automation-science-pack",  -- fallback pack for a sample
  samples_per_pack = 4,    -- one science pack pays for this many analysed samples (docs/balance.md)
  station_throughput_step = 1,  -- samples per pack added by each level of Analysis productivity
  achievement_samples = 10000,  -- Law of large numbers: samples analysed by a force
  progress_ticks = 18000,  -- the Progress tab's snapshots: every 5 game minutes
  progress_per = 100,      -- the efficiency graph: empirical science packs per this many samples
  progress_points = 4000,  -- kept per force; beyond, every other old point goes
  achievement_settled = 100,    -- Publish or perish: questions settled by a force
  fit_lof_p = 0.05,        -- a fit's lack-of-fit p below this misses a pattern in the doses
  bound_miss = 0.025,      -- a 95% range's lower bound is above the truth this often (one side of 5%)
  analysis_ticks = 300,    -- a station analyses one sample per this many ticks (0.72: was 30; user: too quick beside the benches)
  station_slots = 36,       -- (before data-final-fixes sizes it to its layout, 0.72)
  station_data_slots = 2,   -- empirical science packs out
                           -- (10: one per tier the targets use, planets' packs included)
  station_sample_slots = 4, -- (0.72) samples waiting, of the packs the station holds; then scrap, packs out, one slot per pack
}

-- Additives. Families are visible to the player; traits are hidden and per map. `parent` makes an
-- additive's traits close to another's (stone brick is made of stone; lubricant of heavy oil).
-- Tier 1 runs on the simple bench (recipe variants); tier 2 (oil era) only on the advanced bench.
-- Fluids are dosed in units up to max_dose; the hidden curves see every dose on the item scale
-- (dose x shared.max_dose / max_dose), so 100 units of a fluid sit where 9 units of an item do.
shared.additives = {
  {name = "coal", family = "carbon", tier = 1},
  -- Wood (0.70): not early; with Space Age its dosing waits for Tree seeding (shared.unlocked).
  {name = "wood", family = "organic", tier = 1, unlock = "tree-seeding"},
  {name = "stone", family = "mineral", tier = 1},
  {name = "stone-brick", family = "mineral", parent = "stone", tier = 1},
  {name = "copper-cable", family = "metal", tier = 1},
  {name = "sulfur", family = "sulfur", tier = 2},
  {name = "plastic-bar", family = "polymer", tier = 2},
  {name = "solid-fuel", family = "carbon", tier = 2},
  {name = "water", family = "aqueous", tier = 2, fluid = true},
  {name = "crude-oil", family = "oil", tier = 2, fluid = true},
  {name = "heavy-oil", family = "oil", parent = "crude-oil", tier = 2, fluid = true},
  {name = "light-oil", family = "oil", parent = "crude-oil", tier = 2, fluid = true},
  {name = "petroleum-gas", family = "oil", parent = "crude-oil", tier = 2, fluid = true},
  {name = "lubricant", family = "oil", parent = "heavy-oil", tier = 2, fluid = true},
  {name = "sulfuric-acid", family = "sulfur", parent = "sulfur", tier = 2, fluid = true},
  -- Residues by family (0.39): every solid additive leaves its family's
  -- residue, which can be dosed too (a faint echo of its family) and, once a station shows it still
  -- helps, activated into a catalyst (its direction, amplified). Item names are kept from when each
  -- residue belonged to one additive (`spent_of`: the family's first member), so saves keep their items,
  -- evidence and premixes. "late": generated after everything else.
  {name = "es-spent-coal", family = "residue", tier = 2, late = true, spent_of = "coal", residue_of = "carbon"},
  {name = "es-spent-wood", family = "residue", tier = 2, late = true, spent_of = "wood", residue_of = "organic"},
  {name = "es-spent-stone", family = "residue", tier = 2, late = true, spent_of = "stone", residue_of = "mineral"},
  {name = "es-spent-copper-cable", family = "residue", tier = 2, late = true, spent_of = "copper-cable", residue_of = "metal"},
  {name = "es-spent-sulfur", family = "residue", tier = 2, late = true, spent_of = "sulfur", residue_of = "sulfur"},
  {name = "es-spent-plastic-bar", family = "residue", tier = 2, late = true, spent_of = "plastic-bar", residue_of = "polymer"},
  {name = "es-refined-coal", family = "catalyst", tier = 3, late = true, refined_from = "es-spent-coal"},
  {name = "es-refined-wood", family = "catalyst", tier = 3, late = true, refined_from = "es-spent-wood"},
  {name = "es-refined-stone", family = "catalyst", tier = 3, late = true, refined_from = "es-spent-stone"},
  {name = "es-refined-copper-cable", family = "catalyst", tier = 3, late = true, refined_from = "es-spent-copper-cable"},
  {name = "es-refined-sulfur", family = "catalyst", tier = 3, late = true, refined_from = "es-spent-sulfur"},
  {name = "es-refined-plastic-bar", family = "catalyst", tier = 3, late = true, refined_from = "es-spent-plastic-bar"},
}
-- Retired in 0.39 (stone brick's residue and catalyst merged into stone's: the mineral family's).
shared.retired_additives = {["es-spent-stone-brick"] = "es-spent-stone", ["es-refined-stone-brick"] = "es-refined-stone"}
-- Premixes (slice 3): one per pair of additives from different families (the pair a station found to
-- be synergistic is the premix), from the base additives: tier 1, oil era and activated catalysts
-- (residues are degraded, premixes are not remixed). A stable and a volatile item per pair; the map
-- decides which one an unlock enables. The phase decides the recipe: two solids make a blend (an
-- assembler), a solid and a fluid a slurry (a chemical plant, with water), two fluids an emulsion (a
-- chemical plant, with sulfur as emulsifier).
-- `concentrate` (decided 2026-10-02): a premix is a concentrate, like an activated catalyst: every input
-- is multiplied by it, outputs unchanged, so its potency at low doses is paid for (docs/balance.py rule:
-- neither premixes nor catalysts the best choice on more than 70% of their cells).
shared.premix = {item = 2, fluid = 20, water = 20, sulfur = 1, out = 2, concentrate = 5, concentrate_catalyst = 1, seconds = 4, spoil_ticks = 3 * 60 * 60,
  -- Liquid premixes (emulsions, slurries) are fluids (decided 2026-09-30), made at `cold` degrees; the
  -- temperature bands run from cold to hot (the hottest heater). Temperature takes the place of
  -- volatility for them (fluids cannot spoil).
  fluid_out = 20, cold = 15, hot = 90, max_temperature = 100,
  discovery_n = 10}  -- (samples in each of a synergy's four groups to unlock its premix; was control.lua's DISCOVERY_MIN_N)
function shared.premix_name(a, b, volatile) return "es-premix-" .. a .. "-" .. b .. (volatile and "-v" or "") end
function shared.premix_recipe(a, b, volatile) return shared.premix_name(a, b, volatile) end
-- Fluid heaters (decided 2026-10-01): any fluid in, the same fluid out at their temperature (a boiler
-- in output-to-separate-pipe mode without filters). Blending reaches anything between.
-- `unlock`: the technology that unlocks it (default: the one that unlocks its vanilla original). The
-- burner heater waits for the method itself (the boiler is unlocked before the mod has anything to heat).
shared.heaters = {{name = "es-fluid-heater", from = "boiler", temperature = 60, unlock = "es-thermal-studies"},
                  {name = "es-heat-fluid-heater", from = "heat-exchanger", temperature = 90, unlock = "es-thermal-studies"},
                  -- The pressure heater (0.61; 0.70: anywhere, as cold
                  -- is): it burns only pressure charges (tungsten carbide from Vulcanus), so hot dosing away
                  -- from Vulcanus needs a supply line, as cold needs Aquilo's fluoroketone. With Space Age.
                  {name = "es-pressure-heater", from = "boiler", temperature = 500, unlock = "es-pressure-heating",
                   fuel_category = "es-pressure", requires = "space-age", sprites = "pressure", badge = "tungsten-carbide",
                   ingredients = {{type = "item", name = "boiler", amount = 1}, {type = "item", name = "tungsten-plate", amount = 10}}}}
-- The pressure heater's only fuel (0.70): a tungsten carbide (the liner it wears out) and solid fuel, holding
-- exactly its solid fuel's energy (user: the heater takes steam too; a charge with more energy than its fuel
-- would be free power, docs/balance.py stops on it). How many solid fuel a charge holds is set by rule H1 (a
-- yellow belt of science at a hot optimum burns 1 to 10 carbide a minute).
shared.pressure_charge = {item = "es-pressure-charge", carbide = 1, solid_fuel = 4, solid_fuel_mj = 12, seconds = 2}
shared.pressure_charge.fuel_mj = shared.pressure_charge.solid_fuel * shared.pressure_charge.solid_fuel_mj
shared.fluid_max_temperature = 500  -- fluid additives' and liquid premixes' ceiling (the pressure heater's)
-- Chilled twins (0.61): a fluid additive's own minimum is its default temperature, so cold needs a twin
-- (default -150, ceiling its fluid's default), made in a cryogenic plant from the fluid and cold fluoroketone.
-- A hopper takes it wherever its fluid is dosed; evidence counts it as that fluid at its temperature.
shared.chilled = {prefix = "es-chilled-", temperature = -150, fluoroketone = 10, amount = 100, unlock = "es-chilling"}
-- The chiller (0.71, user: a building, not a recipe per fluid): a boiler burning cold charges, set to warm what
-- passes by `warm` degrees (a boiler moves fluid only while it heats), after which the script sets everything
-- leaving it to shared.chilled.temperature. Liquid premixes have that as their minimum, so they chill in
-- place; vanilla fluids keep their twins (their minimum is vanilla's). It takes fluid at the premixes' making
-- temperature (warmer than cold + warm does not pass).
shared.chiller = {name = "es-fluid-chiller", warm = 1}
-- The cold charge: what chilling in a cryogenic plant cost per unit (shared.chilled: cold fluoroketone in, hot
-- out), packed into an item, so cold away from Aquilo needs a supply line as heat needs Vulcanus's carbide.
-- fuel_mj is set by rule C1 (docs/balance.py: a yellow belt of science at a cold optimum burns 1 to 10 a
-- minute). A premix holds 1 kJ per unit and degree (the game's default heat capacity).
shared.cold_charge = {item = "es-cold-charge", fuel_mj = 1, seconds = 2, heat_kj = 1}
shared.cold_charge.units = shared.cold_charge.fuel_mj * 1000 / (shared.cold_charge.heat_kj * shared.chiller.warm)
shared.cold_charge.fluoroketone = shared.cold_charge.units * shared.chilled.fluoroketone / shared.chilled.amount
table.insert(shared.heaters, {name = shared.chiller.name, from = "boiler", chill = true,
  temperature = shared.premix.cold + shared.chiller.warm, unlock = shared.chilled.unlock,
  fuel_category = "es-cold", requires = "space-age", sprites = "chiller", tower = true,
  ingredients = {{type = "item", name = "boiler", amount = 1}, {type = "item", name = "lithium-plate", amount = 10}}})
function shared.chilled_of(fluid) return shared.chilled.prefix .. fluid end
-- A fluid's usual temperature, its evidence unsuffixed and its effect as drawn: a liquid premix's is the one it
-- is made at (since 0.71 its minimum is the chilled cold), a vanilla fluid's its default. Control stage.
function shared.usual_temp(name)
  local a = shared.additive(name)
  if a and a.premix_of then return shared.premix.cold end
  local proto = prototypes and prototypes.fluid[name]
  return proto and proto.default_temperature or shared.premix.cold
end
-- The chilled twin of a fluid if it exists (control stage: premixes have none, nor games without Space Age).
function shared.chilled_twin(fluid)
  local name = shared.chilled.prefix .. fluid
  return prototypes and prototypes.fluid[name] and name or nil
end
-- Temperature bands of fluid evidence (decided 2026-10-01): 15-degree bands over Nauvis's reach (cold to
-- hot, 90 inclusive); since 0.61 30-degree bands beyond it, down to the chilled twins' -150 and up to the
-- pressure heater's 500. Ids: 0 to bands - 1 within, negative colder, bands and up hotter. A sample's key
-- names its band ("lubricant@-2:5"), so the best temperature can be found.
shared.premix.band_width = 15
shared.premix.bands = math.floor((shared.premix.hot - shared.premix.cold) / shared.premix.band_width)
shared.temp_axis = {min = -150, max = 500, wide = 30}
function shared.temp_band(t)
  local P, A = shared.premix, shared.temp_axis
  if t < P.cold then return -math.ceil((P.cold - t) / A.wide) end
  if t > P.hot then return P.bands + math.floor((t - P.hot - 1e-9) / A.wide) end
  return math.max(0, math.min(P.bands - 1, math.floor((t - P.cold) / P.band_width)))
end
function shared.band_range(b)
  local P, A = shared.premix, shared.temp_axis
  if b < 0 then return P.cold + b * A.wide, P.cold + (b + 1) * A.wide end
  if b >= P.bands then local lo = P.hot + (b - P.bands) * A.wide; return lo, lo + A.wide end
  return P.cold + b * P.band_width, P.cold + (b + 1) * P.band_width
end
function shared.band_caption(b)
  local lo, hi = shared.band_range(b)
  return string.format("%d to %d", lo, hi)
end
-- Every band id, coldest first.
function shared.all_bands()
  local P, A = shared.premix, shared.temp_axis
  local out = {}
  for b = -math.ceil((P.cold - A.min) / A.wide), P.bands - 1 + math.ceil((A.max - P.hot) / A.wide) do
    table.insert(out, b)
  end
  return out
end
-- "name@2" -> "name", 2; "name@-1" -> "name", -1; a ripeness band too, "name~2" -> "name", 2 (0.62: its
-- callers want the additive); "name" -> "name", nil.
function shared.split_band(name)
  local base, b = name:match("^(.-)[@~](%-?%d+)$")
  if base then return base, tonumber(b) end
  return name, nil
end
-- Additives from a mod that is not loaded are dropped (as targets are).
do
  local active = (mods) or (script and script.active_mods) or {}
  for i = #shared.additives, 1, -1 do
    local req = shared.additives[i].requires
    if req and not active[req] then table.remove(shared.additives, i) end
  end
end
-- Ripeness (0.62): a living additive's dose carries the mean spoil fraction of the units it took; evidence
-- is kept per band of 20% ("yumako-mash~2:4"), the freshest band unsuffixed.
shared.ripe = {bands = 5, width = 0.25}
function shared.ripe_band(r) return math.max(0, math.min(shared.ripe.bands - 1, math.floor(r * shared.ripe.bands))) end
function shared.ripe_bands()
  local out = {}
  for b = 0, shared.ripe.bands - 1 do table.insert(out, b) end
  return out
end
function shared.ripe_range(b) return 100 * b / shared.ripe.bands, 100 * (b + 1) / shared.ripe.bands end

shared.premixes = {}
do
  local bases = {}
  -- Residues are not premixed; activated catalysts are (re-allowed 2026-10-02 with the user: merging
  -- the two systems should be rewarded; as concentrates of concentrates they are the top rung, priced
  -- by docs/balance.py's rule).
  for _, a in ipairs(shared.additives) do
    if not a.spent_of and a.family ~= "biological" then table.insert(bases, a) end  -- (living: never premixed)
  end
  for i = 1, #bases do
    for j = i + 1, #bases do
      local A, B = bases[i], bases[j]
      if A.family ~= B.family then
        local phase = (A.fluid and B.fluid) and "emulsion" or ((A.fluid or B.fluid) and "slurry" or "blend")
        -- Emulsions and slurries are fluids: no volatile twin (temperature instead).
        for _, volatile in ipairs(phase == "blend" and {false, true} or {false}) do
          local p = {name = shared.premix_name(A.name, B.name, volatile), family = "premix-" .. A.name .. "-" .. B.name,
            tier = 4, late = true, premix_of = {A.name, B.name}, phase = phase, volatile = volatile or nil,
            stable_name = volatile and shared.premix_name(A.name, B.name) or nil, fluid = phase ~= "blend" or nil}
          table.insert(shared.additives, p)
          if not volatile then table.insert(shared.premixes, p) end
        end
      end
    end
  end
end

shared.refine = {spent = 12, acid = 20, seconds = 5}  -- per activated catalyst, from its residue (0.64: 10 -> 12, the
-- dear planet targets put catalysts past the net-ore rule at harsh; docs/balance.py BALANCE_REFINE_SPENT what-if)
function shared.refine_recipe(spent_of) return "es-refine-" .. spent_of end
function shared.refined_of(spent_of) return "es-refined-" .. spent_of end
-- Living additives (Gleba, 0.62): their effect depends on how far they have
-- spoiled. Appended last, after every premix and catalyst: hidden traits are drawn in list order from shared
-- streams, and inserted mid-list they moved every later additive's draws on new maps (a freshness test on one
-- seed caught it). Filled like a missing classic additive (`fill_late`); with Space Age; never premixed;
-- spoilage does not spoil: a plain member of the family.
do
  local active = (mods) or (script and script.active_mods) or {}
  if active["space-age"] then
    for _, name in ipairs({"yumako-mash", "jelly", "nutrients", "pentapod-egg", "bioflux"}) do
      table.insert(shared.additives, {name = name, family = "biological", tier = 2, living = true, late = true, fill_late = true})
    end
    table.insert(shared.additives, {name = "spoilage", family = "biological", tier = 2, late = true, fill_late = true})
  end
end
for _, a in ipairs(shared.additives) do a.max_dose = a.fluid and 100 or shared.max_dose end
shared.tier1 = {}
for _, a in ipairs(shared.additives) do if a.tier == 1 then table.insert(shared.tier1, a) end end
-- The early set (0.70): what a player can automate
-- from the start. The tier 1 additives without an unlock; "tier 1" stays the classic five (the benches'
-- recipes, the hidden world's guarantee scan).
shared.early = {}
for _, a in ipairs(shared.tier1) do if not a.unlock then table.insert(shared.early, a) end end
function shared.is_early(name)
  for _, a in ipairs(shared.early) do if a.name == name then return true end end
  return false
end
-- Whether a force may dose an additive: one with an `unlock` waits for that technology where it exists
-- (Tree seeding is Space Age's), on maps whose world has the early law (older saves keep dosing wood).
function shared.unlocked(force, a)
  if not a.unlock or not (storage.truth and storage.truth.early_law) then return true end
  local tech = prototypes.technology[a.unlock] and force.technologies[a.unlock]
  return tech == nil or tech.researched
end
-- Additives by name (an index: this is looked up per craft and per sample).
local by_name = {}
for _, a in ipairs(shared.additives) do by_name[a.name] = a end
-- Quality agents (decided 2026-10-01): rare vanilla items that raise the
-- chance a craft comes out one quality tier up. Only with the quality mod. Kept out of
-- shared.additives, which the hidden world's draws loop over (adding them there would change every
-- map); found by name like any additive. `rarity` orders their strength (rarer is stronger, about
-- 5-15% at the best dose: scripts/truth.lua).
local function mod_active(name)
  if mods then return mods[name] ~= nil end                                    -- data stage
  if script and script.active_mods then return script.active_mods[name] ~= nil end  -- control stage
  return false
end
shared.quality_on = mod_active("quality")
shared.quality_min_units = 50  -- units rolled before an upgrade rate is shown or output (port Q)
shared.agents = {}
if shared.quality_on then
  local defs = {{name = "uranium-235", rarity = 0.5}}
  if mod_active("space-age") then
    table.insert(defs, {name = "lithium-plate", rarity = 0.3})
    table.insert(defs, {name = "tungsten-carbide", rarity = 0.6})
    table.insert(defs, {name = "holmium-plate", rarity = 0.8})
  end
  for _, d in ipairs(defs) do
    local a = {name = d.name, family = "quality", tier = 2, agent = true, rarity = d.rarity, max_dose = shared.max_dose}
    table.insert(shared.agents, a)
    by_name[a.name] = a
  end
end
function shared.additive(name) return by_name[name] end
function shared.is_agent(name) local a = by_name[name]; return a ~= nil and a.agent == true end
-- Every additive a player can dose: the hidden world's list, then the agents (for screens and dosing).
shared.all_additives = {}
for _, a in ipairs(shared.additives) do table.insert(shared.all_additives, a) end
for _, a in ipairs(shared.agents) do table.insert(shared.all_additives, a) end
function shared.signal_type(name) return shared.additive(name).fluid and "fluid" or "item" end

-- Dosing in production (scripts/dosing.lua): a machine's composition, supplied by the hoppers it
-- touches. Up to `rows` additives per machine; a dose is units per batch of products, as in a trial.
shared.hopper = {slots = 8, rows = 3}
-- Trash slots given to every crafting machine (0.65): residues leave by them, with the products, as
-- spoilage does. Two stacks hold a slow output inserter's backlog; a full one pauses the dose.
-- One stack per kind of residue a dose can leave: each row's additive leaves at most two (a blend's
-- members), review 0.68 (two slots blocked a three-family mixture forever).
shared.trash_slots = 2 * shared.hopper.rows
-- Dossiers: the production a proven effect must reach, in trial batches of
-- its target (so dear targets, with small batches, need fewer products). Thresholds: docs/balance.py.
shared.dossier = {volume_batches = 100,
  -- The report's "worth another look": a dropped cell whose true effect clears its bar by at least this share
  -- of the bar (0.69; so it never sends a player to grind an effect that only just clears).
  look_margin = 0.5}

-- Target recipes that can be experimented on: vanilla recipes with item ingredients only (fluids come
-- with the oil-era bench). Ingredients, trial time and the unlocking technology are derived from the
-- vanilla recipe in the data stage. A trial is destructive: of `batch` nominal products only
-- floor(survivor_share * batch) come out, plus one sample and one spent additive per unit dosed.
-- `process` weights hidden process classes (the lawful world).
-- Early payoff (decided 2026-09-30, by model): a batch holds at least about 60 ore of ingredients
-- (batches only raised, never lowered; docs/balance.py fails the build when one falls short), so a dose
-- per batch is spread over enough product to pay; trials return most of their batch. Before: batches of 3 to 5, survivors 30%, reclaim 4:1, and red-science targets lost
-- ore on most maps.
shared.batch_ore = 60
-- Spoilage (decided 2026-09-30): a trial whose spoilable inputs are this far spoiled fails (the batch
-- is consumed, the sample records a failed run; the station spends no pack on it).
shared.spoil_fail = 0.5
-- Research data: a sample pays floor + (1 - floor) x openness of its
-- question; a question is settled when the CI of its net gain excludes zero or is within +/- band.
-- Full cost prices (decided 2026-10-02 from the review's derivations), in ore per
-- unit: early, an assembling machine 2 over a 2 h horizon, steam on coal, pollution priced by defence;
-- late, an assembling machine 3 with four productivity 3 modules and two beacons' share over 10 h
-- (speed x3.4), solar, pollution unpriced. Power draw is the machine's own (modules ignored: under 1%).
-- A flat table's copy (control-stage code cannot use table.deepcopy: it exists only in the data stage).
function shared.copy(t)
  local o = {}
  for k, v in pairs(t) do o[k] = v end
  return o
end
shared.prices = {
  early = {machine = "assembling-machine-2", speed_factor = 1, machine_second = 0.0075, mj = 0.25, pollution = 0.3},
  late = {machine = "assembling-machine-3", speed_factor = 3.4, machine_second = 0.70, mj = 0.04, pollution = 0},
}
shared.data = {settled = 0.05,  -- openness under which a question is settled (Data column, "To settle")
  band = 0.05, quality_band = 0.02, floor = 0.1, control_free = 8, fluid_ore = 0.1,
  -- (0.72, the variety rules) A target's floor grows with the ore its trial loses, up to this many floors (open
  -- questions keep their value); the map's richness spread comes from docs/balance.py (scripts/richness_*.lua).
  floor_cap_x = 2.5,
  -- The richness spread aimed at (option B, after worked examples): the best long-run grind about
  -- a quarter cheaper than the median target's, worth finding without being a must. docs/balance.py writes the
  -- passing spread nearest it.
  richness_aim = 0.3,
  -- The branch: a level costs about one careful study at its tier, in data,
  -- with the tier's packs alongside; docs/balance.py fails when a price drifts from its model value.
  branch_units = {red = 102, green = 102, blue = 113, purple = 135},
  -- (0.72) Analysis precision 1 is the first thing empirical science packs buy since Process routes were retired:
  -- this share of a red level, so it arrives during the player's first study.
  first_stage_share = 0.5,  -- (0.70, wood left the early set: green 130 -> 102, blue 135 -> 113; 0.72, the grinding fix: red 125 -> 102)
  precision_step = 0.85,   -- trial noise x this per level of precision instruments
  -- Space Age recipe productivity for recipes the mod has as targets: data per research unit (whole
  -- numbers only), set so the floor route costs about 1.5x the level's packs in ore; balance.py stops
  -- when a value strays beyond 2x of that rule.
  productivity_units = {["steel-plate"] = 1, ["low-density-structure"] = 1, ["processing-unit"] = 1, ["plastic-bar"] = 1},
  -- Vanilla's endless technologies (0.72, replacing Mastery): data per unit, by the same rule on gears' floor
  -- route; balance.py stops when one strays beyond 2x.
  infinite_units = {
    -- (Without Space Age, which replaces these two: not in the model's dump, which loads it; at the minimum.)
    ["mining-productivity-4"] = 1, ["worker-robots-speed-6"] = 1,
    ["artillery-shell-damage-1"] = 1, ["artillery-shell-range-1"] = 1, ["artillery-shell-speed-1"] = 1,
    ["asteroid-productivity"] = 1, ["electric-weapons-damage-4"] = 1, ["follower-robot-count-5"] = 1,
    ["health"] = 1, ["laser-weapons-damage-7"] = 1, ["mining-productivity-3"] = 1,
    ["physical-projectile-damage-7"] = 1, ["railgun-damage-1"] = 1, ["railgun-shooting-speed-1"] = 1,
    ["refined-flammables-7"] = 1, ["research-productivity"] = 1, ["rocket-fuel-productivity"] = 1,
    ["rocket-part-productivity"] = 1, ["scrap-recycling-productivity"] = 1, ["stronger-explosives-7"] = 1,
    ["worker-robots-speed-7"] = 1},
  mainline_tiers = {"off", "chemical-science-pack", "production-science-pack", "utility-science-pack"},
}
-- Staged reveal: the mod's tools open in stages, each a
-- technology paid in research data (`units`) and its packs. Precision instruments 1 also measures speed
-- and pollution; Circuit instrumentation 1 also opens circuit mode.
shared.stages = {
  mixtures = {tech = "es-mixtures", units = 102, packs = 2, prerequisites = {"logistic-science-pack"}},
  thermal = {tech = "es-thermal-studies", units = 113, packs = 3, prerequisites = {"oil-processing", "chemical-science-pack"}},
  -- The Theory tab (0.53): one careful study at green, after Mixtures (a model needs several targets).
  theory = {tech = "es-theory", units = 102, packs = 2, prerequisites = {"es-mixtures"}},
}
-- Quality additives (with the quality mod): the agents, after vanilla's quality modules.
if shared.quality_on then
  shared.stages.quality = {tech = "es-quality-additives", units = 102, packs = 2, prerequisites = {"quality-module"}}
end
shared.side_effects_tech = "es-precision-instruments-1"
shared.circuit_tech = "es-circuit-instrumentation-1"
-- A technology as shown in text: its icon, then its name (an icon alone does not say which).
function shared.tech_caption(tech)
  return {"", "[technology=" .. tech .. "] ", {"technology-name." .. tech}}
end

-- (Control stage.) Whether a force may use a staged tool: researched, or a force from before staging
-- (storage.legacy_stages: nothing it used disappears).
function shared.stage_ok(force, tech)
  if storage.legacy_stages and storage.legacy_stages[force.index] then return true end
  local t = force.technologies[tech]
  return t ~= nil and t.researched
end

-- A bench is not a factory: trial time factor >= survivor share keeps it no faster
-- than assembling machine 1 (docs/balance.py stops otherwise); half the batch lost makes it a wasteful
-- one, and a study a real investment of ore.
shared.survivor_share = 0.5
shared.trial_time_factor = 0.5  -- trial time = vanilla crafting time of the batch x this
shared.targets = {
  {key = "gear", result = "iron-gear-wheel", batch = 30, process = {metalwork = 1}},
  {key = "circuit", result = "electronic-circuit", batch = 24, process = {electronics = 1}},
  {key = "steel", result = "steel-plate", batch = 12, process = {metalwork = 1}},
  {key = "red", result = "automation-science-pack", batch = 20, process = {metalwork = 0.7, electronics = 0.3}},
  {key = "green", result = "logistic-science-pack", batch = 9, process = {metalwork = 0.6, electronics = 0.4}},
  {key = "engine", result = "engine-unit", batch = 7, process = {metalwork = 0.7, chemistry = 0.3}},
  {key = "advanced-circuit", result = "advanced-circuit", batch = 6, process = {electronics = 0.6, chemistry = 0.4}},
  {key = "blue", result = "chemical-science-pack", batch = 4,
   process = {chemistry = 0.5, electronics = 0.3, metalwork = 0.2}},
  {key = "lds", result = "low-density-structure", batch = 2, process = {metalwork = 0.5, chemistry = 0.5}},
  {key = "purple", result = "production-science-pack", batch = 3, process = {metalwork = 0.7, electronics = 0.3}},
  {key = "yellow", result = "utility-science-pack", batch = 3,
   process = {electronics = 0.6, metalwork = 0.2, chemistry = 0.2}},
  -- Fluid-fed targets (the bench's fluid input, 0.25): their productivity research joins the data loop.
  {key = "processing-unit", result = "processing-unit", batch = 1, process = {electronics = 0.7, chemistry = 0.3}},
  {key = "plastic", result = "plastic-bar", batch = 40, process = {chemistry = 1}},
  {key = "battery", result = "battery", batch = 15, process = {chemistry = 0.6, metalwork = 0.4}},
  {key = "electric-engine", result = "electric-engine-unit", batch = 4, process = {metalwork = 0.5, electronics = 0.5}},
  {key = "robot-frame", result = "flying-robot-frame", batch = 2, process = {metalwork = 0.5, electronics = 0.5}},
  -- One per planet (Space Age only). Their samples cost the planet's own pack (`pack`): their unlocking
  -- technologies are triggers with no pack to derive a tier from.
  {key = "tungsten-carbide", result = "tungsten-carbide", batch = 9, process = {metalwork = 0.6, chemistry = 0.4},
   requires = "space-age", pack = "metallurgic-science-pack"},
  {key = "superconductor", result = "superconductor", batch = 24, process = {electronics = 0.6, chemistry = 0.4},
   requires = "space-age", pack = "electromagnetic-science-pack"},
  {key = "carbon-fiber", result = "carbon-fiber", batch = 9, process = {chemistry = 1}, requires = "space-age"},
  {key = "lithium-plate", result = "lithium-plate", batch = 25, process = {metalwork = 0.7, chemistry = 0.3},
   requires = "space-age", pack = "cryogenic-science-pack"},
  -- Smelting (0.50, decided 2026-10-02 with an outside review): quality agents can start the ladder from
  -- raw materials. Reduction leans chemistry, brick firing more so; the three classes, since a fourth
  -- would shift every family's draws. `extended` (the batch they were added in: 1 smelting, 2 Gleba):
  -- drawn by truth.extend_targets on its own stream, last, so no existing target's hidden world moves.
  {key = "iron-plate", result = "iron-plate", batch = 60, process = {metalwork = 0.7, chemistry = 0.3}, extended = 1,
   simplest = true},
  {key = "copper-plate", result = "copper-plate", batch = 60, process = {metalwork = 0.7, chemistry = 0.3}, extended = 1,
   simplest = true},
  {key = "stone-brick", result = "stone-brick", batch = 30, process = {chemistry = 0.7, metalwork = 0.3}, extended = 1,
   simplest = true},
  -- Gleba (0.52, decided 2026-10-03): spoilable products, so the freshness effect has something to act
  -- on. Their technologies are triggers: samples cost Gleba's pack. Batches:
  -- whole crafts holding at least shared.batch_ore of ingredients.
  {key = "bioflux", result = "bioflux", batch = 12, process = {chemistry = 1}, requires = "space-age",
   pack = "agricultural-science-pack", extended = 2},
  {key = "nutrients", result = "nutrients", recipe = "nutrients-from-bioflux", batch = 80,
   process = {chemistry = 0.8, electronics = 0.2}, requires = "space-age", pack = "agricultural-science-pack",
   extended = 2},
  {key = "pentapod-egg", result = "pentapod-egg", batch = 4, process = {chemistry = 0.6, electronics = 0.4},
   requires = "space-age", pack = "agricultural-science-pack", extended = 2},
  {key = "agricultural", result = "agricultural-science-pack", batch = 3,
   process = {chemistry = 0.5, electronics = 0.3, metalwork = 0.2}, requires = "space-age",
   pack = "agricultural-science-pack", extended = 2},
  -- Space platforms (0.63): the two space-only item
  -- recipes (gravity 0, which their trials inherit). `own_stream`: drawn as other mods' targets are, from
  -- streams keyed by the map and the target (truth.extend_registered), so they move no other draw.
  {key = "space-science", result = "space-science-pack", batch = 75, process = {metalwork = 0.4, chemistry = 0.6},
   requires = "space-age", pack = "space-science-pack", own_stream = true},
  {key = "promethium-science", result = "promethium-science-pack", batch = 20,
   process = {chemistry = 0.6, electronics = 0.4}, requires = "space-age", own_stream = true},
  -- Second and third targets for the one-target planets (0.64): a planet's
  -- dossier quota needs more than one draw to lean on. One fluid in and none out (the bench's fluid box);
  -- batches by the same rule; drawn on their own streams like the platform targets.
  {key = "tungsten-plate", result = "tungsten-plate", batch = 12, process = {metalwork = 0.8, chemistry = 0.2},
   requires = "space-age", pack = "metallurgic-science-pack", own_stream = true},
  {key = "metallurgic", result = "metallurgic-science-pack", batch = 2, process = {metalwork = 0.6, chemistry = 0.4},
   requires = "space-age", pack = "metallurgic-science-pack", own_stream = true},
  {key = "supercapacitor", result = "supercapacitor", batch = 3, process = {electronics = 0.7, chemistry = 0.3},
   requires = "space-age", pack = "electromagnetic-science-pack", own_stream = true},
  {key = "tesla-ammo", result = "tesla-ammo", batch = 3, process = {electronics = 0.5, chemistry = 0.5},
   requires = "space-age", pack = "electromagnetic-science-pack", own_stream = true},
  {key = "fusion-power-cell", result = "fusion-power-cell", batch = 3, process = {chemistry = 0.7, metalwork = 0.3},
   requires = "space-age", pack = "cryogenic-science-pack", own_stream = true},
  {key = "foundation", result = "foundation", batch = 1, process = {metalwork = 0.5, chemistry = 0.5},
   requires = "space-age", pack = "cryogenic-science-pack", own_stream = true},
}
-- A target's vanilla recipe: named after its product unless `recipe` says otherwise (nutrients has five
-- recipes, none named after it).
function shared.target_recipe(t) return t.recipe or t.result end
-- Targets from a mod that is not loaded are dropped (the data stage sees `mods`, the control stage
-- `script.active_mods`; the same list either way).
do
  local active = (mods) or (script and script.active_mods) or {}
  for i = #shared.targets, 1, -1 do
    local req = shared.targets[i].requires
    if req and not active[req] then table.remove(shared.targets, i) end
  end
end
shared.process_classes = {"metalwork", "chemistry", "electronics"}
-- World strength (0.57): fixed when a map is created. Harsh: dearer trials
-- (noise) and a spikier world (fewer activators, larger peaks, sharper humps); gentle (withdrawn) mirrored it. The
-- draws do not change; standard is the world as it was (truth.activator_slope and activator_cap).
shared.world_strength = {
  -- Harsh's peak starts where standard's would be at its threshold, so no activator it keeps is smaller.
  -- Gentle: standard's activators unchanged (the same line above standard's threshold) plus small ones
  -- standard calls inert (0.59: a lower cap and slope let the cheapest additive win everywhere, P4 87%).
  -- `window`: at harsh an activator's curve sits in a bell of this half-width (doses) around its optimum.
  -- `samples_per_pack`: what one pack analyses (more packs per sample at harsh).
  -- `trial_cost`: a trial uses this many times its batch's crafts of ingredients (whole crafts, rounded up),
  -- with the same survivors back and the same measured batch: harsh is dearer, like expensive recipes.
  -- Trial recipes are prototypes, so this follows the startup setting (the world's shape stays the map's).
  -- Gentle's noise is 0.9: at 0.8 the Theory tab's intervals covered just under its 85% floor.
  -- (Gentle's packs as standard's: 5 samples a pack made every stage cost over 1.1 of its careful studies, P2.)
  gentle = {noise = 0.9, threshold = 0.4, base = 0.04, slope = 0.15, cap = 0.28, sharp = 0.75,
            samples_per_pack = shared.samples_per_pack,
            trial_cost = 1},
  standard = {noise = 1, threshold = 0.8, base = 0.1, slope = 0.15, cap = 0.28, sharp = 1,
               samples_per_pack = shared.samples_per_pack, trial_cost = 1},
  harsh = {noise = 1.25, threshold = 0.85, base = 0.1075, slope = 0.2, cap = 0.36, sharp = 1.5, window = 2,
           samples_per_pack = 2, trial_cost = 1.5},
}
-- The setting's choices. Gentle is out until it is redesigned after the playtest (as a
-- mirror of harsh it broke a different rule at each adjustment); its row stays so a map made with it loads.
shared.world_strength_order = {"standard", "harsh"}

-- Fulgora scrap samples (0.60): a result of scrap recycling, drawn when
-- a station analyses it. `rate`: its probability per scrap recycled; a cell takes `cap` scrap samples (a
-- target's control `control_cap`), then draws on it are duds; `control_share` of draws are controls; dose
-- weights skew low and middle; a pack of tier k raises every weight to 1 - flatten x k (rarer cells more
-- often). Scrap forensics 1 and 2 widen the targets.
shared.scrap = {
  item = "es-scrap-sample", rate = 0.002, cap = 3, control_cap = 6, control_share = 0.15, spoil_minutes = 5,
  slots = 4, flatten = 0.15,
  dose_weight = {2, 2, 2, 2, 2, 2, 0.5, 0.5, 0.5},
  pack_tier = {["automation-science-pack"] = 0, ["logistic-science-pack"] = 1, ["military-science-pack"] = 1,
    ["chemical-science-pack"] = 2, ["production-science-pack"] = 3, ["utility-science-pack"] = 3,
    ["space-science-pack"] = 3, ["metallurgic-science-pack"] = 4, ["electromagnetic-science-pack"] = 4,
    ["agricultural-science-pack"] = 4, ["cryogenic-science-pack"] = 5, ["promethium-science-pack"] = 6},
  forensics = {"es-scrap-forensics-1", "es-scrap-forensics-2"},
}
-- A trial's crafts of ingredients at a strength, from its batch's crafts.
function shared.trial_crafts(crafts, strength)
  return math.ceil(crafts * shared.world_strength[strength or "standard"].trial_cost - 1e-9)
end

-- Alternate routes: hand-authored recipes with genuinely different inputs. {key, ingredients,
-- amount (products per craft), time (seconds), lever}. Whether a route works on a map, and how well,
-- is hidden; `lever` names an additive whose hidden traits govern it (lawful: a route through stone
-- brick behaves like stone brick does as an additive on that target). No lever: its own draw.
shared.routes_all = {
  gear = {
    {key = "cast", ingredients = {{"stone-brick", 1}, {"iron-plate", 2}}, amount = 2, time = 1, lever = "stone-brick"},
    {key = "forged", ingredients = {{"steel-plate", 2}}, amount = 5, time = 2},
  },
  circuit = {
    {key = "ceramic", ingredients = {{"stone-brick", 1}, {"copper-cable", 1}}, amount = 1, time = 1, lever = "stone-brick"},
    {key = "wooden", ingredients = {{"wood", 1}, {"copper-cable", 3}}, amount = 1, time = 1, lever = "wood"},
  },
  steel = {
    {key = "carburised", ingredients = {{"iron-plate", 4}, {"coal", 1}}, amount = 1, time = 16, lever = "coal"},
    {key = "direct", ingredients = {{"iron-ore", 4}, {"coal", 1}}, amount = 1, time = 20},
  },
  red = {
    {key = "wired", ingredients = {{"copper-cable", 2}, {"iron-gear-wheel", 1}}, amount = 1, time = 5, lever = "copper-cable"},
    {key = "plated", ingredients = {{"copper-plate", 1}, {"iron-plate", 2}}, amount = 1, time = 6},
  },
  green = {
    {key = "piped", ingredients = {{"inserter", 1}, {"pipe", 2}}, amount = 1, time = 6},
    {key = "geared", ingredients = {{"electronic-circuit", 1}, {"iron-gear-wheel", 1}, {"transport-belt", 2}},
     amount = 1, time = 7},
  },
  engine = {
    {key = "cast-iron", ingredients = {{"iron-plate", 5}, {"iron-gear-wheel", 1}, {"pipe", 2}}, amount = 1, time = 12},
    {key = "brick-lined", ingredients = {{"steel-plate", 1}, {"stone-brick", 2}}, amount = 1, time = 10,
     lever = "stone-brick"},
  },
  ["advanced-circuit"] = {
    {key = "sulfur-doped", ingredients = {{"electronic-circuit", 2}, {"sulfur", 1}, {"copper-cable", 4}}, amount = 1,
     time = 6, lever = "sulfur"},
    {key = "lean", ingredients = {{"electronic-circuit", 2}, {"plastic-bar", 1}, {"copper-cable", 6}}, amount = 1,
     time = 8, lever = "plastic-bar"},
  },
  blue = {
    {key = "geared", ingredients = {{"engine-unit", 1}, {"advanced-circuit", 3}, {"sulfur", 1}, {"iron-gear-wheel", 5}},
     amount = 2, time = 24},
    {key = "plastic", ingredients = {{"engine-unit", 2}, {"advanced-circuit", 2}, {"plastic-bar", 6}, {"sulfur", 1}},
     amount = 2, time = 24, lever = "plastic-bar"},
  },
  lds = {
    {key = "lean", ingredients = {{"steel-plate", 3}, {"copper-plate", 15}, {"plastic-bar", 5}}, amount = 1, time = 15},
    {key = "brick", ingredients = {{"steel-plate", 2}, {"stone-brick", 10}, {"plastic-bar", 5}}, amount = 1, time = 15,
     lever = "stone-brick"},
  },
  purple = {
    {key = "steel-furnace", ingredients = {{"steel-furnace", 2}, {"productivity-module", 1}, {"rail", 34}},
     amount = 3, time = 21},
    {key = "speed", ingredients = {{"electric-furnace", 1}, {"speed-module", 1}, {"rail", 30}}, amount = 3, time = 21},
  },
  yellow = {
    {key = "advanced", ingredients = {{"advanced-circuit", 14}, {"flying-robot-frame", 1}, {"low-density-structure", 3}},
     amount = 3, time = 21},
    {key = "electric", ingredients = {{"processing-unit", 2}, {"electric-engine-unit", 2}, {"low-density-structure", 3}},
     amount = 3, time = 21},
  },
}
-- Science packs have no alternative recipes ("wired automation packs" beside a copper
-- cable additive trips players up, and changing how science itself is made reaches further than the
-- mod can see). Their routes stay in routes_all, which the hidden world draws from, so no map changes.
-- (0.72, after the advisory pass: an even-money bet of a few per cent, outside the additive frame; the user had
-- doubted them since 2026-10-01) Every route is retired: none is testable or adoptable. They stay in routes_all,
-- which the hidden world draws from, so no map changes.
shared.routes = {}

-- Process profile of each route (additives on routes, 7b): how the route's chemistry differs from the
-- vanilla recipe's, so additive effects on it follow the same hidden traits but land differently.
shared.route_process = {
  ["gear@cast"] = {metalwork = 0.5, chemistry = 0.5},
  ["gear@forged"] = {metalwork = 1},
  ["circuit@ceramic"] = {electronics = 0.6, chemistry = 0.4},
  ["circuit@wooden"] = {electronics = 0.7, chemistry = 0.3},
  ["steel@carburised"] = {metalwork = 0.6, chemistry = 0.4},
  ["steel@direct"] = {metalwork = 0.5, chemistry = 0.5},
  ["red@wired"] = {electronics = 0.6, metalwork = 0.4},
  ["red@plated"] = {metalwork = 1},
  ["green@piped"] = {metalwork = 0.8, electronics = 0.2},
  ["green@geared"] = {metalwork = 0.5, electronics = 0.5},
  ["engine@cast-iron"] = {metalwork = 1},
  ["engine@brick-lined"] = {metalwork = 0.5, chemistry = 0.5},
  ["advanced-circuit@sulfur-doped"] = {electronics = 0.4, chemistry = 0.6},
  ["advanced-circuit@lean"] = {electronics = 0.8, chemistry = 0.2},
  ["blue@geared"] = {metalwork = 0.5, chemistry = 0.3, electronics = 0.2},
  ["blue@plastic"] = {chemistry = 0.7, electronics = 0.3},
  ["lds@lean"] = {metalwork = 0.7, chemistry = 0.3},
  ["lds@brick"] = {metalwork = 0.3, chemistry = 0.7},
  ["purple@steel-furnace"] = {metalwork = 0.8, electronics = 0.2},
  ["purple@speed"] = {metalwork = 0.5, electronics = 0.5},
  ["yellow@advanced"] = {electronics = 0.7, metalwork = 0.3},
  ["yellow@electric"] = {electronics = 0.5, metalwork = 0.3, chemistry = 0.2},
}

-- Routes as sub-targets ("gear@cast"): testable and dosable like any target.
function shared.subtarget_key(target_key, route_key) return target_key .. "@" .. route_key end
-- subtargets_all includes retired routes: the hidden world draws for them too, so a seed gives the same
-- world it did before they were retired.
shared.subtargets, shared.subtargets_all = {}, {}
for _, target in ipairs(shared.targets) do
  for _, route in ipairs(shared.routes_all[target.key] or {}) do
    local key = shared.subtarget_key(target.key, route.key)
    local sub = {key = key, result = target.result, batch = target.batch,
      process = shared.route_process[key], parent = target, route = route}
    table.insert(shared.subtargets_all, sub)
    if shared.routes[target.key] then table.insert(shared.subtargets, sub) end
  end
end
-- Every testable target in display order: each vanilla target followed by its routes. The _all list
-- keeps retired routes, for the hidden world's draws.
local function with_subtargets(subs)
  local out = {}
  for _, target in ipairs(shared.targets) do
    table.insert(out, target)
    for _, sub in ipairs(subs) do
      if sub.parent == target then table.insert(out, sub) end
    end
  end
  return out
end
shared.all_targets, shared.all_targets_all = with_subtargets(shared.subtargets), with_subtargets(shared.subtargets_all)
-- An item's name (control stage): its own localised name, for other mods' items that set one.
function shared.item_name(name)
  local proto = prototypes and prototypes.item[name]
  return proto and proto.localised_name or {"item-name." .. name}
end
-- A target's name with its icon; an alternative recipe adds its name ("Iron gear wheel (Cast gears)").
function shared.target_caption(t)
  local base = {"", "[item=" .. t.result .. "] ", shared.item_name(t.result)}
  if not t.route then return base end
  return {"", base, " (", {"es-route." .. t.parent.key .. "-" .. t.route.key}, ")"}
end
-- The trial recipe a target's control runs (a route's own trial for a route sub-target).
function shared.control_trial(key)
  local t = shared.target(key)
  if t.route then return shared.route_trial(t.parent.key, t.route.key) end
  return shared.trial_recipe(key)
end

function shared.route_recipe(target, key) return "es-route-" .. target .. "-" .. key end
function shared.route_trial(target, key) return "es-trial-" .. target .. "-route-" .. key end
-- Crafts of a route per trial: about one target batch of products.
function shared.route_crafts(target, route)
  return math.max(1, math.floor(target.batch / route.amount + 0.5))
end

-- The evidence key of a surface (control stage only): its planet, "space-platform" for every platform
-- (their physics is the same), else its name.
function shared.surface_key(surface)
  if surface.planet then return surface.planet.name end
  if surface.platform then return "space-platform" end
  return surface.name
end

function shared.target(key)
  for _, t in ipairs(shared.targets) do if t.key == key then return t end end
  for _, t in ipairs(shared.subtargets) do if t.key == key then return t end end
end

-- A target's trial recipe: one per target; its dose comes from the bench's hoppers.
function shared.trial_recipe(target) return "es-trial-" .. target .. "-control" end

-- The family an additive mixes as (decided 2026-10-02): a residue or an activated catalyst as its
-- family's (activated carbon is carbon: redundant with coal, carbon's synergies with others); anything
-- else as its own. Screens still label them "residue" and "activated catalyst".
function shared.mix_family(name)
  local a = shared.additive(name)
  if not a then return nil end
  if a.residue_of then return a.residue_of end
  if a.refined_from then return shared.additive(a.refined_from).residue_of end
  return a.family
end

-- The residue a dosed unit of an additive leaves: its family's, for solid additives of a family with a
-- residue; fluids, premixes, catalysts, residues and quality agents leave none.
local residue_by_family = {}
for _, a in ipairs(shared.additives) do if a.residue_of then residue_by_family[a.residue_of] = a.name end end
function shared.residue_of(additive)
  local a = shared.additive(additive)
  if not a or a.fluid or a.agent or a.premix_of or a.spent_of or a.refined_from then return nil end
  return residue_by_family[a.family]
end
-- What one unit of an additive leaves when dosed (0.68):
-- one residue per solid member. A raw solid its family's; an activated catalyst its own family's (the
-- residue it was made from); a solid blend each member's; a biological additive spoilage (not a residue:
-- it is never activated). A slurry its solid member's, at the share of it a unit carries (0.70, user: the
-- late loop, residue back to activation, closes; shared.residue_shares). Fluids, emulsions, quality agents,
-- residues and spoilage leave nothing.
local function slurry_solid(a)
  return shared.additive(a.premix_of[1]).fluid and a.premix_of[2] or a.premix_of[1]
end
function shared.residues_of(additive)
  local a = shared.additive(additive)
  if a and a.phase == "slurry" then return shared.residues_of(slurry_solid(a)) end
  if not a or a.fluid or a.agent or a.spent_of or additive == "spoilage" then return {} end
  if a.living then return {"spoilage"} end
  if a.refined_from then return {a.refined_from} end
  if a.premix_of then
    local out = {}
    for _, m in ipairs(a.premix_of) do
      for _, r in ipairs(shared.residues_of(m)) do table.insert(out, r) end
    end
    return out
  end
  local r = residue_by_family[a.family]
  return r and {r} or {}
end
-- Residue left per unit dosed, by residue: 1 per solid member, and for a slurry the solid its recipe puts
-- into one unit of it (about 2 in 15). Control stage (it reads the recipe).
local slurry_share, shares_cache = {}, {}
-- (Cached per additive: read on every dose, and fixed once the prototypes are; callers must not change it.)
function shared.residue_shares(additive)
  if shares_cache[additive] then return shares_cache[additive] end
  local a = shared.additive(additive)
  local share = 1
  if a and a.phase == "slurry" then
    if not slurry_share[additive] then
      local solid, rec = slurry_solid(a), prototypes.recipe[additive]
      local s_amt, out = 0, 0
      for _, i in ipairs(rec and rec.ingredients or {}) do if i.name == solid then s_amt = i.amount end end
      for _, p in ipairs(rec and rec.products or {}) do if p.name == additive then out = p.amount or 0 end end
      slurry_share[additive] = out > 0 and s_amt / out or 0
    end
    share = slurry_share[additive]
  end
  local out = {}
  for _, r in ipairs(shared.residues_of(additive)) do out[r] = (out[r] or 0) + share end
  shares_cache[additive] = out
  return out
end

-- Other mods' targets (0.55): entries of the `es-targets` mod-data,
-- checked, appended in key order and marked `registered` (no routes). The data stage calls
-- this from data-final-fixes, after every mod's data; the control stage reads the same table at load,
-- keeping only the entries data-final-fixes built prototypes for.
shared.REGISTRY = "es-targets"
local function check_registered(key, e)
  if type(key) ~= "string" or not key:match("^%a[%w%-]*$") then return "the key must be a name (letters, digits, -)" end
  if shared.target(key) then return "a target with this key exists" end
  if type(e) ~= "table" then return "the entry must be a table" end
  if type(e.result) ~= "string" then return "result must name an item" end
  if type(e.batch) ~= "number" or e.batch < 1 or e.batch ~= math.floor(e.batch) then return "batch must be a whole number" end
  if type(e.process) ~= "table" then return "process must give weights per class" end
  local known, sum = {}, 0
  for _, c in ipairs(shared.process_classes) do known[c] = true end
  for c, w in pairs(e.process) do
    if not known[c] then return "unknown process class " .. tostring(c) end
    if type(w) ~= "number" or w < 0 then return "process weights must be numbers, not negative" end
    sum = sum + w
  end
  if sum <= 0 then return "process weights are all zero" end
  for _, t in ipairs(shared.targets) do
    if t.result == e.result and shared.target_recipe(t) == (e.recipe or e.result) then return "this recipe is already a target" end
  end
end
function shared.register_targets(entries, built_only)
  local keys, added = {}, {}
  for key in pairs(entries) do table.insert(keys, key) end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local e = entries[key]
    if not built_only or e.built then
      local err = check_registered(key, e)
      if err then error("empirical-science: registered target " .. tostring(key) .. ": " .. err) end
      local t = {key = key, result = e.result, recipe = e.recipe, batch = e.batch, process = e.process,
        pack = e.pack, registered = true, derived = e.derived or nil}
      table.insert(shared.targets, t)
      table.insert(added, t)
    end
  end
  shared.refresh_target_lists()
  return added
end
-- The lists built from shared.targets (after registering, and for tests that swap the targets).
function shared.refresh_target_lists()
  shared.all_targets, shared.all_targets_all = with_subtargets(shared.subtargets), with_subtargets(shared.subtargets_all)
end
if prototypes and prototypes.mod_data then
  local registry = prototypes.mod_data[shared.REGISTRY]
  if registry then shared.register_targets(registry.data, true) end
end

-- Samples (0.72): one item per science pack ("es-sample-<pack>"); "es-sample" is the item before 0.72, still
-- read where saves hold one.
function shared.sample_of(pack) return "es-sample-" .. pack end
function shared.pack_of_sample(name) return name:match("^es%-sample%-(.+)$") end
function shared.is_sample(name) return name == "es-sample" or shared.pack_of_sample(name) ~= nil end

return shared
