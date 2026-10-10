local shared = require("shared")
local stats = require("scripts.stats")
local truth = require("scripts.truth")
local regress = require("scripts.regress")
local chart = require("scripts.chart")
local gui = require("scripts.gui")
local dosing = require("scripts.dosing")
local dose_gui = require("scripts.dose_gui")
local hopper_report = require("scripts.hopper_report")
local theory = require("scripts.theory")
local research = require("scripts.research")
local answer_key = require("scripts.answer_key")
local dossiers = require("scripts.dossiers")
local blueprints = require("scripts.blueprints")

local BENCH, STATION, PORT = "es-test-bench", "es-analysis-station", "es-station-port"
local GUI_REFRESH_TICKS = 60
local DOSSIER_TICKS = 600  -- dossiers are re-judged this often (only for forces whose evidence or output moved)
local CLEAR_CONFIRM_TICKS = 5 * 60  -- a clear needs its second click within this
local CRAFTER_TICKS = 60
local DISCOVERY_MIN_N = shared.premix.discovery_n  -- (catalysts' discovery uses the same floor)

-- Trial recipes: recipe name -> {target}. Production recipes whose products a dose can change: a target's
-- vanilla recipe -> {target}. `producing` maps them to what a machine running them makes, for the dose panel.
local trials, industrial, producing = {}, {}, {}
for _, target in ipairs(shared.targets) do
  trials[shared.trial_recipe(target.key)] = {target = target}
  producing[shared.trial_recipe(target.key)] = target
  industrial[shared.target_recipe(target)] = {target = target}
  producing[shared.target_recipe(target)] = target
end

---------------------------------------------------------------------------
-- Storage
---------------------------------------------------------------------------

-- Station data per target: accumulators keyed "control", "additive:dose", or a mixture
-- "a:dose+b:dose" (names sorted). Created on first use: fluid doses can be any value.
local function new_obs()
  local obs = {}
  for _, target in ipairs(shared.targets) do obs[target.key] = {control = {n = 0, sum = 0, sumsq = 0}} end
  return obs
end

-- Batches of the only targets that existed when samples recorded a product count (before 0.5).
local COUNT_FORMAT_BATCH = {gear = 10, circuit = 5, engine = 5}

-- The force's pool (decided 2026-09-30): every station of a force analyses into one set of
-- observations, read on the Empirical Science screen. Stations are the mod's labs; they keep only their
-- own counts (analysed, unreadable) for their window.
local function new_pool() return {obs = new_obs(), side = {}, analysed = 0, unreadable = 0} end
-- Per force and per surface (planet conditions, 0.26): evidence from one planet never mixes with
-- another's. Without a surface key: Nauvis.
local function pool_of(force, skey)
  local by = storage.pools[force.index]
  if not by then by = {}; storage.pools[force.index] = by end
  skey = skey or "nauvis"
  by[skey] = by[skey] or new_pool()
  return by[skey]
end
local function mark_pool(force)
  storage.dirty_pools[force.index] = true
end

-- Planet conditions: where a trial or a craft happens. The key names the evidence (a planet, "space-
-- platform" for every platform: their physics is the same); the condition feeds the hidden world.
local surface_key = shared.surface_key
local schedule_bench  -- defined with the benches below; on_built uses it
local PLANET_CONDS = {}  -- the sampler's planets (set in sample_worlds)
local cond_cache = {}  -- derived from prototypes only: the same on every peer, rebuilt after a load
local function surface_cond(surface)
  local k = surface_key(surface)
  if cond_cache[k] == nil then
    local values = {}
    for _, p in ipairs(truth.condition_props) do values[p] = surface.get_property(p) end
    cond_cache[k] = truth.condition_of(values) or false
  end
  return cond_cache[k] or nil
end

-- Levels of a branch technology a force has researched (name-1, name-2, ...).
local function level_of(force, name)
  local level = 0
  while force.technologies[name .. "-" .. (level + 1)] and force.technologies[name .. "-" .. (level + 1)].researched do
    level = level + 1
  end
  return level
end
-- Precision instruments: trial noise x step per level. Station throughput: one more sample per pack.
-- World strength: the map's own, fixed at creation; spikiness in truth.lua.
local function strength_of_map() return storage.truth and storage.truth.strength or "standard" end
-- The seed the hidden world draws from: its science seed, or (worlds made before 0.70) the map's.
local function world_seed()
  return storage.truth and storage.truth.science_seed or game.surfaces[1].map_gen_settings.seed
end
local function noise_factor(force)
  return shared.world_strength[strength_of_map()].noise
    * shared.data.precision_step ^ level_of(force, "es-precision-instruments")
end
local function samples_per_pack(force)
  return shared.world_strength[strength_of_map()].samples_per_pack
    + shared.station_throughput_step * level_of(force, "es-station-throughput")
end

local function sample_key(tags)
  if tags.mix and next(tags.mix) then
    local parts = {}
    for name, dose in pairs(tags.mix) do
      -- A fluid's evidence is kept per temperature band (name@band), except its usual band (unsuffixed:
      -- what every sample had before temperatures mattered).
      local t = tags.temps and tags.temps[name]
      local proto = t and prototypes.fluid[name]
      local a = shared.additive(name)
      if t and a and a.living then
        -- A living additive's evidence is kept per ripeness band (0.62), its freshest unsuffixed.
        if shared.ripe_band(t) ~= 0 then name = name .. "~" .. shared.ripe_band(t) end
      elseif proto and shared.temp_band(t) ~= shared.temp_band(shared.usual_temp(name)) then
        name = name .. "@" .. shared.temp_band(t)
      end
      table.insert(parts, name .. ":" .. dose)
    end
    table.sort(parts)
    return table.concat(parts, "+")
  end
  -- (A sample missing its additive or dose reads as a control: tags written by hand once crashed the game here.)
  if not tags.additive or tags.additive == "" or not tags.dose or tags.dose == 0 then return "control" end
  return tags.additive .. ":" .. tags.dose
end

-- The science pack a target's samples cost: the most advanced pack of the technology that unlocks
-- the target's recipe (the last one listed), or the first pack if the recipe is available from the start.
local function pack_for(target)
  -- (0.72) The pack of the sample its trial makes (data_targets.lua chose it): one source for both.
  local trial = prototypes.recipe[shared.trial_recipe(target.key)]
  local made = trial and trial.main_product and shared.pack_of_sample(trial.main_product.name)
  if made then return made end
  if target.pack and prototypes.item[target.pack] then return target.pack end  -- a planet's own pack
  local recipe = prototypes.recipe[shared.target_recipe(target)]
  if recipe and recipe.enabled then return shared.pack end
  for _, tech in pairs(prototypes.technology) do
    for _, effect in pairs(tech.effects or {}) do
      if effect.type == "unlock-recipe" and effect.recipe == shared.target_recipe(target) then
        local ings = tech.research_unit_ingredients
        if ings and #ings > 0 then return ings[#ings].name end
      end
    end
  end
  return shared.pack
end

-- LuaRandomGenerator treats seeds 0..341 alike and nearby seeds similarly, so scramble the map seed
-- (multiplicative hash mod 2^32, in 16-bit halves to stay exact in doubles).
local function mul32(a, b)
  local hi, lo = math.floor(a / 65536), a % 65536
  return ((hi * b % 4294967296) * 65536 + lo * b) % 4294967296
end
local function scrambled_seed(seed)
  local h = mul32((seed + 0x9E3779B9) % 4294967296, 2654435761)
  h = mul32((h + math.floor(h / 65536)) % 4294967296, 2246822519)
  return math.max(h, 342)
end
-- Other mods' targets (truth.extend_registered): a generator per name, from the map seed and the name.
local function registered_streams(seed)
  return function(name)
    return game.create_random_generator(scrambled_seed((seed + 137 + truth.fnv(name)) % 4294967296))
  end
end

-- A station's slots are filtered for samples except the last few: an inserter feeding packs would
-- otherwise fill every slot with packs and no sample could get in.
local function reserve_sample_slots(station)
  local inv = station.get_inventory(defines.inventory.chest)
  if not inv.supports_filters() then return end
  local rec = storage.stations and storage.stations[station.unit_number]
  -- The layout (0.72): the samples waiting, scrap samples (with Space Age), empirical science packs out, then
  -- one slot per science pack kind; slots a higher quality adds hold empirical science packs too. The pack
  -- slots come last so an inserter feeding packs cannot fill the station with them.
  local packs, seen = {}, {}
  for _, target in ipairs(shared.targets) do
    local pack = storage.target_pack and storage.target_pack[target.key] or shared.pack
    if not seen[pack] then seen[pack] = true; table.insert(packs, pack) end
  end
  local S = shared.station_sample_slots
  local scrap_slots = prototypes.item[shared.scrap.item] and shared.scrap.slots or 0
  local first_pack = S + scrap_slots + shared.station_data_slots + 1
  -- The waiting slots take the samples of the packs the station holds (no setting; a lab is
  -- organised by what is belted where), shared among them in turn. A slot holding a sample keeps its filter
  -- until it is analysed; with no pack held, the slots keep what they had (red, new).
  local held = {}
  for _, pack in ipairs(packs) do
    if inv.get_item_count_filtered{name = pack} > 0 and prototypes.item[shared.sample_of(pack)] then
      table.insert(held, pack)
    end
  end
  -- (A test mod may ask for every free slot unfiltered: its labs move samples of several kinds by script.)
  local any = rec and rec.test_any
  for i = 1, #inv do
    local filter
    if i < first_pack and any then
      filter = false
    elseif i <= S then
      if inv[i].valid_for_read then goto next end
      local pack = #held > 0 and held[(i - 1) % #held + 1] or (not inv.get_filter(i) and shared.pack)
      if not pack then goto next end
      filter = {name = shared.sample_of(pack), quality = "normal"}
    elseif i <= S + scrap_slots then
      filter = {name = shared.scrap.item, quality = "normal"}
    elseif i < first_pack then
      filter = {name = research.ITEM, quality = "normal"}
    else
      local pack = packs[i - first_pack + 1]
      filter = pack and {name = pack, quality = "normal", comparator = ">="} or {name = research.ITEM, quality = "normal"}
    end
    if filter == false then inv.set_filter(i, nil)
    elseif inv.can_set_filter(i, filter) then inv.set_filter(i, filter) end
    ::next::
  end
end

-- Take one science pack of any quality, the lowest held first. Returns its quality prototype, or false
-- when there is none. A pack's quality stretches it (0.60): it analyses more samples, by vanilla's own
-- durability multiplier for science packs of that quality (pack_samples).
local qualities_by_level
local function take_pack(inv, pack)
  if not qualities_by_level then
    qualities_by_level = {}
    -- (0.72: every quality but the placeholder, as dosing.lua lists them. Without the Quality mod "normal" is
    -- hidden, and skipping hidden qualities left the list empty: no station ever took a pack.)
    for name, q in pairs(prototypes.quality) do
      if name ~= "quality-unknown" then table.insert(qualities_by_level, q) end
    end
    table.sort(qualities_by_level, function(a, b) return a.level < b.level end)
  end
  for _, q in ipairs(qualities_by_level) do
    if inv.remove{name = pack, count = 1, quality = q.name} == 1 then return q end
  end
  return false
end

-- The samples one pack of this quality analyses.
local function pack_samples(force, quality)
  return math.max(1, math.floor(samples_per_pack(force) * (quality and quality.tool_durability_multiplier or 1) + 0.5))
end

local function register_crafter(entity)
  if entity.name == BENCH or storage.crafters[entity.unit_number] then return end
  storage.crafters[entity.unit_number] = {entity = entity, last = entity.products_finished, debt = 0}
  -- Checked once a second, spread over the second's ticks: bucket = unit number mod CRAFTER_TICKS.
  local bucket = entity.unit_number % CRAFTER_TICKS
  storage.crafter_buckets[bucket] = storage.crafter_buckets[bucket] or {}
  storage.crafter_buckets[bucket][entity.unit_number] = true
  script.register_on_object_destroyed(entity)
end

-- The lawful part of a target's responsiveness (7c), from its recipe: more ingredient kinds and longer
-- crafts respond more. 0.6 + 0.1 x (kinds - 1) + 0.08 x log2(seconds / 0.5), clamped to [0.6, 1.4]
-- (docs/balance.md, payoff spread).
local RESPONSIVENESS_FLOOR = 0.6
local function base_responsiveness()
  local function formula(kinds, seconds)
    return math.max(RESPONSIVENESS_FLOOR,
      math.min(1.4, RESPONSIVENESS_FLOOR + 0.1 * (kinds - 1) + 0.08 * math.log(math.max(seconds, 0.01) / 0.5, 2)))
  end
  local out = {}
  for _, t in ipairs(shared.targets) do
    local r = prototypes.recipe[shared.target_recipe(t)]
    -- Smelting targets (0.50): the floor, like gears. The time term reads assembly time as complexity;
    -- a furnace's heating time is not, and it made plates the largest lever (balance.py, Smelting).
    out[t.key] = t.simplest and RESPONSIVENESS_FLOOR or formula(#r.ingredients, r.energy)
  end
  return out
end

-- Pools from 0.21 to 0.25 were one per force: they become that force's Nauvis pool (before planet
-- conditions every sample behaved as on Nauvis, so that is exactly what they measured). Research data
-- memory from before ("target|question") becomes Nauvis's. Idempotent.
local function migrate_to_planets(pools, memory)
  for fi, v in pairs(pools) do if v.obs then pools[fi] = {nauvis = v} end end
  for _, mem in pairs(memory) do
    local moved = {}
    for id, o in pairs(mem) do
      if select(2, id:gsub("|", "")) == 1 then moved[id] = o end
    end
    for id, o in pairs(moved) do mem[id] = nil; mem["nauvis|" .. id] = o end
  end
end

-- 0.71 (user: one entity a chest, the other a fluid input): hoppers lose the fluid port overlaid on them, and
-- the fluid it held (user: the fluid hopper is a 1x2 pump, which an old hopper's tile may not fit); said once,
-- with how many.
local function split_hoppers()
  local lost = 0
  for _, h in pairs(storage.hoppers or {}) do
    if not h.fluid and h.port then
      local f = h.port.valid and h.port.fluidbox[1]
      if f and f.amount > 0 then lost = lost + 1 end
      if h.port.valid then h.port.destroy() end
      h.port = nil
    end
  end
  if lost > 0 then game.print({"es.migrated-fluid-hoppers", tostring(lost)}) end
end

local function init_storage()
  storage.chillers = storage.chillers or {}
  storage.benches = storage.benches or {}
  -- The bench schedule is rebuilt on every load: each bench looked at on the next tick, then as due.
  storage.bench_wheel = {[game.tick + 1] = {}}
  for unit in pairs(storage.benches) do storage.bench_wheel[game.tick + 1][unit] = true end
  storage.stations = storage.stations or {}
  storage.crafters = storage.crafters or {}
  -- Crafter buckets (0.10.1+): rebuilt from the crafters table, so older saves get them too.
  storage.crafter_buckets = {}
  for unit in pairs(storage.crafters) do
    local b = unit % CRAFTER_TICKS
    storage.crafter_buckets[b] = storage.crafter_buckets[b] or {}
    storage.crafter_buckets[b][unit] = true
  end
  storage.adopted = storage.adopted or {}
  storage.open = storage.open or {}
  storage.gui_selected = storage.gui_selected or {}
  storage.gui_model = storage.gui_model or {}
  -- 0.34: Automatic became the first model choice; a saved choice of a named model moves down one.
  if not storage.gui_model_auto then
    for i, m in pairs(storage.gui_model) do storage.gui_model[i] = m + 1 end
    storage.gui_model_auto = true
  end
  storage.gui_mix_a = storage.gui_mix_a or {}
  storage.gui_mix_b = storage.gui_mix_b or {}
  storage.gui_mix_adopt = storage.gui_mix_adopt or {}
  storage.dirty_stations = storage.dirty_stations or {}
  storage.gui_dirty = storage.gui_dirty or {}
  storage.pools = storage.pools or {}
  migrate_to_planets(storage.pools, storage.data_memory or {})
  storage.dirty_pools = storage.dirty_pools or {}
  storage.gui_dirty_forces = storage.gui_dirty_forces or {}
  storage.missed_tags = storage.missed_tags or 0
  dosing.init()
  -- Adoptions from before 0.7 were {additive, dose}: give them a composition and a route.
  for _, targets in pairs(storage.adopted) do
    for _, a in pairs(targets) do
      if not a.mix then a.mix, a.route = {[a.additive] = a.dose}, "recipe" end
    end
  end
  -- Saves from 0.2 have a truth without curve shapes or the newer targets: regenerate it.
  local t = storage.truth
  -- (Targets added since are filled by truth.extend_targets below: a missing target is no reason to
  -- regenerate a world.)
  local current = t and t.traits and next(t.traits) and t.traits[next(t.traits)].shape
  for _, target in ipairs(shared.targets) do
    if target.key == "gear" or target.key == "circuit" then current = current and t.targets[target.key] end
  end
  -- World strength: a new world takes the setting's; a world keeps the one it was made with (before
  -- 0.57: standard). Set before anything below draws a response.
  local strength = current and strength_of_map() or settings.startup["es-world-strength"].value
  truth.set_strength(strength)
  if not current then
    -- The science seed (0.70): the setting's, or the map's when it is 0; kept in the world, so it never
    -- changes after this. Worlds made before have none and keep the map's (world_seed).
    local seed = settings.global["es-science-seed"].value
    if seed == 0 then seed = game.surfaces[1].map_gen_settings.seed end
    storage.rng = game.create_random_generator(scrambled_seed(seed))
    storage.truth = truth.generate(storage.rng, seed + 113)
    storage.truth.science_seed = seed
    storage.truth.strength = strength
    -- New worlds only: responsiveness (0.16) from its own stream. Older worlds keep theirs unscaled.
    storage.truth.responsiveness = truth.generate_responsiveness(base_responsiveness(),
      game.create_random_generator(scrambled_seed(world_seed() + 29)))
  end
  -- Saves from before 4b have no family chemistry: add it from its own stream (singles unchanged).
  if not storage.truth.chem then
    storage.truth.chem = truth.generate_chemistry(
      game.create_random_generator(scrambled_seed(world_seed() + 7)))
  end
  -- Saves from before an additive existed (oil era, residues, catalysts): fill the missing ones from
  -- their own stream, before anything (chemistry, routes) looks them up. Existing truths are unchanged.
  truth.extend(storage.truth, game.create_random_generator(scrambled_seed(world_seed() + 13)))
  -- Mastery is gone (0.72, research data feeds vanilla's endless technologies instead); its
  -- technologies left with the prototypes, and its counts go.
  storage.mastery_data = nil
  -- Liquid premixes became fluids (0.27): a force that had unlocked one (as its stable or its volatile
  -- item, now gone) keeps it unlocked, heating recipe included.
  for fi, disc in pairs(storage.discovered or {}) do
    local force = game.forces[fi]
    if force then
      for _, pm in ipairs(shared.premixes) do
        if pm.fluid and (disc[pm.name] or disc[pm.name .. "-v"]) then
          force.recipes[pm.name].enabled = true
        end
      end
    end
  end
  -- Liquid premixes' best temperatures (0.27): own stream.
  truth.generate_premix_temps(storage.truth,
    game.create_random_generator(scrambled_seed(world_seed() + 71)))
  -- Every fluid additive's best temperature (0.30): own stream.
  truth.generate_fluid_temps(storage.truth,
    game.create_random_generator(scrambled_seed(world_seed() + 83)))
  -- Science richness by process class (0.72): own stream; added to worlds made before.
  truth.generate_science_richness(storage.truth,
    game.create_random_generator(scrambled_seed(world_seed() + 137)))
  -- Planet conditions (0.26): sensitivities from their own stream; Nauvis is neutral, nothing else changes.
  truth.generate_conditions(storage.truth,
    game.create_random_generator(scrambled_seed(world_seed() + 67)))
  truth.generate_additive_conditions(storage.truth,
    game.create_random_generator(scrambled_seed(world_seed() + 79)))
  -- Quality agents (with the quality mod): their own stream, filling only agents a world lacks.
  if shared.quality_on then
    truth.generate_quality(storage.truth,
      game.create_random_generator(scrambled_seed(world_seed() + 101)))
  end
  -- Targets added after the world was made: their own stream (everything already there unchanged).
  truth.extend_targets(storage.truth,
    game.create_random_generator(scrambled_seed(world_seed() + 53)), base_responsiveness())
  -- Other mods' targets: a stream per target and draw, from the map seed and the target's key.
  truth.extend_registered(storage.truth, registered_streams(world_seed()),
    base_responsiveness())
  -- Saves from before routes: add them from their own stream (everything else unchanged).
  if not storage.truth.routes then
    storage.truth.routes = truth.generate_routes(storage.truth,
      game.create_random_generator(scrambled_seed(world_seed() + 11)))
  end
  -- Premix volatility (slice 3): own stream.
  truth.generate_premix_volatility(storage.truth,
    game.create_random_generator(scrambled_seed(world_seed() + 41)))
  -- Side effects (7d, speed and pollution): own stream; yield responses are unchanged.
  truth.generate_side(storage.truth,
    game.create_random_generator(scrambled_seed(world_seed() + 31)))
  -- Efficiency (0.44): its own stream, after the side effects it leans on.
  truth.generate_efficiency(storage.truth,
    game.create_random_generator(scrambled_seed(world_seed() + 109)))
  -- Freshness (0.52) from its own stream: older worlds gain it without any other draw moving.
  truth.generate_freshness(storage.truth,
    game.create_random_generator(scrambled_seed(world_seed() + 131)))
  -- Additives on routes (7b): responses of route sub-targets, own stream, nothing else changes.
  truth.generate_route_responses(storage.truth,
    game.create_random_generator(scrambled_seed(world_seed() + 23)))
  -- Residue recipes (0.39): enabled wherever the family's activation is.
  for _, force in pairs(game.forces) do
    for _, a in ipairs(shared.additives) do
      if a.residue_of and force.recipes[shared.refine_recipe(a.spent_of)].enabled and force.recipes[a.name] then
        force.recipes[a.name].enabled = true
      end
    end
  end
  -- Residues by family (0.39): stone brick's residue and catalyst merged into stone's. A force that had
  -- discovered the brick's keeps it as the mineral family's.
  for _, force in pairs(game.forces) do
    local disc = storage.discovered and storage.discovered[force.index]
    if disc and disc["es-refined-stone-brick"] then
      disc["es-refined-stone-brick"] = nil
      disc["es-refined-stone"] = true
      local r = force.recipes[shared.refine_recipe("stone")]
      if r then r.enabled = true end
    end
  end
  dosing.prune()
  -- Findings are re-judged on any version change (review 0.68: a 0.66 state, judged with the wrong
  -- cleanliness sign and old bars, stayed until evidence moved).
  storage.dossier_state = nil
  storage.dossier_dirty = {}
  for _, f in pairs(game.forces) do storage.dossier_dirty[f.index] = true end
  -- 0.65: residues leave by the machine's trash slots. Hoppers drop the bar that kept slots for spent and
  -- their old full warnings. Once (0.71: run on every update, it also cleared the bars players set). A record
  -- whose entity is gone goes (the exhaust hopper, retired in 0.65, was removed in 0.71: the game drops any
  -- left in a save, with its residues).
  for unit, h in pairs(storage.hoppers or {}) do
    if not h.entity.valid then
      storage.hoppers[unit] = nil
    else
      if not h.fluid then
        if not storage.hopper_bars_reset then h.entity.get_inventory(defines.inventory.chest).set_bar() end
        if h.warn and h.warn.valid then h.warn.destroy() end
        h.warn, h.spent_full = nil, nil
        dosing.redraw(unit)
      end
    end
  end
  storage.hopper_bars_reset = true
  split_hoppers()
  -- 0.72: additives with evidence stay listed on the screen even when the force cannot make them (scrap
  -- samples); built once from the pools' keys, then kept by ingest.
  if not storage.additives_seen then
    storage.additives_seen = {}
    for fi, pools in pairs(storage.pools or {}) do
      local seen = {}
      for _, pool in pairs(pools) do
        for _, cells in pairs(pool.obs or {}) do
          for key in pairs(cells) do
            for part in key:gmatch("[^+]+") do
              local name = part:match("^(.+):%d+$")
              if name then seen[shared.split_band(name)] = true end
            end
          end
        end
      end
      storage.additives_seen[fi] = seen
    end
  end
  storage.discovered = storage.discovered or {}
  storage.target_pack = {}
  for _, target in ipairs(shared.targets) do storage.target_pack[target.key] = pack_for(target) end
  -- 0.72: samples are one item per science pack. Samples from before become their tier's, tags kept, wherever
  -- they are: inventories, belts, inserters' hands, the ground. Stations keep their record, tier red.
  if not storage.samples_tiered then
    storage.samples_tiered = true
    local function tiered(stack)
      if not (stack and stack.valid_for_read and stack.name == "es-sample") then return end
      local tags = stack.item and stack.item.tags or {}
      local key = tags.target and (shared.target(tags.target) and tags.target or tags.target:match("^([^@]+)"))
      local pack = key and storage.target_pack[key] or shared.pack
      local name = shared.sample_of(pack)
      if not prototypes.item[name] then name = shared.sample_of(shared.pack) end
      stack.set_stack{name = name, count = 1}
      if next(tags) then stack.item.tags = tags end
      storage.samples_migrated = (storage.samples_migrated or 0) + 1
    end
    local BELTS = {["transport-belt"] = true, ["underground-belt"] = true, splitter = true, ["lane-splitter"] = true,
      loader = true, ["loader-1x1"] = true, ["linked-belt"] = true}
    local function inventory(inv)
      if not inv then return end
      for i = 1, #inv do
        -- (A station's slot filtered for the old sample would refuse the new one: unfiltered first; the
        -- station's layout is set again below.)
        if inv[i].valid_for_read and inv[i].name == "es-sample" and inv.supports_filters() then inv.set_filter(i, nil) end
        tiered(inv[i])
      end
    end
    for _, surface in pairs(game.surfaces) do
      for _, e in pairs(surface.find_entities()) do
        if e.valid and e.unit_number then
          for idx = 1, e.get_max_inventory_index() do inventory(e.get_inventory(idx)) end
          if e.type == "inserter" then tiered(e.held_stack) end
          if BELTS[e.type] then
            for li = 1, e.get_max_transport_line_index() do
              local line = e.get_transport_line(li)
              for i = 1, #line do tiered(line[i]) end
            end
          end
        elseif e.valid and e.name == "item-on-ground" then
          tiered(e.stack)
        end
      end
    end
    for _, player in pairs(game.players) do
      for idx = 1, 10 do local ok, inv = pcall(player.get_inventory, idx); if ok then inventory(inv) end end
      tiered(player.cursor_stack)
    end
  end
  -- Stations from before the pool (0.21) held their own observations: they add into their force's pool
  -- (accumulators of n, sum and sum of squares add), and the stations keep only their counts.
  local function merge(into, from)
    for key, acc in pairs(from) do
      into[key] = into[key] or {n = 0, sum = 0, sumsq = 0}
      into[key].n, into[key].sum, into[key].sumsq = into[key].n + acc.n, into[key].sum + acc.sum, into[key].sumsq + acc.sumsq
    end
  end
  for _, station in pairs(storage.stations) do
    if station.entity.valid and station.obs then
      local pool = pool_of(station.entity.force)
      for target_key, obs in pairs(station.obs) do
        pool.obs[target_key] = pool.obs[target_key] or {}
        merge(pool.obs[target_key], obs)
      end
      for effect, by_target in pairs(station.side or {}) do
        pool.side[effect] = pool.side[effect] or {}
        for target_key, obs in pairs(by_target) do
          pool.side[effect][target_key] = pool.side[effect][target_key] or {}
          merge(pool.side[effect][target_key], obs)
        end
      end
      pool.analysed = pool.analysed + (station.analysed or 0)
      pool.unreadable = pool.unreadable + (station.unreadable or 0)
      station.history = {obs = station.obs, side = station.side or {}}  -- what it had is its own history
    end
    station.obs, station.side = nil, nil
    station.history = station.history or {obs = new_obs(), side = {}}
    station.port_source = station.port_source or "force"
  end
  for _, by_surface in pairs(storage.pools) do
    for _, pool in pairs(by_surface) do
      for key, obs in pairs(new_obs()) do pool.obs[key] = pool.obs[key] or obs end
    end
  end
  for _, station in pairs(storage.stations) do
    if station.entity.valid then reserve_sample_slots(station.entity) end  -- stations from before 0.10.3
    station.view_target = station.view_target or shared.targets[1].key
    station.packs_seen = station.packs_seen or {}
  end
  -- Crafting machines built before this mod (or version) was loaded; furnaces since 0.14 (steel).
  for _, surface in pairs(game.surfaces) do
    for _, e in pairs(surface.find_entities_filtered{type = {"assembling-machine", "furnace"}}) do register_crafter(e) end
  end
end

-- (0.72) Alternative recipes retired: their evidence goes, route results ("route:cast") and route sub-targets
-- ("gear@cast"), in every pool and every station's own history; a station shown a sub-target shows its product.
local function prune_routes()
  local function prune(book)
    if not book then return end
    for _, by_target in pairs({book.obs or {}, book.quality or {}}) do
      for target_key, obs in pairs(by_target) do
        if target_key:find("@", 1, true) then by_target[target_key] = nil
        else for key in pairs(obs) do if key:find("^route:") then obs[key] = nil end end end
      end
    end
    for _, by_effect in pairs(book.side or {}) do
      for target_key, obs in pairs(by_effect) do
        if target_key:find("@", 1, true) then by_effect[target_key] = nil
        else for key in pairs(obs) do if key:find("^route:") then obs[key] = nil end end end
      end
    end
  end
  for _, by_surface in pairs(storage.pools or {}) do for _, pool in pairs(by_surface) do prune(pool) end end
  for _, st in pairs(storage.stations or {}) do
    prune(st.history)
    if st.view_target and st.view_target:find("@", 1, true) then st.view_target = st.view_target:match("^[^@]+") end
  end
  storage.evidence_version = (storage.evidence_version or 0) + 1
end

local function gain(target_key, additive, dose)
  return truth.gain(storage.truth, target_key, additive, dose)
end

---------------------------------------------------------------------------
-- Entities
---------------------------------------------------------------------------

-- Station wires in blueprints. The port is not blueprintable (it is created with its station), so its
-- player-made wires to other blueprinted entities travel in the station's tags, as offsets from the
-- station, and are reconnected when a station is built from them, to the real entity or its ghost.
local wire_tags_of
local reconnect_wires
local function port_wire_tags(station, in_blueprint)
  return station and wire_tags_of(station.port, station.entity, in_blueprint)
end
-- Any hidden port's player wires, as offsets from the entity it belongs to (stations, hopper reporters).
wire_tags_of = function(port, owner, in_blueprint)
  if not (port and port.valid) then return nil end
  local sp, list = owner.position, {}
  for from, connector in pairs(port.get_wire_connectors(false)) do
    for _, c in ipairs(connector.connections) do
      local t = c.target.owner
      if c.origin == defines.wire_origin.player and t.valid and in_blueprint(t) then
        table.insert(list, {dx = t.position.x - sp.x, dy = t.position.y - sp.y,
          name = t.name == "entity-ghost" and t.ghost_name or t.name, from = from, to = c.target.wire_connector_id})
      end
    end
  end
  return #list > 0 and list or nil
end

-- A pasted blueprint may be rotated or mirrored (a station has no direction to tell): try the offset's
-- eight orientations and take the first holding an entity (or ghost) of the wired name.
local ORIENTATIONS = {{1, 0, 0, 1}, {0, -1, 1, 0}, {-1, 0, 0, -1}, {0, 1, -1, 0},
                      {-1, 0, 0, 1}, {0, 1, 1, 0}, {1, 0, 0, -1}, {0, -1, -1, 0}}
local function reconnect_port(station, wires) reconnect_wires(station.port, station.entity, wires) end
reconnect_wires = function(port, owner, wires)
  local sp, surface = owner.position, owner.surface
  for _, w in ipairs(wires) do
    for _, o in ipairs(ORIENTATIONS) do
      local x, y = sp.x + o[1] * w.dx + o[2] * w.dy, sp.y + o[3] * w.dx + o[4] * w.dy
      local found
      for _, e in pairs(surface.find_entities_filtered{area = {{x - 0.1, y - 0.1}, {x + 0.1, y + 0.1}},
          force = owner.force}) do
        if (e.name == w.name or (e.name == "entity-ghost" and e.ghost_name == w.name)) and e ~= port then found = e end
      end
      local target = found and found.get_wire_connector(w.to, true)
      if target then port.get_wire_connector(w.from, true).connect_to(target, false); break end
    end
  end
end

local function on_built(event)
  local entity = event.entity
  if not (entity and entity.valid) then return end
  local unit = entity.unit_number
  if entity.name == BENCH then
    storage.benches[unit] = {entity = entity, last = entity.products_finished}
    schedule_bench(unit, storage.benches[unit], game.tick)
    dosing.on_built_with_tags(entity, event.tags)  -- a dose carried by a blueprint
    dosing.mark_neighbours(entity)
  elseif entity.name == STATION then
    local p = entity.position
    local port = entity.surface.create_entity{name = PORT, position = {p.x + 1, p.y + 1}, force = entity.force}
    port.destructible = false
    storage.stations[unit] = {entity = entity, port = port, analysed = 0, unreadable = 0,
      view_target = shared.targets[1].key, packs_seen = {}, history = {obs = new_obs(), side = {}}, port_source = "force",
      }
    reserve_sample_slots(entity)
    storage.dirty_stations[unit] = true
    mark_pool(entity.force)  -- its port shows the pool from the start
    if event.tags and event.tags.es_port_wires then reconnect_port(storage.stations[unit], event.tags.es_port_wires) end
  elseif dosing.IS_HOPPER[entity.name] then
    dosing.on_hopper_built(entity)
    -- A hopper's circuit report travels by blueprint (0.49), its wires too.
    if event.tags and event.tags.es_report then
      hopper_report.set(unit, true)
      local rec = storage.hoppers[unit]
      if event.tags.es_report_wires and rec.reporter then reconnect_wires(rec.reporter, entity, event.tags.es_report_wires) end
    end
    return
  elseif entity.name == shared.chiller.name then
    storage.chillers[unit] = entity
    return
  elseif entity.type == "assembling-machine" or entity.type == "furnace" then
    register_crafter(entity)
    dosing.on_built_with_tags(entity, event.tags)  -- a dose carried by a blueprint
    dosing.mark_neighbours(entity)                 -- hoppers next to it draw a chute into it
    return
  else
    return
  end
  script.register_on_object_destroyed(entity)
end

local function on_destroyed(event)
  local unit = event.useful_id
  if dosing.on_destroyed(unit) then return end
  storage.benches[unit] = nil
  if storage.crafters[unit] then
    local power = storage.crafters[unit].power
    if power and power.valid then power.destroy() end
    storage.crafters[unit] = nil
    local bucket = storage.crafter_buckets[unit % CRAFTER_TICKS]
    if bucket then bucket[unit] = nil end
  end
  local station = storage.stations[unit]
  if station then
    if station.port.valid then station.port.destroy() end
    storage.stations[unit] = nil
    gui.refresh_station(unit)  -- closes windows on the vanished station
  end
end

---------------------------------------------------------------------------
-- Benches
---------------------------------------------------------------------------

local function untagged_sample(stack)
  return stack and stack.valid_for_read and shared.is_sample(stack.name) and not (stack.item and stack.item.get_tag("target"))
end

-- Find the untagged sample a trial just produced: in the output, or already in an inserter's hand.
local function find_new_sample(entity)
  local out = entity.get_inventory(defines.inventory.crafter_output)
  for i = 1, #out do
    if untagged_sample(out[i]) then return out[i] end
  end
  local box = entity.bounding_box
  for _, ins in pairs(entity.surface.find_entities_filtered{type = "inserter",
      area = {{box.left_top.x - 3, box.left_top.y - 3}, {box.right_bottom.x + 3, box.right_bottom.y + 3}}}) do
    if ins.pickup_target == entity and untagged_sample(ins.held_stack) then return ins.held_stack end
  end
end

local function mix_icons(mix)
  local parts = {""}
  for name, dose in pairs(mix) do
    table.insert(parts, (shared.additive(name).fluid and "[fluid=" or "[item=") .. name .. "]×" .. dose .. " ")
  end
  if #parts == 1 then return {"es.control"} end
  return parts
end

-- A trial is destructive: the sample records the yield; the products are consumed by the test. Its
-- dose comes from the bench's hoppers (scripts/dosing.lua): the sample records what it actually got.
-- The spoilage a machine's products inherit (0.52): the count-weighted average spoil of its spoilable
-- inputs, or nil when none of them spoils.
local function inherited_spoil(entity)
  local inv = entity.get_inventory(defines.inventory.crafter_input)
  if not inv then return nil end
  local sum, n = 0, 0
  for i = 1, #inv do
    local st = inv[i]
    if st.valid_for_read and st.spoil_tick and st.spoil_tick > 0 then
      sum, n = sum + st.spoil_percent * st.count, n + st.count
    end
  end
  return n > 0 and sum / n or nil
end

-- What a sample measured besides yield (0.59): its tooltip says so, values stay on the screen.
local function also_measured(sp, pp, ef, fr)
  local parts = {""}
  for _, m in ipairs({{sp, "col-speed"}, {pp, "col-pollution"}, {ef, "col-efficiency"}, {fr, "col-freshness"}}) do
    if m[1] then
      if #parts > 1 then table.insert(parts, ", ") end
      table.insert(parts, {"es." .. m[2]})
    end
  end
  return #parts > 1 and {"es.sample-also", parts} or ""
end

-- One trial's measurement, shared by benches and the showcase's simulated history (0.51): the yield as a
-- percentage of the nominal batch (one decimal), and with Precision instruments 1 speed, cleanliness
-- and efficiency, each with its own noise. `rngs` holds the generators; `seed` makes the lazy ones.
-- Draw order is the benches' own (yield, side, efficiency), so a bench's samples are unchanged.
local function measure_trial(force, key, mix, temps, surface, rngs, seed, inherited)
  local g = truth.gain_on(storage.truth, key, mix or {}, surface_cond(surface), temps)
  local precision = noise_factor(force)
  local y = 1 + g + shared.noise_sd * precision * truth.normal(rngs.yield)
  y = math.max(0, math.floor(y * 1000 + 0.5) / 10)
  -- Speed and pollution are measured too (7d), each with its own noise, from their own generator: a
  -- bench is not physically sped up, so a timed trial does not give speed away.
  local function measured(effect, noise)
    local v = 1 + truth.effect_on(storage.truth, key, mix or {}, effect) + noise * precision * truth.normal(rngs.side)
    return math.floor(v * 1000 + 0.5) / 10
  end
  -- Speed and pollution are measured once Precision instruments 1 is researched (staged reveal): before
  -- that, samples record yield only (the effects are real; production statistics show them).
  local sp, pp, ef
  if shared.stage_ok(force, shared.side_effects_tech) then
    sp, pp = measured("speed", shared.noise_speed), measured("pollution", shared.noise_pollution)
    -- Efficiency (0.44) from its own generator, so the speed and cleanliness draws are unchanged.
    rngs.efficiency = rngs.efficiency or game.create_random_generator(scrambled_seed(seed + 89))
    local v = 1 + truth.effect_on(storage.truth, key, mix or {}, "efficiency")
      + shared.noise_speed * precision * truth.normal(rngs.efficiency)
    ef = math.floor(v * 1000 + 0.5) / 10
  end
  -- Freshness (0.52): the products' spoilage against what they inherit, measured with a fixed error on
  -- the spoil reading, so fresh inputs tell almost nothing (nothing to restore). Recorded as 100 + the
  -- per cent restored, like the other effects; nil when the inputs are fresh or nothing spoils.
  local fr
  if inherited and inherited >= 0.02 and truth.spoilable(key) and shared.stage_ok(force, shared.side_effects_tech) then
    rngs.fresh = rngs.fresh or game.create_random_generator(scrambled_seed(seed + 97))
    local f = truth.effect_on(storage.truth, key, mix or {}, "freshness")
    local out = inherited * (1 - f) + shared.noise_freshness * precision * truth.normal(rngs.fresh)
    fr = math.floor((100 + (1 - out / inherited) * 100) * 10 + 0.5) / 10
  end
  return y, sp, pp, ef, fr
end
-- Quality agents: each unit of the batch rolls against the hidden chance (its own generator); returns
-- how many came out a tier up (k) of how many (b), or nil.
local function roll_quality(key, mix, batch, rngs, seed)
  local chance = mix and truth.quality_chance(storage.truth, key, mix) or 0
  if chance <= 0 then return nil, nil end
  rngs.quality = rngs.quality or game.create_random_generator(scrambled_seed(seed + 71))
  local qk = 0
  for _ = 1, batch do if rngs.quality() < chance then qk = qk + 1 end end
  return qk, batch
end

local function run_trial(bench, info)
  local target = info.target
  local mix, temps = dosing.supply_trial(bench.entity)
  local key = target.key
  -- Trial noise from the bench's own generator: one shared generator gave each bench a subsequence of
  -- draws, and LuaRandomGenerator draws are not independent of the ones before them, so a bench whose
  -- trials fell into a regular pattern read biased (control +4.8% on one map, 4 SE).
  local seed = game.surfaces[1].map_gen_settings.seed + 7919 * bench.entity.unit_number
  local rngs = bench.rngs
  if not rngs then
    rngs = {yield = game.create_random_generator(scrambled_seed(seed)),
            side = game.create_random_generator(scrambled_seed(seed + 37))}
    bench.rngs = rngs
  end
  local y, sp, pp, ef, fr = measure_trial(bench.entity.force, key, mix, temps, bench.entity.surface, rngs, seed,
    inherited_spoil(bench.entity))
  local sample = find_new_sample(bench.entity)
  if not sample then
    storage.missed_tags = storage.missed_tags + 1
    return
  end
  local pack = storage.target_pack[key]
  -- A stale input fails the trial: what is left of a spoilable ingredient came from the stacks the
  -- trial drew from.
  local input = bench.entity.get_inventory(defines.inventory.crafter_input)
  for i = 1, #input do
    local st = input[i]
    if st.valid_for_read and st.spoil_percent >= shared.spoil_fail then
      sample.item.tags = {target = key, failed = true, pack = pack, v = 3, surface = surface_key(bench.entity.surface)}
      sample.item.custom_description = {"es.sample-desc-failed", shared.target_caption(shared.target(key)),
        "[item=" .. st.name .. "]", string.format("%.0f", st.spoil_percent * 100)}
      return
    end
  end
  local single, single_dose = next(mix or {})
  if single and next(mix, single) then single, single_dose = nil, nil end
  -- Quality agents: the sample records how many came out a tier up, of how many.
  local qk, qb = roll_quality(key, mix, target.batch, rngs, seed)
  sample.item.tags = {target = key, mix = mix or {}, additive = single or "", dose = single_dose or 0, y = y,
    sp = sp, pp = pp, ef = ef, fr = fr, pack = pack, v = 3, surface = surface_key(bench.entity.surface), temps = temps, qk = qk, qb = qb}
  sample.item.custom_description = {"", {"es.sample-desc-mix", shared.target_caption(shared.target(key)),
    mix_icons(mix or {}), string.format("%.1f", y), "[item=" .. pack .. "]", tostring(samples_per_pack(bench.entity.force))},
    also_measured(sp, pp, ef, fr)}
end

-- Benches are checked when their craft is due (1,000 benches polled every tick cost about 0.3 ms): one
-- tick before the predicted finish, and again the next tick if it has not come. An idle bench is looked at
-- again after one craft time (a craft it starts cannot end sooner). A bench sped up mid-craft (a beacon,
-- power restored) may finish early: its sample is then tagged in the inserter's hand (the fallback).
schedule_bench = function(unit, bench, now)
  local e = bench.entity
  local delay = 30
  local recipe = e.get_recipe()
  local speed = e.crafting_speed
  if recipe and speed and speed > 0 then
    local craft = recipe.energy / speed * 60
    if e.is_crafting() then
      delay = math.floor((1 - e.crafting_progress) * craft) - 1
    else
      delay = math.floor(craft)
    end
  end
  local due = now + math.max(1, delay)
  storage.bench_wheel[due] = storage.bench_wheel[due] or {}
  storage.bench_wheel[due][unit] = true
end

local function process_bench(bench)
  local e = bench.entity
  local finished = e.products_finished
  local new = finished - bench.last
  bench.last = finished
  if new == 0 then return end
  local recipe = e.get_recipe()
  local info = recipe and trials[recipe.name]
  if info then
    for _ = 1, new do run_trial(bench, info) end
  end
end

---------------------------------------------------------------------------
-- Industrial recipes: the true effect, applied by script and never displayed
---------------------------------------------------------------------------

-- Add or remove products for crafts finished since the last check. Stochastic rounding makes the
-- long-run average exactly the true gain; products already taken are owed and removed later.
-- Hidden speed (7d): while a craft is running, add (or take) the dosed composition's speed effect in
-- proportion to the progress the engine made since the last poll. Never on an idle machine: progress
-- set there starts a phantom craft that consumes nothing (spiked). Remainders are carried.
local function nudge_speed(crafter)
  local e = crafter.entity
  local d = storage.doses[e.unit_number]
  local speed = d and d.active and d.active.speed or 0
  local f, p = e.products_finished, e.crafting_progress
  if speed ~= 0 and crafter.sp_f and e.is_crafting() then
    local advanced = (f - crafter.sp_f) + (p - crafter.sp_p)
    local want = p + speed * advanced + (crafter.sp_debt or 0)
    -- Never 0: writing 0 cancels the craft in progress and its ingredients are lost (spike, 2026-10-02:
    -- 15 resets, 15 crafts' plates gone); 0.001 keeps it. The rest is carried in sp_debt.
    local set = math.max(0.001, math.min(0.999, want))
    crafter.sp_debt = math.max(-1, math.min(1, want - set))
    if set ~= p then e.crafting_progress = set end
    p = set
  end
  crafter.sp_f, crafter.sp_p = f, p
end

-- Pollution of one craft at full power, for the machine's own energy source (electric or burner).
local function pollution_per_craft(e, recipe)
  local per_joule = e.electric_emissions_per_joule
  if not per_joule then
    local burner = e.prototype.burner_prototype
    per_joule = burner and burner.emissions_per_joule
  end
  local rate = (per_joule and per_joule.pollution or 0) * e.prototype.get_max_energy_usage() * 60  -- per second
  -- With its modules (review 0.68: efficiency modules made a dosed machine a net air purifier).
  rate = rate * math.max(0, 1 + e.consumption_bonus) * math.max(0, 1 + e.pollution_bonus)
  return rate * recipe.energy / math.max(e.crafting_speed, 0.01)
end

-- Additive power (0.44): the hidden consumer on a dosed machine. While it works, it draws the extra power
-- an efficiency below zero costs, or feeds back what one above zero saves (at most half the machine's
-- draw, so it is never a generator). Set once a poll from the machine's state then.
local is_electric = {}  -- by entity name: a prototype read crosses into the engine, once per poll was costly
local function set_power(crafter, e, efficiency)
  -- Electric machines only: a burner (a stone furnace) has no connection, and a hidden interface on it
  -- fed or drew power from any pole in range (outside review, 2026-10-02). Its efficiency does nothing.
  local electric = is_electric[e.name]
  if electric == nil then
    electric = e.prototype.electric_energy_source_prototype ~= nil
    is_electric[e.name] = electric
  end
  if not electric then return end
  local c = crafter.power
  if efficiency == 0 and not (c and c.valid) then return end
  -- A consumer for a cost, a producer for a saving: one prototype cannot hold both priorities.
  local name = efficiency > 0 and "es-power-give" or "es-power-draw"
  if c and c.valid and efficiency ~= 0 and c.name ~= name then c.destroy(); c = nil end
  if not (c and c.valid) then
    c = e.surface.create_entity{name = name, position = e.position, force = e.force}
    if not c then return end
    c.destructible = false
    crafter.power = c
  end
  local base = (e.prototype.energy_usage or 0) * (1 + (e.consumption_bonus or 0))
  local working = e.status == defines.entity_status.working
  local use = working and efficiency < 0 and base * -efficiency or 0
  local give = working and efficiency > 0 and base * math.min(efficiency, 0.5) or 0
  c.power_usage, c.power_production = use, give
  c.electric_buffer_size = math.max(use, give) * 2 + 1
end

-- Freshness in production (0.52): a dosed machine's products come out fresher than they inherit, so the
-- machine is looked at when a craft is due (as benches are: once a second, inserters would take most
-- products away first). The new units are the output's count above the last look; their inherited
-- spoilage is the difference of the averages, restored by the dose's fraction; a matching stack already
-- in the hand of an inserter picking from the machine is restored too.
local FRESH_LOOK = 10
local function schedule_fresh(unit, c, now)
  local e = c.entity
  local delay = 30
  local recipe = e.get_recipe()
  local speed = e.crafting_speed
  if recipe and speed and speed > 0 then
    -- At the dosed speed: the speed effect's nudge makes the machine craft (1 + speed) times faster than
    -- the engine's crafting speed says (predicted at that speed, half the looks came after two crafts).
    local d = storage.doses[e.unit_number]
    local sp = math.max(-0.9, d and d.active and d.active.speed or 0)
    local craft = recipe.energy / speed * 60 / (1 + sp)
    delay = e.is_crafting() and math.floor((1 - e.crafting_progress) * craft) - 1 or math.floor(craft)
  end
  -- At least every FRESH_LOOK ticks: a fast inserter carries a product off in about 12, so a look within
  -- 10 of a craft finds its units in the output or a hand. Predicting the craft's end missed a craft in
  -- three or four (the machine waits for ingredients, the speed nudge jumps its progress); a look that
  -- finds no new craft compares one counter.
  delay = math.min(delay, FRESH_LOOK)
  local due = now + math.max(1, delay)
  c.fresh_next = due  -- an earlier entry for another tick is stale (rescheduled after a speed nudge)
  storage.fresh_wheel = storage.fresh_wheel or {}
  storage.fresh_wheel[due] = storage.fresh_wheel[due] or {}
  storage.fresh_wheel[due][unit] = true
end
local function process_fresh(unit, c, now)
  if c.fresh_next and c.fresh_next ~= now then return end  -- rescheduled since
  local e = c.entity
  local f = c.fresh_f or 0
  if f <= 0 then c.fresh_on = nil; return end  -- the dose no longer restores: off the wheel
  local finished = e.products_finished
  local crafts = finished - (c.fresh_last or finished)
  if crafts > 0 then
    -- The new units carry the spoilage they inherited: restore exactly that many units by the dose's
    -- fraction, first those in the hands of inserters picking from the machine (the newest), then in the
    -- output. (Estimating it from the inputs read the next craft's fresher top-up: a fifth of the effect
    -- went missing.)
    local recipe = e.get_recipe()
    local per = recipe and recipe.products[1] and recipe.products[1].amount or 1
    local new = crafts * per
    local box = e.bounding_box
    for _, ins in pairs(e.surface.find_entities_filtered{type = "inserter",
        area = {{box.left_top.x - 3, box.left_top.y - 3}, {box.right_bottom.x + 3, box.right_bottom.y + 3}}}) do
      local h = ins.held_stack
      if new > 0 and ins.pickup_target == e and h.valid_for_read and h.name == c.fresh_item then
        local units = math.min(new, h.count)
        h.spoil_percent = h.spoil_percent * (1 - f * units / h.count)
        new = new - units
      end
    end
    local out = e.get_inventory(defines.inventory.crafter_output)
    for i = 1, #out do
      local st = out[i]
      if new > 0 and st.valid_for_read and st.name == c.fresh_item then
        local units = math.min(new, st.count)
        st.spoil_percent = st.spoil_percent * (1 - f * units / st.count)
        new = new - units
      end
    end
    local left = new  -- units the restoration did not find (taken away before the look)
    c.fresh_missed = (c.fresh_missed or 0) + left  -- for tests: new units the restoration did not find
    c.fresh_restored = (c.fresh_restored or 0) + crafts  -- for tests
  end
  c.fresh_last = finished
  schedule_fresh(unit, c, now)
end

local function process_crafter(crafter)
  local e = crafter.entity
  nudge_speed(crafter)
  local finished = e.products_finished
  local new = finished - crafter.last
  crafter.last = finished
  if new <= 0 then
    -- Nothing made this second: the machine is idle, so its additive power stops too.
    local c = crafter.power
    if c and c.valid and (c.power_usage > 0 or c.power_production > 0) then c.power_usage, c.power_production = 0, 0 end
    return
  end
  local recipe = e.get_recipe()
  local info = recipe and industrial[recipe.name]
  if not info then
    -- Not a target's recipe (any more): the dose's running effects stop with it (review 0.68: speed and
    -- the hidden power kept running after a switch to pipes).
    local d0 = storage.doses[e.unit_number]
    if d0 then d0.active = nil end
    crafter.fresh_f = 0
    set_power(crafter, e, 0)
    return
  end
  local target = info.target
  -- Products per craft of this recipe (read once from the prototype).
  info.per_craft = info.per_craft or recipe.products[1].amount
  local per_craft = info.per_craft
  -- A dosed machine: its composition's effect when the hoppers supplied it (on a route, route gain x
  -- composition gain on the route); otherwise the route's own yield, or nothing on a vanilla recipe.
  local key = target.key
  local mix, temps = dosing.supply(e, new * per_craft, target.batch)
  local d = storage.doses[e.unit_number]
  local g
  if mix then  -- dossiers: products made with this composition, under its evidence key
    dossiers.record_made(e.force, target.key, sample_key{mix = mix, temps = temps}, new * per_craft)
  end
  -- (0.72, advisory pass: production statistics mix every line of a product, so a dosed line could not be
  -- told from the others) What this machine made with its composition, counted from the first craft after it
  -- changed; the dose panel shows it, with the products the dose added.
  if mix then
    local k = sample_key{mix = mix, temps = temps}
    if crafter.dose_key ~= k then crafter.dose_key, crafter.dose_made, crafter.dose_extra = k, 0, 0 end
    crafter.dose_made = crafter.dose_made + new * per_craft
  end
  if mix then
    g = truth.gain_on(storage.truth, key, mix, surface_cond(e.surface), temps)
    -- Side effects of the supplied composition: speed from now on (nudge_speed), pollution for these
    -- crafts (less when positive), credited to the machine in the pollution statistics.
    d.active = {speed = truth.effect_on(storage.truth, key, mix, "speed"),
                pollution = truth.effect_on(storage.truth, key, mix, "pollution"),
                efficiency = truth.effect_on(storage.truth, key, mix, "efficiency")}
    set_power(crafter, e, d.active.efficiency)
    -- Freshness: on the wheel while the dose restores something on a spoilable target.
    if truth.spoilable(key) then
      crafter.fresh_f = truth.effect_on(storage.truth, key, mix, "freshness")
      crafter.fresh_item = target.result
      if crafter.fresh_f > 0 and not crafter.fresh_on then
        crafter.fresh_on, crafter.fresh_last = true, e.products_finished
        schedule_fresh(e.unit_number, crafter, game.tick)
      elseif crafter.fresh_on then
        -- The speed nudge moves the craft's progress: the look is due again from where it is now (a sped
        -- up machine finished before the predicted tick, and its products were gone by then).
        schedule_fresh(e.unit_number, crafter, game.tick)
      end
    end
    -- Real crafts only: `new` counts products, productivity's included.
    local extra = -d.active.pollution * pollution_per_craft(e, recipe) * new / (1 + math.max(0, e.productivity_bonus))
    if extra ~= 0 then e.surface.pollute(e.position, extra, e.name) end
    crafter.polluted = (crafter.polluted or 0) + extra  -- for tests: pollution added (or taken) so far
  else
    if d then d.active = nil end  -- not dosed: no side effects either
    crafter.fresh_f = 0
    set_power(crafter, e, 0)
    return
  end
  -- The productivity cap (decided 2026-09-30): the mod's yield counts toward the recipe's
  -- maximum_productivity. `new` counts productivity crafts too, so the output already carries
  -- (1 + P); the mod adds up to (1 + cap) / (1 + P) - 1 of it. Past the cap, a recycler's quarter
  -- return would make craft-recycle loops produce items from nothing. P = modules and beacons (the
  -- entity's bonus) + the recipe's research bonus, clamped at the cap as the engine does (checked by
  -- spike: the entity's value leaves research out).
  if g > 0 then
    local cap = recipe.prototype.maximum_productivity
    local p = math.min(e.productivity_bonus + recipe.productivity_bonus, cap)
    local room = (1 + cap) / (1 + p) - 1
    -- Say so in the dose panel: the additive is still consumed, and its yield is (partly) lost.
    if room < g and d and mix then d.status = {"es.dose-capped", string.format("%.0f", math.max(0, room) * 100)} end
    g = math.min(g, room)
  end
  -- Whole products are applied as the fractional effect accumulates: deterministic and exact in the
  -- long run (never more than one product off). Stochastic rounding with the shared generator was
  -- measurably biased (its draws are not independent of the draws before them).
  local total = (crafter.fraction or 0) + new * per_craft * g - crafter.debt
  local delta = total >= 0 and math.floor(total) or -math.floor(-total)
  crafter.fraction = total - delta
  crafter.debt = 0
  crafter.bonus_total = (crafter.bonus_total or 0) + delta  -- for tests: extra products added so far
  if mix then crafter.dose_extra = (crafter.dose_extra or 0) + delta end
  -- (0.72) The force's net extra products from doses, for the Progress tab (fewer, where a dose hurts).
  storage.extra_total = storage.extra_total or {}
  storage.extra_total[e.force.index] = (storage.extra_total[e.force.index] or 0) + delta
  local out = e.get_inventory(defines.inventory.crafter_output)
  -- Script-made changes are invisible to the production graph unless recorded, and production is the
  -- only place the player can learn an adopted effect.
  local stats = e.force.get_item_production_statistics(e.surface)
  -- Extra products that did not fit (a backed-up line keeps its output full) wait here and go in when
  -- there is room, instead of being spilled on the ground. A machine blocked on its output stops
  -- crafting, so this holds at most a poll's worth; it is lost if the machine is removed meanwhile.
  -- Extra products of a spoilable target come out as stale as the inputs they are made from (0.52):
  -- inserted fresh, they made a yield additive a free freshness one.
  -- (0.72) As stale as the products they join: those already in the output (the dose's freshness applied),
  -- else the inputs with it applied, else the last seen. A machine fed one craft at a time had no inputs left at
  -- the poll, and its extras came out fresh (the integration test's dosed bioflux read fresher than its dose).
  local spoil
  if truth.spoilable(target.key) then
    local sum, n = 0, 0
    for i = 1, #out do
      local st = out[i]
      if st.valid_for_read and st.name == target.result and st.spoil_tick and st.spoil_tick > 0 then
        sum, n = sum + st.spoil_percent * st.count, n + st.count
      end
    end
    if n > 0 then spoil = sum / n
    else
      spoil = inherited_spoil(e)
      if spoil and (crafter.fresh_f or 0) > 0 then spoil = spoil * (1 - crafter.fresh_f) end  -- products of a dosed craft
    end
    if spoil then crafter.extra_spoil = spoil else spoil = crafter.extra_spoil end
  end
  local function deliver(quality, count)
    local inserted = count > 0 and out.insert{name = target.result, count = count, quality = quality,
      spoil_percent = spoil} or 0
    if inserted > 0 then stats.on_flow({name = target.result, quality = quality}, inserted) end
    local left = count - inserted
    crafter.pending = crafter.pending or {}
    crafter.pending[quality] = left > 0 and left or nil
  end
  for quality, count in pairs(crafter.pending or {}) do deliver(quality, count) end
  if delta > 0 then
    -- Extra products take the quality the machine crafts at (its recipe quality) and, with a quality
    -- effect (modules, beacons), the same chance per unit to upgrade, tier by tier, as its crafts.
    local _, recipe_quality = e.get_recipe()
    local base = recipe_quality or prototypes.quality.normal
    -- The quality effect is scaled by the tier's next_probability (0.2 x 0.1 = a 2% chance).
    local chance = math.max(0, math.min(1, ((e.effects and e.effects.quality) or 0) * base.next_probability))
    local per_quality = {}
    -- Its own generator: draws from the shared one are not independent of the trial draws around them.
    storage.quality_rng = storage.quality_rng
      or game.create_random_generator(scrambled_seed(game.surfaces[1].map_gen_settings.seed + 17))
    local rng = storage.quality_rng
    for _ = 1, delta do
      local q = base
      if chance > 0 and q.next and rng() < chance then
        q = q.next
        while q.next and rng() < q.next_probability do q = q.next end
      end
      per_quality[q.name] = (per_quality[q.name] or 0) + 1
    end
    for quality, count in pairs(per_quality) do
      deliver(quality, count + (crafter.pending and crafter.pending[quality] or 0))
    end
  elseif delta < 0 then
    -- Fewer products: take them from the output (any quality). If inserters already took them, a
    -- lower yield is the same as spending more material per product: take that from the inputs.
    local need = -delta
    for _, item in pairs(out.get_contents()) do
      if need > 0 and item.name == target.result then
        local removed = out.remove{name = item.name, count = need, quality = item.quality}
        -- Recorded as consumed: net production comes out right (the engine already counted them made).
        if removed > 0 then stats.on_flow({name = item.name, quality = item.quality}, -removed) end
        crafter.outputs_taken = (crafter.outputs_taken or 0) + removed  -- for tests
        need = need - removed
      end
    end
    if need > 0 then
      local _, quality = e.get_recipe()
      local inv_in = e.get_inventory(defines.inventory.crafter_input)
      -- Output per input must come to (1 + g) of nominal, so the missing products' worth of inputs is
      -- scaled by 1 / (1 + g) (g is at least -0.6). Fractions accumulate per ingredient. A machine fed
      -- just in time often holds less than that: what was taken is credited, and only the share not
      -- taken is owed (2026-10-02: owing all of it again each poll took a fed machine's inputs at every
      -- poll and starved it, -47% output where -4% was due).
      local covered = 1
      crafter.input_fraction = crafter.input_fraction or {}
      for _, ing in pairs(recipe.ingredients) do
        if ing.type == "item" then
          local want = (crafter.input_fraction[ing.name] or 0) + ing.amount * need / per_craft / (1 + g)
          local count = math.floor(want)
          crafter.input_fraction[ing.name] = want - count
          if count > 0 then
            local removed = inv_in.remove{name = ing.name, count = count, quality = quality and quality.name or "normal"}
            crafter.inputs_taken = (crafter.inputs_taken or 0) + removed  -- for tests
            if removed > 0 then stats.on_flow({name = ing.name, quality = quality and quality.name or "normal"}, -removed) end
            covered = math.min(covered, removed / count)
          end
        end
      end
      need = need * (1 - covered)
    end
    crafter.debt = math.min(need, per_craft)  -- owed next time, never growing without bound
  end
  -- Quality agents: each product made this poll comes out a tier up
  -- with the composition's chance. That many are swapped in the output for the next tier (and on, with
  -- each tier's next_probability, as the engine chains). Products inserters already took are owed and
  -- swapped from the next ones (at most a few crafts' worth). Both flows are recorded.
  local qc = mix and truth.quality_chance(storage.truth, key, mix) or 0
  if qc > 0 then
    local _, rq = e.get_recipe()
    local base = rq or prototypes.quality.normal
    if base.next then
      storage.quality_rng = storage.quality_rng
        or game.create_random_generator(scrambled_seed(game.surfaces[1].map_gen_settings.seed + 17))
      local rng = storage.quality_rng
      local up = crafter.quality_owed or 0
      crafter.quality_rolled = (crafter.quality_rolled or 0) + new * per_craft   -- (for tests)
      crafter.quality_qc = qc
      for _ = 1, new * per_craft do
        if rng() < qc then up = up + 1; crafter.quality_earned = (crafter.quality_earned or 0) + 1 end  -- (for tests)
      end
      local id = {name = target.result, quality = base.name}
      local n = math.min(up, out.get_item_count(id))
      if n > 0 then
        out.remove{name = target.result, count = n, quality = base.name}
        stats.on_flow(id, -n)
        local per_quality = {}
        for _ = 1, n do
          local q = base.next
          while q.next and rng() < q.next_probability do q = q.next end
          per_quality[q.name] = (per_quality[q.name] or 0) + 1
        end
        for quality, count in pairs(per_quality) do
          deliver(quality, count + (crafter.pending and crafter.pending[quality] or 0))
        end
        crafter.upgraded_total = (crafter.upgraded_total or 0) + n  -- for tests
      end
      up = up - n
      -- Inserters usually empty the output before a poll sees it: what is still owed goes on the craft
      -- in progress, whose products all come out upgraded (checked by spike, 2026-10-02: a write to
      -- result_quality holds to the end of the craft). One craft a poll, when one is in progress; a machine
      -- idle at some polls (short of input) is paid at later ones, and owed beyond ten crafts is lost.
      -- result_quality is nil when no craft is in progress (is_crafting() reads false right after a
      -- write to crafting_progress, while the craft goes on).
      if up >= per_craft and e.result_quality and e.result_quality.name == base.name then
        local q = base.next
        while q.next and rng() < q.next_probability do q = q.next end
        e.result_quality = q
        up = up - per_craft
        crafter.upgraded_total = (crafter.upgraded_total or 0) + per_craft  -- for tests
      end
      if up > 10 * per_craft then  -- (for tests: owed past the cap is lost)
        crafter.quality_lost = (crafter.quality_lost or 0) + up - 10 * per_craft
      end
      crafter.quality_owed = math.min(up, 10 * per_craft)
    end
  end
end


---------------------------------------------------------------------------
-- Stations
---------------------------------------------------------------------------

-- A residue's discovery: its activation and its own recipe, and the catalyst counted as discovered.
local function unlock_activation(force, name)
  local a = shared.additive(name)
  force.recipes[shared.refine_recipe(a.spent_of)].enabled = true
  if force.recipes[name] then force.recipes[name].enabled = true end
  storage.discovered[force.index] = storage.discovered[force.index] or {}
  storage.discovered[force.index][shared.refined_of(a.spent_of)] = true
end

-- Discovery chains by evidence: a residue tested alone that a station shows to have a clear effect on a
-- target (p < 0.05 against that target's control) unlocks refining it, for that station's force.
local function check_discovery(force, pool, target_key, key)
  local name = key:match("^([^+:]+):%d+$")
  local a = name and shared.additive(name)
  if not (a and a.spent_of) then return end
  local refine = force.recipes[shared.refine_recipe(a.spent_of)]
  if refine.enabled then return end
  local obs = pool.obs[target_key]
  -- At least DISCOVERY_MIN_N samples on each side: the station re-tests after every sample, and the
  -- first few would otherwise unlock on noise far more often than 5% of the time.
  if not (obs[key] and obs.control and obs[key].n >= DISCOVERY_MIN_N and obs.control.n >= DISCOVERY_MIN_N) then return end
  local rs, cs = stats.summary(obs[key]), stats.summary(obs.control)
  -- A gain, not just any effect: residues mostly harm, and a clear harm is no lead.
  if not (rs and cs and rs.mean > cs.mean) then return end
  local p = stats.welch(rs, cs)
  if not (p and p < 0.05) then return end
  unlock_activation(force, name)
  -- (0.72, user: the message read like an aphorism) A plain unlock notice, as for a premix.
  force.print({"es.recipe-unlocked", gui.item_caption(shared.refined_of(a.spent_of))})
end

-- Achievements (0.72, data.lua): granted to every player of the force, and to players who join it later.
local function achieve(force, name)
  if not prototypes.achievement[name] then return end  -- (those of Space Age or Quality, without them)
  storage.achieved = storage.achieved or {}
  storage.achieved[force.index] = storage.achieved[force.index] or {}
  storage.achieved[force.index][name] = true
  for _, player in pairs(force.players) do player.unlock_achievement(name) end
end
research.on_settled = function(force_index, question)
  local force = game.forces[force_index]
  if not force then return end
  storage.settled_count = storage.settled_count or {}
  storage.settled_count[force_index] = (storage.settled_count[force_index] or 0) + 1
  if storage.settled_count[force_index] >= shared.achievement_settled then achieve(force, "es-publish-or-perish") end
  if question:find("^quality:") then achieve(force, "es-gold-standard") end
end
local FIELDWORK = {"nauvis", "vulcanus", "fulgora", "gleba", "aquilo"}
dossiers.on_judged = function(force, r)
  local any = r.exc_done > 0
  for _, p in pairs(r.planets) do if p.done > 0 then any = true end end
  if any then achieve(force, "es-statistically-significant") end
  local all = true
  for _, planet in ipairs(FIELDWORK) do
    local p = r.planets[planet]
    if not (p and p.done > 0) then all = false end
  end
  if all then achieve(force, "es-fieldwork") end
end

-- Premixes by evidence (slice 3): the rule is research.premix_gate. Checked whenever a sample lands in any of a
-- mixture's four groups (0.72: before, only a mixture's own sample ran it, so a set completed by its singles or
-- controls waited for one more mixture sample).
local function check_premix(force, pool, target_key, key)
  local gate = research.premix_gate(force, pool.obs[target_key], key)
  if not (gate and gate.ready) or gate.recipe.enabled then return end
  local g = gate.groups
  local inter = regress.interaction(stats.summary(g[1]), stats.summary(g[2]), stats.summary(g[3]), stats.summary(g[4]))
  if not (inter and inter.p and inter.p < 0.05 and inter.estimate > 0) then return end
  gate.recipe.enabled = true
  storage.discovered[force.index] = storage.discovered[force.index] or {}
  storage.discovered[force.index][gate.recipe.name] = true
  force.print({"es.recipe-unlocked", gui.item_caption(gate.recipe.name)})
  achieve(force, "es-sum-of-parts")
end
-- A sample under `key` can complete any mixture's set it belongs to: the mixture itself, one of its members
-- alone at its dose, or the control (every two-additive mixture on the target).
local function check_premixes(force, pool, target_key, key)
  if key:find("+", 1, true) then check_premix(force, pool, target_key, key); return end
  local obs = pool.obs[target_key]
  if not obs then return end
  for k in pairs(obs) do
    if k:find("+", 1, true) and (key == "control" or ("+" .. k .. "+"):find("+" .. key .. "+", 1, true)) then
      check_premix(force, pool, target_key, k)
    end
  end
end

-- Record one analysed sample in a book (the force's pool, or a station's own history: both have obs
-- and side): yield, speed and pollution under the sample's key, and a route trial as its route's control.
local function record(book, tags, key, y)
  local function acc(t, k)
    t[k] = t[k] or {n = 0, sum = 0, sumsq = 0}
    return t[k]
  end
  book.obs[tags.target] = book.obs[tags.target] or {control = {n = 0, sum = 0, sumsq = 0}}
  local cell = acc(book.obs[tags.target], key)
  stats.add(cell, (y - 100) * 10)  -- yield % of nominal -> gain in per mille
  -- (0.72) When this target's evidence last changed, for caches that keep one target's work (findings).
  book.changed = book.changed or {}
  book.changed[tags.target] = storage.evidence_version
  -- (0.72) Scrap samples counted apart: research data's cap on unrepeated doses is for a player's own skim,
  -- not for what Fulgora's scrap happened to land on.
  if tags.scrap then cell.scrap_n = (cell.scrap_n or 0) + 1 end
  -- Speed and pollution (7d): the same keys, in their own tables.
  local function add_side(effect, value, target_key)
    if not value then return end
    book.side[effect] = book.side[effect] or {}
    local t = book.side[effect]
    t[target_key] = t[target_key] or {control = {n = 0, sum = 0, sumsq = 0}}
    stats.add(acc(t[target_key], target_key == tags.target and key or "control"), (value - 100) * 10)
  end
  add_side("speed", tags.sp, tags.target)
  add_side("pollution", tags.pp, tags.target)
  add_side("efficiency", tags.ef, tags.target)
  add_side("freshness", tags.fr, tags.target)
  -- Quality agents: units upgraded (k) of units rolled (b), pooled per composition.
  if tags.qb then
    book.quality = book.quality or {}
    book.quality[tags.target] = book.quality[tags.target] or {}
    local q = book.quality[tags.target][key] or {n = 0, k = 0, b = 0}
    q.n, q.k, q.b = q.n + 1, q.k + tags.qk, q.b + tags.qb
    book.quality[tags.target][key] = q
  end
end

-- One analysed sample into the force's pool (0.51: shared by stations and the showcase's simulated
-- history): research data, the pool and the station's own history, then discovery and premix.
-- `station` is nil for history: its research data then counts in the pool only.
-- The Progress tab's record (0.72): a force's totals every shared.progress_ticks. Aligned arrays: t (tick),
-- tiers[pack] (samples analysed needing that pack), data (empirical science packs made), settled (questions
-- settled), findings (findings done). Thinned by half past shared.progress_points.
local function progress_now(force)
  local fi = force.index
  local data = 0
  for _, pool in pairs(storage.pools and storage.pools[fi] or {}) do data = data + (pool.data_made or 0) end
  local findings = 0
  for _ in pairs(storage.dossier_done_at and storage.dossier_done_at[fi] or {}) do findings = findings + 1 end
  return {tiers = storage.samples_by_tier and storage.samples_by_tier[fi] or {}, data = data,
    settled = storage.settled_count and storage.settled_count[fi] or 0, findings = findings,
    dosed = storage.dosed_total and storage.dosed_total[fi] or 0, extra = storage.extra_total and storage.extra_total[fi] or 0}
end
gui.progress_now = progress_now  -- (the Progress tab draws the current totals as its last point)
local function record_progress(force)
  storage.progress = storage.progress or {}
  local P = storage.progress[force.index] or {t = {}, tiers = {}, data = {}, settled = {}, findings = {}}
  P.dosed, P.extra = P.dosed or {}, P.extra or {}  -- (added after the first snapshots of some saves)
  storage.progress[force.index] = P
  local now = progress_now(force)
  table.insert(P.t, game.tick)
  local i = #P.t
  for pack, count in pairs(now.tiers) do
    P.tiers[pack] = P.tiers[pack] or {}
    P.tiers[pack][i] = count
  end
  P.data[i], P.settled[i], P.findings[i], P.dosed[i], P.extra[i] = now.data, now.settled, now.findings, now.dosed, now.extra
  if i > shared.progress_points then
    local function thin(list, n_)
      local out = {}
      for k = 1, n_ do if k % 2 == 1 or k > n_ / 2 then out[#out + 1] = list[k] or false end end
      return out
    end
    local n_ = i
    P.t, P.data, P.settled, P.findings = thin(P.t, n_), thin(P.data, n_), thin(P.settled, n_), thin(P.findings, n_)
    P.dosed, P.extra = thin(P.dosed, n_), thin(P.extra, n_)
    for pack, list in pairs(P.tiers) do P.tiers[pack] = thin(list, n_) end
  end
end

local function ingest(force, pool, tags, skey, station, no_data)
  local key = sample_key(tags)
  -- Samples from before 0.5 (no format tag) recorded a product count, not a percentage; a
  -- percentage is never as low as twice the batch for these targets, so convert those.
  -- They were made with that era's batches (a363f6f: gears, circuits, engines), not today's.
  local y = tags.y
  local old_batch = COUNT_FORMAT_BATCH[tags.target]
  if not tags.v and old_batch and y <= 2 * old_batch then y = y / old_batch * 100 end
  -- Research data: what this sample can teach the force, judged before it is added.
  local rate = no_data and 0 or research.rate(force.index, pool.obs[tags.target], tags.target, key, skey,
    pool.quality and pool.quality[tags.target])  -- (scrap samples make none)
  pool.data_made = (pool.data_made or 0) + rate
  if station then
    station.data_made = (station.data_made or 0) + rate
    station.data_fraction = (station.data_fraction or 0) + rate
    local whole = math.floor(station.data_fraction)
    if whole > 0 then
      -- Into its own slots; what does not fit waits in the fraction for the next sample.
      local inv = station.entity.get_inventory(defines.inventory.chest)
      station.data_fraction = station.data_fraction - inv.insert{name = research.ITEM, count = whole}
    end
  end
  -- Into the force's pool and this station's own history (its port can read either).
  record(pool, tags, key, y)
  -- The station's own history keeps its own planet's samples (a port reading it never mixes
  -- conditions).
  if station and skey == surface_key(station.entity.surface) then record(station.history, tags, key, y) end
  -- (From the key, as the migration reads it: a sample names its additive in its mix or on its own.)
  storage.additives_seen = storage.additives_seen or {}
  storage.additives_seen[force.index] = storage.additives_seen[force.index] or {}
  for part in key:gmatch("[^+]+") do
    local name = part:match("^(.+):%d+$")
    if name then storage.additives_seen[force.index][shared.split_band(name)] = true end
  end
  check_discovery(force, pool, tags.target, key)
  check_premixes(force, pool, tags.target, key)
  pool.analysed = pool.analysed + 1
  mark_pool(force)
  if station then  -- (a station's analysis, not a simulated history)
    storage.samples_count = storage.samples_count or {}
    local n = (storage.samples_count[force.index] or 0) + 1
    storage.samples_count[force.index] = n
    if n == 1 then achieve(force, "es-lab-rat") end
    -- (0.72) By the science pack the sample needs, for the Progress tab.
    local pack = tags.pack or (storage.target_pack and storage.target_pack[tags.target]) or shared.pack
    storage.samples_by_tier = storage.samples_by_tier or {}
    storage.samples_by_tier[force.index] = storage.samples_by_tier[force.index] or {}
    storage.samples_by_tier[force.index][pack] = (storage.samples_by_tier[force.index][pack] or 0) + 1
    if n >= shared.achievement_samples then achieve(force, "es-large-numbers") end
  end
end

-- Fulgora scrap samples. The targets a scrap sample can be: those
-- among scrap's contents, weighted by their share of its output; with Scrap forensics 1, those one recipe
-- step above them; with 2, every target (added ones at the smallest content weight).
local function scrap_targets(force)
  local r = prototypes.recipe["scrap-recycling"]
  local share = {}
  for _, p in pairs(r and r.products or {}) do
    if p.name ~= shared.scrap.item then
      local amount = p.amount or ((p.amount_min or 0) + (p.amount_max or 0)) / 2
      share[p.name] = (share[p.name] or 0) + (p.probability or 1) * amount
    end
  end
  local level = 0
  for i, tech in ipairs(shared.scrap.forensics) do
    if force.technologies[tech] and force.technologies[tech].researched then level = i end
  end
  local list, least = {}, nil
  for _, t in ipairs(shared.targets) do
    if share[t.result] then
      table.insert(list, {key = t.key, w = share[t.result]})
      least = math.min(least or share[t.result], share[t.result])
    end
  end
  if level >= 1 then
    for _, t in ipairs(shared.targets) do
      if not share[t.result] then
        local rec, near = prototypes.recipe[shared.target_recipe(t)], level >= 2
        for _, ing in pairs(rec and rec.ingredients or {}) do if share[ing.name] then near = true end end
        if near then table.insert(list, {key = t.key, w = least or 1}) end
      end
    end
  end
  return list
end
-- An additive's fixed weight on this map (lognormal, from a hash: no stream).
local function scrap_additive_weight(name)
  local seed = storage.truth.quirk_seed or game.surfaces[1].map_gen_settings.seed
  local u1 = (truth.fnv(seed .. ":scrap:" .. name .. ":1") + 0.5) / 4294967296
  local u2 = (truth.fnv(seed .. ":scrap:" .. name .. ":2") + 0.5) / 4294967296
  return math.exp(math.sqrt(-2 * math.log(u1)) * math.cos(2 * math.pi * u2))
end
local function pick(list, e, rng)
  local total = 0
  for _, x in ipairs(list) do total = total + x.w ^ e end
  local u = rng() * total
  for _, x in ipairs(list) do
    u = u - x.w ^ e
    if u <= 0 then return x end
  end
  return list[#list]
end
-- One scrap sample's cell, drawn with a pack of this tier; nil for a dud (a full cell, or nothing to draw).
local function draw_scrap(force, pool, tier, rng)
  local SC = shared.scrap
  local e = math.max(0.05, 1 - SC.flatten * tier)
  local targets = scrap_targets(force)
  if #targets == 0 then return nil end
  local t = pick(targets, e, rng)
  pool.scrap_counts = pool.scrap_counts or {}
  local counts = pool.scrap_counts
  local cell, cap
  if rng() < SC.control_share then
    cell, cap = {target = t.key, dose = 0}, SC.control_cap
  else
    local adds = {}
    for _, a in ipairs(gui.visible_additives(force)) do
      -- (Not the biological family, 0.62: Fulgora's ruins carry no traces of Gleba's perishables.)
      if not a.fluid and not a.premix_of and not a.agent and a.family ~= "biological" then
        table.insert(adds, {name = a.name, w = scrap_additive_weight(a.name)})
      end
    end
    if #adds == 0 then return nil end
    local doses = {}
    for d, w in ipairs(SC.dose_weight) do table.insert(doses, {d = d, w = w}) end
    cell, cap = {target = t.key, additive = pick(adds, e, rng).name, dose = pick(doses, e, rng).d}, SC.cap
  end
  local ck = cell.target .. "|" .. (cell.additive or "control") .. "|" .. cell.dose
  if (counts[ck] or 0) >= cap then return nil end
  counts[ck] = (counts[ck] or 0) + 1
  return cell
end
-- The best pack a station holds for a scrap sample (the highest tier), and its tier.
local function best_scrap_pack(inv)
  local best, tier
  for name, k in pairs(shared.scrap.pack_tier) do
    -- (Any quality: a bare name counts normal ones only.)
    if prototypes.item[name] and inv.get_item_count_filtered{name = name} > 0 and (not tier or k > tier) then
      best, tier = name, k
    end
  end
  return best, tier
end
-- Analyse one scrap sample at a station: a pack's share (the best held), a drawn cell, measured like a
-- bench trial on the station's surface, into its planet's pool without research data; a dud otherwise.
local function analyse_scrap(unit, station, s, inv)
  local e = station.entity
  station.pack_credit = station.pack_credit or {}
  -- An opened pack's remaining credit first (the best tier among them), else a new pack, the best held.
  local pack, tier
  for name, k in pairs(shared.scrap.pack_tier) do
    if (station.pack_credit[name] or 0) > 0 and (not tier or k > tier) then pack, tier = name, k end
  end
  if pack then
    station.pack_credit[pack] = station.pack_credit[pack] - 1
  else
    pack, tier = best_scrap_pack(inv)
    local q = pack and take_pack(inv, pack)
    if not q then return false end
    station.pack_credit[pack] = pack_samples(e.force, q) - 1
  end
  station.packs_seen[pack] = true
  local skey = surface_key(e.surface)
  local pool = pool_of(e.force, skey)
  storage.scrap_rng = storage.scrap_rng
    or game.create_random_generator(scrambled_seed(game.surfaces[1].map_gen_settings.seed + 149))
  local cell = draw_scrap(e.force, pool, tier, storage.scrap_rng)
  s.count = s.count - 1  -- one of the stack (scrap samples stack, unlike bench samples)
  storage.dirty_stations[unit] = true
  if not cell then
    station.unreadable = station.unreadable + 1
    pool.unreadable = pool.unreadable + 1
    mark_pool(e.force)
    return true
  end
  if not pool.obs[cell.target] then pool.obs[cell.target] = {control = {n = 0, sum = 0, sumsq = 0}} end
  storage.scrap_rngs = storage.scrap_rngs or {
    yield = game.create_random_generator(scrambled_seed(game.surfaces[1].map_gen_settings.seed + 151)),
    side = game.create_random_generator(scrambled_seed(game.surfaces[1].map_gen_settings.seed + 157))}
  local mix = cell.additive and {[cell.additive] = cell.dose} or nil
  local y, sp, pp, ef = measure_trial(e.force, cell.target, mix, nil, e.surface, storage.scrap_rngs,
    game.surfaces[1].map_gen_settings.seed + 151, nil)
  ingest(e.force, pool, {target = cell.target, mix = mix or {}, additive = cell.additive or "", dose = cell.dose,
    y = y, sp = sp, pp = pp, ef = ef, pack = pack, v = 3, surface = skey, scrap = true}, skey, station, true)
  station.analysed = station.analysed + 1
  station.scrap_analysed = (station.scrap_analysed or 0) + 1
  achieve(e.force, "es-cold-case")
  e.custom_status = nil
  return true
end

-- Analyse one sample if there is one and the pack it needs.
local function analyse(unit, station)
  local e = station.entity
  local inv = e.get_inventory(defines.inventory.chest)
  local waiting_for
  for i = 1, #inv do
    local s = inv[i]
    if s.valid_for_read and s.name == shared.scrap.item then
      if analyse_scrap(unit, station, s, inv) then return end
      waiting_for = waiting_for or shared.pack
    end
    if s.valid_for_read and shared.is_sample(s.name) then
      local tags = s.item and s.item.tags
      -- The evidence of the surface the trial ran on (samples travel; conditions do not).
      local skey = tags and tags.surface or "nauvis"
      local pool = pool_of(e.force, skey)
      -- Route sub-targets ("gear@cast") get their data table on first use.
      if tags and tags.target and not pool.obs[tags.target] and shared.target(tags.target) then
        pool.obs[tags.target] = {control = {n = 0, sum = 0, sumsq = 0}}
      end
      -- (0.72) A route trial's sample, from before alternative recipes were retired: nothing to file it under.
      if tags and tags.route and tags.route ~= "" then tags = nil end
      if not (tags and tags.target and pool.obs[tags.target]) then
        s.clear()
        station.unreadable = station.unreadable + 1
        pool.unreadable = pool.unreadable + 1
        storage.dirty_stations[unit] = true
        mark_pool(e.force)
        return
      end
      -- A failed run (stale inputs): counted, discarded, no pack spent on it.
      if tags.failed then
        s.clear()
        station.failed = (station.failed or 0) + 1
        storage.dirty_stations[unit] = true
        return
      end
      local pack = tags.pack or shared.pack
      station.packs_seen[pack] = true
      -- One pack pays for samples_per_pack samples: spend credit first, then open a new pack.
      station.pack_credit = station.pack_credit or {}
      local credit = station.pack_credit[pack] or 0
      local q = credit <= 0 and take_pack(inv, pack)
      if credit > 0 or q then
        if credit > 0 then
          station.pack_credit[pack] = credit - 1
        else
          station.pack_credit[pack] = pack_samples(e.force, q) - 1
        end
        ingest(e.force, pool, tags, skey, station)
        s.clear()
        station.analysed = station.analysed + 1
        storage.dirty_stations[unit] = true
        e.custom_status = nil
        return
      end
      waiting_for = waiting_for or pack  -- try other samples that may need a pack we have
    end
  end
  e.custom_status = waiting_for and {diode = defines.entity_status_diode.yellow,
    label = {"es.waiting-packs", "[item=" .. waiting_for .. "]"}} or nil
end

-- Alerts (onboarding): a station waiting for packs, or with every sample slot full, says so on the map,
-- the way Factorio says why a machine does nothing. Raised when the condition starts, removed when it ends.
local function update_alert(unit, station)
  local e = station.entity
  local kind, icon, message
  local status = e.custom_status
  if status and status.label and status.label[1] == "es.waiting-packs" then
    local pack = tostring(status.label[2]):match("item=([^%]]+)") or shared.pack
    kind, icon, message = "packs", {type = "item", name = pack}, {"es.alert-packs", status.label[2]}
  else
    -- Full: no waiting slot free (0.72: they follow the packs held, so any kind; the first one's for the icon).
    local inv = e.get_inventory(defines.inventory.chest)
    local free = false
    for i = 1, shared.station_sample_slots do if not inv[i].valid_for_read then free = true end end
    if not free then
      local f = inv.get_filter(1)
      kind, icon, message = "full", {type = "item", name = f and f.name or shared.sample_of(shared.pack)}, {"es.alert-full"}
    end
  end
  storage.station_alerts = storage.station_alerts or {}
  -- A pack alert holds ten seconds after packs arrive (0.68: a belt bringing them one by one flickered it).
  storage.station_alert_seen = storage.station_alert_seen or {}
  if kind then storage.station_alert_seen[unit] = game.tick
  elseif storage.station_alerts[unit] and game.tick - (storage.station_alert_seen[unit] or 0) < 600 then return end
  if storage.station_alerts[unit] == kind then return end
  for _, player in pairs(e.force.players) do
    if storage.station_alerts[unit] then player.remove_alert{entity = e, type = defines.alert_type.custom} end
    if kind then player.add_custom_alert(e, icon, message, true) end
  end
  storage.station_alerts[unit] = kind
end

local function signal(type, name, value)
  return {value = {type = type, name = name, quality = "normal"}, min = value}
end

-- Circuit outputs for the port's selected target, from the force's pool, gains in per mille: N samples
-- analysed (by the whole force); each
-- additive's best-dose gain on its own item signal; D, Y, W: dose, gain and 95% CI half-width of the
-- best additive-dose overall; S, C: that same composition's speed and cleanliness changes (7d; the
-- Screening grid's trade-off, positive = faster, cleaner).
-- A port page's target echo: the signal of the recipe the target is made by (its vanilla recipe, or the
-- route's own), never an item (item signals carry additives' values on the same port).
local function port_echo(target_key)
  local t = shared.target(target_key)
  local name = (prototypes.recipe[shared.target_recipe(t)] and shared.target_recipe(t)) or shared.trial_recipe(t.key)
  return signal("recipe", name, 1)
end

local function write_outputs(station, cache)
  if not station.port.valid then return end
  -- The target and page the station's circuit input selects (0.49), else the window's choice.
  local input = station.input or {}
  local tk = input.target or station.view_target
  local skey = surface_key(station.entity.surface)
  local pool = pool_of(station.entity.force, skey)
  -- The port reads the force's pool (its own planet's) (summaries computed once per force, target and effect however many
  -- ports read them) or this station's own history.
  local own = station.port_source == "station"
  local function sums_of(effect)
    if own then return gui.summaries(station.history, tk, effect) end
    local k = station.entity.force.index .. "|" .. skey .. "|" .. tk .. "|" .. (effect or "yield")
    cache[k] = cache[k] or gui.summaries(pool, tk, effect)
    return cache[k]
  end
  local sums = sums_of()
  -- (0.72) Every value on a signal whose icon
  -- says what it is, no letters. An additive signal on the station's input selects that additive on every page:
  -- the page then adds its dose (es-dose), so a rig needs one page, not two in turn.
  local force = station.entity.force
  local function researched(name) return force.technologies[name] and force.technologies[name].researched end
  local page = input.page or 0
  if ((page == 1 or page == 2) and not researched("es-circuit-instrumentation-2"))
     or (page == 3 and not researched("es-circuit-instrumentation-3")) or page > 3 or page < 0 then
    page = 0
  end
  local book = own and station.history or pool
  local obs = book.obs[tk] or {}
  local sel = input.additive and sums.additives[input.additive] and input.additive or nil
  local function per_mille(x) return math.floor(x + 0.5) end
  local out = {}
  local function put(ty, name, v) if v and v ~= 0 then table.insert(out, signal(ty, name, v)) end end
  if page > 0 then out = {signal("virtual", "es-page", page), port_echo(tk)} end
  if page == 0 then
    -- Results: each additive's gain lower bound at its best dose; samples on the target; the best upgrade rate.
    for _, a in ipairs(shared.all_additives) do
      local row = sums.additives[a.name]
      if row and row.best then put(shared.signal_type(a.name), a.name, per_mille(row.doses[row.best].lo)) end
    end
    local n = 0
    for _, acc in pairs(obs) do n = n + (acc.n or 0) end
    put("virtual", "es-n", n)
    local qual = book.quality and book.quality[tk]
    local best_q
    for _, q in pairs(qual or {}) do
      if q.b >= shared.quality_min_units and (not best_q or q.k / q.b > best_q) then best_q = q.k / q.b end
    end
    put("virtual", "es-quality", best_q and math.floor(best_q * 1000 + 0.5))
    if sel then put("virtual", "es-dose", sums.additives[sel].best) end
  elseif page == 1 then
    -- Screening: each additive's packs per next sample (per mille); for the selected one, its most open tested
    -- dose and that cell's samples (an untested additive sends none: a rig starts it at a dose of its own).
    local qual = book.quality and book.quality[tk]
    for _, a in ipairs(shared.all_additives) do
      local row = research.row(force.index, obs, tk, a.name, skey, qual)
      put(shared.signal_type(a.name), a.name, row and math.floor(row.rate * 1000 + 0.5))
    end
    if sel then
      local d = research.most_open_dose(obs, tk, sel)
      if d then
        put("virtual", "es-dose", d)
        put("virtual", "es-n", obs[sel .. ":" .. d] and obs[sel .. ":" .. d].n)
      end
    end
  elseif page == 2 then
    -- Selected result: the cell an additive and es-dose name (es-dose 0 or none: the control), with its side
    -- effects (per mille: faster, cleaner and more efficient are positive, as on Screening).
    local s, d
    if sel then d = input.dose or 0 end
    if sel and d > 0 then s = sums.additives[sel].doses[d] else s = sums.control end
    if s and s.n > 0 then
      put("virtual", "es-n", s.n)
      put("virtual", "es-mean", per_mille(s.mean))
      if s.half then put("virtual", "es-half", per_mille(s.half)) end
      if s.lo then put("virtual", "es-lo", per_mille(s.lo)) end
      for effect, name in pairs({speed = "es-speed", pollution = "es-cleanliness", efficiency = "es-efficiency"}) do
        local se = sums_of(effect)
        local side = (sel and d > 0) and se.additives[sel] and se.additives[sel].doses[d] or (not (sel and d > 0) and se.control)
        if side and side.n > 0 then put("virtual", name, per_mille(side.mean)) end
      end
    end
  elseif page == 3 then
    -- Best composition: the best tested composition by lower bound of net gain, as doses (a machine in circuit
    -- mode wired to the port uses it; the only page a machine takes directly).
    local best = research.best_composition(obs, tk)
    if best then
      for name, dose in pairs(best.mix) do table.insert(out, signal(shared.signal_type(name), name, dose)) end
      put("virtual", "es-lo", per_mille(best.net - research.Z * best.se))
      put("virtual", "es-n", best.n)
    end
  end
  station.served = {target = tk, page = page, selected = sel}
  local cb = station.port.get_or_create_control_behavior()
  local section = cb.get_section(1) or cb.add_section()
  section.filters = out
end

-- The station's circuit input (0.49), read with the analysis tick when wired: the target (a recipe
-- signal of its vanilla, route or trial recipe; the highest wins), es-page, and for page 4 an additive's
-- signal and es-dose. Item signals are always additives: plastic bars, tungsten carbide and lithium
-- plates are both additives and targets' products, so an item cannot name a target.
local target_of_signal
local function build_target_signals()
  target_of_signal = {recipe = {}}
  for _, t in ipairs(shared.targets) do
    if prototypes.recipe[shared.target_recipe(t)] then target_of_signal.recipe[shared.target_recipe(t)] = t.key end
    target_of_signal.recipe[shared.trial_recipe(t.key)] = t.key
  end
end
local function read_input(station)
  if not shared.stage_ok(station.entity.force, shared.circuit_tech) then station.input = nil; return false end
  local e, ids = station.entity, {}
  for _, id in ipairs({defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green}) do
    if e.get_circuit_network(id) then table.insert(ids, id) end
  end
  -- The optional second connector must be omitted, not passed as nil (as in dosing.lua).
  local signals = #ids == 2 and e.get_signals(ids[1], ids[2]) or #ids == 1 and e.get_signals(ids[1]) or nil
  if not target_of_signal then build_target_signals() end
  local input = {}
  local tv, av = 0, 0
  for _, sg in ipairs(signals or {}) do
    local id, v = sg.signal, sg.count
    local ty = id.type or "item"
    if id.quality and id.quality ~= "normal" then goto next_signal end
    if ty == "virtual" and id.name == "es-page" then input.page = v
    elseif ty == "virtual" and id.name == "es-dose" then input.dose = v
    elseif v > 0 then
      local t = ty == "recipe" and target_of_signal.recipe[id.name]
      if t and v > tv then input.target, tv = t, v end
      local a = shared.additive(id.name)
      if a and not t and v > av then input.additive, av = id.name, v end
    end
    ::next_signal::
  end
  local old = station.input or {}
  station.input = next(input) and input or nil
  local new = station.input or {}
  return old.target ~= new.target or old.page ~= new.page or old.additive ~= new.additive or old.dose ~= new.dose
end

-- Clear one target's evidence from a force's pool (yield and side effects); other targets keep theirs.
local function clear_target(force, target_key, skey)
  local pool = pool_of(force, skey)
  pool.obs[target_key] = {control = {n = 0, sum = 0, sumsq = 0}}
  for _, by_target in pairs(pool.side) do by_target[target_key] = nil end
  if pool.quality then pool.quality[target_key] = nil end
  storage.evidence_version = (storage.evidence_version or 0) + 1
  pool.changed = pool.changed or {}
  pool.changed[target_key] = storage.evidence_version
  mark_pool(force)
end


---------------------------------------------------------------------------
-- Events
---------------------------------------------------------------------------

-- The report (0.69): shown in the Findings tab once a force has finished.
-- The truth appears only as counts (what is still out there, never what or where) and as the true value of
-- what the force already proved; plus tested-and-dropped cells worth another look (no dose, no number).
local report_holds = {}       -- target -> true when some single additive's true best clears a finding bar
local report_major_possible   -- readout -> true when some dose anywhere clears its major bar
local function report_world()
  if report_major_possible then return end
  local th = dossiers.thresholds()
  local d = answer_key.compute()
  report_major_possible = {}
  for _, t in ipairs(d.targets) do
    for _, row in ipairs(t.rows) do
      for _, r in ipairs(dossiers.STANDARD) do
        local std = dossiers.standard_for(th, t.key)
        if row.best[r] and std[r] and row.best[r].v >= std[r] then report_holds[t.key] = true end
      end
      for _, r in ipairs(dossiers.EXCEPTIONAL) do
        if row.best[r] and row.best[r].v >= th.exceptional[r] then report_major_possible[r] = true end
      end
    end
  end
end
-- The true effect of a tested cell, under its planet's conditions and at its band.
local function cond_of(force, skey)
  if cond_cache[skey] ~= nil then return cond_cache[skey] or nil end
  local s = game.surfaces[skey]
  if not s and skey == "space-platform" then
    for _, p in pairs(force.platforms) do if p.surface then s = p.surface; break end end
  end
  return s and surface_cond(s) or nil
end
local function true_effect(force, target_key, key, readout, skey)
  local mix, temps = {}, {}
  for part in key:gmatch("[^+]+") do
    local name, dose = part:match("^(.+):(%d+)$")
    if not name then return nil end
    local base, b = shared.split_band(name)
    mix[base] = tonumber(dose)
    if b and name:find("@") then local lo, hi = shared.band_range(b); temps[base] = (lo + hi) / 2 end
    if b and name:find("~") then local lo, hi = shared.ripe_range(b); temps[base] = (lo + hi) / 200 end
  end
  local t = storage.truth
  if readout == "yield" then return truth.gain_on(t, target_key, mix, cond_of(force, skey), next(temps) and temps or nil) end
  if readout == "quality" then return truth.quality_chance(t, target_key, mix) end
  return truth.effect_on(t, target_key, mix, readout == "cleanliness" and "pollution" or readout)
end
local report_cache = {}
function dossiers.report_fn(force)
  report_world()
  local th = dossiers.thresholds()
  local r = dossiers.state(force)
  local out = {planets = {}, truth = {}, look = {}}
  for planet, p in pairs(r.planets) do
    if p.reached then
      local more = 0
      for _, b in ipairs(p.targets) do
        if b.state ~= "done" and report_holds[b.target.key] then more = more + 1 end
      end
      table.insert(out.planets, {planet = planet, done = p.done, more = more})
    end
  end
  local possible = 0
  for readout, b in pairs(r.exceptional) do
    if b.state ~= "done" and report_major_possible[readout] then possible = possible + 1 end
  end
  out.majors = {done = r.exc_done, needed = r.exc_needed, more = possible}
  local function truth_row(b, label)
    local e = b.entry
    local v = true_effect(force, e.target, e.key, e.readout, e.skey)
    if v then table.insert(out.truth, {target = e.target, readout = e.readout, key = e.key, lb = e.lb, v = v, label = label}) end
  end
  for _, p in pairs(r.planets) do for _, b in ipairs(p.targets) do if b.state == "done" then truth_row(b) end end end
  for _, b in pairs(r.exceptional) do if b.state == "done" then truth_row(b, true) end end
  -- Tested and dropped, worth another look: cached on the evidence (cells and truth do not change between
  -- samples).
  local seen = dossiers.analysed(force)
  local cached = report_cache[force.index]
  if cached and cached.seen == seen then out.look = cached.look; return out end
  local done_t = {}
  for _, p in pairs(r.planets) do for _, b in ipairs(p.targets) do if b.state == "done" then done_t[b.target.key] = true end end end
  local margin = shared.dossier.look_margin
  local look = {}
  for _, target in ipairs(shared.targets) do
    for _, c in ipairs(dossiers.cells(force, target.key)) do
      local std = not done_t[target.key] and dossiers.standard_for(th, target.key)[c.readout]
      local exc = th.exceptional[c.readout]
      for _, bar in ipairs({std or false, exc or false}) do
        if bar and c.lb < bar then
          local v = true_effect(force, target.key, c.key, c.readout, c.skey)
          if v and v >= bar * (1 + margin) then
            table.insert(look, {target = target.key, key = c.key, n = c.n, readout = c.readout, room = v - bar})
            break
          end
        end
      end
    end
  end
  table.sort(look, function(a, b) return a.room > b.room end)
  local top, seen_cell = {}, {}
  for _, l in ipairs(look) do
    local id = l.target .. "|" .. l.key
    if #top < 5 and not seen_cell[id] then seen_cell[id] = true; table.insert(top, l) end
  end
  report_cache[force.index] = {seen = seen, look = top}
  out.look = top
  return out
end

-- The ending: the first time a force completes its dossiers, its players
-- get the achievement, a message and the summary. The game goes on.
local function dossiers_finished(force, result)
  if strength_of_map() == "harsh" then achieve(force, "es-reviewer-2") end
  local theory = force.technologies["es-theory"]
  if not (theory and theory.researched) then achieve(force, "es-brute-force") end
  for _, row in ipairs(dossiers.report_fn(force).truth) do
    if row.v < row.lb then achieve(force, "es-replication-crisis") end
  end
  for _, player in pairs(force.players) do
    player.unlock_achievement(dossiers.ACHIEVEMENT)
    player.print({"es.dossiers-finished"})
    gui.open_dossier_summary(player, result)
  end
end

-- Fluid chillers (0.71, shared.chiller): what leaves one is set to the chilled cold, every 10 ticks. A
-- boiler passes fluid only while it warms it, and only while it burns cold charges, so the charge pays for it.
-- (A vanilla fluid cannot go below its minimum: it keeps its own, warmed one degree; its cold is its twin.)
-- A boiler's own box hands its fluid to the pipes beyond; the pipes share one temperature (a segment), set by
-- writing any one of them: the entity at its output connection is written too.
-- (Written with the segment's total: writing one pipe's share sets the whole segment to that amount, which
-- deleted the rest every 10 ticks and burned the charges refilling it; seen in the playtest kit.)
local function chill(box, i, cold)
  local f = box[i]
  if f and f.amount > 0 and f.temperature > cold then
    local total = box.get_fluid_segment_contents(i)
    box[i] = {name = f.name, amount = total and total[f.name] or f.amount, temperature = cold}
  end
end
local function chill_tick()
  local cold = shared.chilled.temperature
  for unit, e in pairs(storage.chillers) do
    if e.valid then
      chill(e.fluidbox, 2, cold)
      for _, cn in ipairs(e.fluidbox.get_pipe_connections(2)) do
        -- (Not the chiller itself, whose edge the point may touch: chilling its input would make it heat that
        -- from the cold again, burning a hundred times the charge's due. Seen in the playtest kit.)
        for _, n in pairs(e.surface.find_entities_filtered{position = cn.target_position}) do
          if n.unit_number ~= e.unit_number and n.fluidbox and #n.fluidbox > 0 then
            for i = 1, #n.fluidbox do
              local f = n.fluidbox[i]
              if f and e.fluidbox[2] and f.name == e.fluidbox[2].name then chill(n.fluidbox, i, cold) end
            end
          end
        end
      end
    else
      storage.chillers[unit] = nil
    end
  end
end

local function on_tick(event)
  -- Benches whose craft is due: samples must be tagged before an inserter can carry them off.
  local due = storage.bench_wheel[event.tick]
  if due then
    storage.bench_wheel[event.tick] = nil
    for unit in pairs(due) do
      local bench = storage.benches[unit]
      if bench and bench.entity.valid then
        process_bench(bench)
        schedule_bench(unit, bench, event.tick)
      elseif bench then
        storage.benches[unit] = nil
      end
    end
  end
  local fresh_due = storage.fresh_wheel and storage.fresh_wheel[event.tick]
  if fresh_due then
    storage.fresh_wheel[event.tick] = nil
    for unit in pairs(fresh_due) do
      local c = storage.crafters[unit]
      if c and c.entity.valid then process_fresh(unit, c, event.tick) end
    end
  end
  if not storage.crafter_buckets then  -- a save that never ran the migration: build them now
    storage.crafter_buckets = {}
    for unit in pairs(storage.crafters) do
      local b = unit % CRAFTER_TICKS
      storage.crafter_buckets[b] = storage.crafter_buckets[b] or {}
      storage.crafter_buckets[b][unit] = true
    end
  end
  -- Crafting machines: once a second each, spread over the second's ticks.
  local bucket = storage.crafter_buckets[event.tick % CRAFTER_TICKS]
  if bucket then
    for unit in pairs(bucket) do
      local crafter = storage.crafters[unit]
      if crafter and crafter.entity.valid then process_crafter(crafter)
      else storage.crafters[unit] = nil; bucket[unit] = nil end
    end
  end
  dosing.redraw_dirty()
  hopper_report.update(event.tick)
  if event.tick % 10 == 0 and next(storage.chillers) then chill_tick() end
  -- (storage.analysis_ticks: set only by the mechanics test, whose lab was built for stations ten times as
  -- quick; the kit and the playthrough run at the real pace.)
  if event.tick % (storage.analysis_ticks or shared.analysis_ticks) == 0 then
    for unit, station in pairs(storage.stations) do
      if station.entity.valid then
        local before = station.analysed
        -- (0.72) Quality speeds a station as it speeds a lab (the quality's lab research speed): a period
        -- analyses that many samples, the fraction carried to the next.
        reserve_sample_slots(station.entity)  -- (its waiting slots follow the packs it holds)
        local q = station.entity.quality
        station.progress = (station.progress or 0) + (q and q.lab_research_speed_multiplier or 1)
        while station.progress >= 1 do
          station.progress = station.progress - 1
          analyse(unit, station)
        end
        update_alert(unit, station)
        -- Its working animation while it analyses (0.72), gone after two periods with nothing to read (one
        -- would flicker it on a station fed a little slower than it reads).
        local working = station.analysed ~= before
        station.idle = working and 0 or (station.idle or 0) + 1
        if working and not (station.anim and station.anim.valid) then
          station.anim = rendering.draw_animation{animation = "es-station-working", target = station.entity,
            surface = station.entity.surface, render_layer = "object", animation_speed = 1 / 3}
          -- (The port, an entity in the same layer, would sit under the animation: its sprite over it.)
          if station.port.valid then
            station.port_front = rendering.draw_sprite{sprite = "es-station-port-front", target = station.port,
              surface = station.entity.surface, render_layer = "higher-object-under"}
          end
        elseif station.idle >= 2 and station.anim then
          if station.anim.valid then station.anim.destroy() end
          station.anim = nil
          if station.port_front and station.port_front.valid then station.port_front.destroy() end
          station.port_front = nil
        end
        -- A new selection, or a page asked for but not served yet (its technology may have arrived).
        local changed = read_input(station)
        local want = station.input and station.input.page
        if changed or (want and station.served and station.served.page ~= want) then write_outputs(station, {}) end
      end
    end
  end
  -- A pool that changed rewrites every port of its force; a station whose own counts changed, its window.
  local cache = {}
  for force_index in pairs(storage.dirty_pools) do
    for unit, station in pairs(storage.stations) do
      if station.entity.valid and station.entity.force.index == force_index then
        write_outputs(station, cache)
        storage.dirty_stations[unit] = true
      end
    end
    storage.gui_dirty_forces[force_index] = true
  end
  storage.dirty_pools = {}
  for unit in pairs(storage.dirty_stations) do storage.gui_dirty[unit] = true end
  storage.dirty_stations = {}
  -- The Progress tab's record: every force with players (0.72, user: a save with only a dosed line showed
  -- nothing), every shared.progress_ticks, and a first snapshot as soon as a force has none, so the tab has a
  -- starting point to draw from.
  if event.tick % shared.progress_ticks == 0 then
    for _, force in pairs(game.forces) do
      if #force.players > 0 or (storage.samples_count and storage.samples_count[force.index]) then record_progress(force) end
    end
  end
  if event.tick % DOSSIER_TICKS == 0 then
    for _, force in pairs(game.forces) do
      if #force.players > 0 and not (storage.progress and storage.progress[force.index]) then record_progress(force) end
    end
    dossiers.update(dossiers_finished)
    -- Waste not (0.72): an activated catalyst made by the force, anywhere.
    for _, force in pairs(game.forces) do
      if #force.players > 0 and not (storage.achieved and storage.achieved[force.index] and storage.achieved[force.index]["es-waste-not"]) then
        for _, a in ipairs(shared.additives) do
          if a.tier == 3 and prototypes.item[a.name] then
            for _, surface in pairs(game.surfaces) do
              if force.get_item_production_statistics(surface).get_input_count(a.name) > 0 then achieve(force, "es-waste-not") end
            end
          end
        end
      end
    end
  end
  if event.tick % GUI_REFRESH_TICKS == 0 then
    for unit in pairs(storage.gui_dirty) do gui.refresh_station(unit) end
    for force_index in pairs(storage.gui_dirty_forces) do gui.refresh_force(force_index) end
    storage.gui_dirty = {}
    storage.gui_dirty_forces = {}
    dose_gui.refresh_all(producing)
  end
end

local build_filter = {{filter = "name", name = BENCH}, {filter = "name", name = STATION},
  {filter = "name", name = dosing.HOPPER}, {filter = "name", name = dosing.FLUID_HOPPER},
  {filter = "type", type = "assembling-machine"},
  {filter = "type", type = "furnace"}}
-- (The chiller exists with Space Age only: an event filter on a missing name is an error.)
if prototypes.entity[shared.chiller.name] then table.insert(build_filter, {filter = "name", name = shared.chiller.name}) end


-- World strength: truth.lua reads the map's own on every lookup (the dose window).
script.on_load(function() truth.set_strength(storage.truth and storage.truth.strength) end)
script.on_init(function()
  init_storage()
  storage.staging = true  -- a new game: the tools open by research
end)
-- Achievements a force earned before a player joined it (0.72).
script.on_event(defines.events.on_player_joined_game, function(event)
  local player = game.get_player(event.player_index)
  for name in pairs(storage.achieved and storage.achieved[player.force.index] or {}) do player.unlock_achievement(name) end
end)

script.on_configuration_changed(function()
  init_storage()
  -- Saves from before staging (0.32): every staged tool stays open for the forces that exist (nothing
  -- they used disappears; Precision instruments is not given away), the stage technologies researched.
  if not storage.staging then
    storage.legacy_stages = {}
    for _, force in pairs(game.forces) do
      storage.legacy_stages[force.index] = true
      for _, st in pairs(shared.stages) do
        if force.technologies[st.tech] then force.technologies[st.tech].researched = true end
      end
    end
    storage.staging = true
  end
  -- 0.14 replaced adoption recipes (direct recipes, formulas) by dosing: say so once to saves that had
  -- adopted compositions. Their machines lost those recipes when the prototypes went.
  local had = false
  for _, targets in pairs(storage.adopted or {}) do if next(targets) then had = true end end
  if had and not storage.dosing_announced then game.print({"es.migrated-dosing"}) end
  storage.dosing_announced = true
  storage.adopted = {}
  -- (0.72) Alternative recipes are retired: their adoptions go (machines running one lost the recipe with it), and
  -- so does their evidence: route results ("route:cast") and route sub-targets ("gear@cast"), in every pool and
  -- every station's own history. A station shown a sub-target shows its product instead.
  storage.routes_adopted = nil
  prune_routes()
  -- Trials unlock with their target's technology; enable them where it was researched before.
  for _, force in pairs(game.forces) do
    for name, tech in pairs(force.technologies) do
      if tech.researched then
        for _, effect in pairs(tech.prototype.effects or {}) do
          if effect.type == "unlock-recipe" and effect.recipe:find("^es%-") and force.recipes[effect.recipe] then
            force.recipes[effect.recipe].enabled = true
          end
        end
      end
    end
  end
end)
script.on_event(defines.events.on_tick, on_tick)
script.on_event(defines.events.on_built_entity, on_built, build_filter)
script.on_event(defines.events.on_robot_built_entity, on_built, build_filter)
script.on_event(defines.events.on_space_platform_built_entity, on_built, build_filter)
script.on_event(defines.events.script_raised_built, on_built, build_filter)
script.on_event(defines.events.script_raised_revive, on_built, build_filter)
script.on_event(defines.events.on_object_destroyed, on_destroyed)
-- A crafting machine about to go: the hoppers next to it redraw their chutes once it is gone.
local removal_filter = {{filter = "type", type = "assembling-machine"}, {filter = "type", type = "furnace"}}
local function on_machine_removed(event) dosing.mark_neighbours(event.entity) end
script.on_event(defines.events.on_player_mined_entity, on_machine_removed, removal_filter)
script.on_event(defines.events.on_robot_mined_entity, on_machine_removed, removal_filter)
script.on_event(defines.events.on_entity_died, on_machine_removed, removal_filter)
script.on_event(defines.events.script_raised_destroy, on_machine_removed, removal_filter)

script.on_event(defines.events.on_gui_opened, function(event)
  local e = event.entity
  if not (e and e.valid) then return end
  local player = game.get_player(event.player_index)
  if e.name == PORT then
    -- The port is part of the station: open the station instead.
    for _, station in pairs(storage.stations) do
      if station.port == e then player.opened = station.entity; return end
    end
  elseif e.name == STATION then
    gui.open_station(player, e.unit_number)
  elseif e.name == hopper_report.NAME then
    local hopper = hopper_report.hopper_of(e)
    if hopper then player.opened = hopper end
  elseif dosing.IS_HOPPER[e.name] then
    hopper_report.open_gui(player, e)
  elseif dosing.is_machine(e) then
    dose_gui.open(player, e, gui.pickable_additives(player.force))
    dose_gui.refresh_player(player, producing)
  end
end)

script.on_event(defines.events.on_gui_closed, function(event)
  local e = event.entity
  local el = event.element
  if el and el.valid and el.name == "es_science" then gui.close(game.get_player(event.player_index)) end
  if el and el.valid and el.name == "es_dossier_summary" then el.destroy() end
  if e and e.valid and e.name == STATION then gui.close_station(game.get_player(event.player_index)) end
  if e and e.valid and dosing.is_machine(e) then dose_gui.close(game.get_player(event.player_index)) end
  if e and e.valid and dosing.IS_HOPPER[e.name] then hopper_report.close_gui(game.get_player(event.player_index)) end
end)

script.on_event(defines.events.on_gui_text_changed, function(event)
  local el = event.element
  if el.valid and el.tags and el.tags.es_action == "dose-amount" then
    dose_gui.on_amount(game.get_player(event.player_index), el.tags.row)
  elseif el.valid and el.tags and el.tags.es_action == "notebook" then
    -- The force's notebook (0.72): one page, shared by the force, kept with the map.
    storage.notebook = storage.notebook or {}
    storage.notebook[game.get_player(event.player_index).force.index] = el.text
  end
end)

-- The science screen's tabs: the Target row shows only where the target matters (0.70).
script.on_event(defines.events.on_gui_selected_tab_changed, function(event)
  local player = game.get_player(event.player_index)
  local frame = player.gui.screen.es_science
  if frame and event.element == frame.panel.pages then gui.refresh_player(player) end  -- (Coverage fills on show)
end)

script.on_event(defines.events.on_gui_checked_state_changed, function(event)
  local el = event.element
  if el.valid and el.tags and el.tags.es_action == "hopper-report" then
    hopper_report.set(el.tags.unit, el.state)
  elseif el.valid and el.tags and el.tags.es_action == "progress-marks" then
    local player = game.get_player(event.player_index)
    storage.gui_progress = storage.gui_progress or {}
    local st = storage.gui_progress[player.index] or {graph = 1, range = #gui.PROGRESS_RANGES, marks = true}
    st.marks = el.state
    storage.gui_progress[player.index] = st
    gui.refresh_player(player)
  elseif el.valid and el.tags and el.tags.es_action == "all-targets" then
    -- The Target list: sampled targets only, or every open one (0.70).
    local player = game.get_player(event.player_index)
    storage.gui_all_targets = storage.gui_all_targets or {}
    storage.gui_all_targets[player.index] = el.state
    if storage.gui_targets then storage.gui_targets[player.index] = nil end
    gui.refresh_player(player)
  elseif el.valid and el.tags and el.tags.es_action == "dose-circuit" then
    dose_gui.on_circuit(game.get_player(event.player_index), el.state)
  elseif el.valid and el.tags and el.tags.es_action == "port-source" then
    -- A station's port: the force's pool, or this station's own history.
    local player = game.get_player(event.player_index)
    local unit = storage.station_open and storage.station_open[player.index]
    local station = unit and storage.stations[unit]
    if not station then return end
    station.port_source = el.state and "station" or "force"
    write_outputs(station, {})
    gui.refresh_station(unit)
  end
end)

-- Dose settings travel like vanilla settings: copy-paste and blueprints.
script.on_event(defines.events.on_entity_settings_pasted, function(event)
  dosing.on_settings_pasted(event)
end)
-- Blueprint tags: doses, station port wires, hopper reports. One function for the player's blueprint
-- tool and for the example blueprints the mod ships (0.67, remote `blueprint_of`).
-- The example book into the player's hand (shortcut es-lab-blueprints).
local BOOK_ORDER = {"dose_signal", "dose_sweep", "adopt_best"}
local function give_blueprints(player)
  if not (player and player.clear_cursor()) then return end
  local inv = game.create_inventory(1)
  inv.insert{name = "blueprint-book"}
  local book = inv[1]
  local pages = book.get_inventory(defines.inventory.item_main)
  local tmp = game.create_inventory(1)
  for _, key in ipairs(BOOK_ORDER) do
    tmp.clear()
    tmp.insert{name = "blueprint"}
    if blueprints[key] and tmp[1].import_stack(blueprints[key]) == 0 then pages.insert(tmp[1]) end
  end
  book.label = "Empirical Science examples"
  player.cursor_stack.set_stack(book)
  tmp.destroy()
  inv.destroy()
end

local function tag_blueprint(bp, mapping)
  for index, entity in pairs(mapping) do
    local settings = entity.valid and entity.unit_number and dosing.settings(entity.unit_number)
    if settings then bp.set_blueprint_entity_tag(index, "es_dose", settings) end
  end
  local in_bp = {}
  for _, e in pairs(mapping) do if e.valid and e.unit_number then in_bp[e.unit_number] = true end end
  -- A port counts as blueprinted with its station.
  for _, e in pairs(mapping) do
    local st = e.valid and e.unit_number and storage.stations[e.unit_number]
    if st and st.port.valid then in_bp[st.port.unit_number] = true end
  end
  for _, e in pairs(mapping) do
    local h = e.valid and e.unit_number and storage.hoppers[e.unit_number]
    if h and h.reporter and h.reporter.valid then in_bp[h.reporter.unit_number] = true end
  end
  local function inside(t) return t.unit_number and in_bp[t.unit_number] end
  for index, e in pairs(mapping) do
    local st = e.valid and e.unit_number and storage.stations[e.unit_number]
    local wires = st and port_wire_tags(st, inside)
    if wires then bp.set_blueprint_entity_tag(index, "es_port_wires", wires) end
    local h = e.valid and e.unit_number and storage.hoppers[e.unit_number]
    if h and h.reporter and h.reporter.valid then
      bp.set_blueprint_entity_tag(index, "es_report", true)
      local hw = wire_tags_of(h.reporter, h.entity, inside)
      if hw then bp.set_blueprint_entity_tag(index, "es_report_wires", hw) end
    end
  end
end

script.on_event(defines.events.on_player_setup_blueprint, function(event)
  local player = game.get_player(event.player_index)
  -- The blueprint being set up (review 0.68): a library record, else the event's stack, else the player's.
  -- (A record is no item stack: it has `type`, not valid_for_read or is_blueprint.)
  local rec = event.record
  if rec and rec.valid and rec.type == "blueprint" then tag_blueprint(rec, event.mapping.get()); return end
  local bp = event.stack
  if not (bp and bp.valid_for_read) then bp = player and player.blueprint_to_setup end
  if not (bp and bp.valid_for_read) then bp = player and player.cursor_stack end
  if not (bp and bp.valid_for_read and bp.is_blueprint) then return end
  tag_blueprint(bp, event.mapping.get())
end)

-- A drop-down choice in the station panel (also driven by the GUI smoke test).
local function apply_selection(player, action, index)
  if action == "dose-preset" then dose_gui.on_preset(player, index); return end
  if action == "progress-graph" or action == "progress-range" then
    storage.gui_progress = storage.gui_progress or {}
    local st = storage.gui_progress[player.index] or {graph = 1, range = #gui.PROGRESS_RANGES, marks = true}
    if action == "progress-graph" then st.graph = index else st.range = index end
    storage.gui_progress[player.index] = st
    gui.refresh_player(player)
    return
  end
  if action == "port-target" then
    -- A station's port: which of the pool's targets it outputs.
    local unit = storage.station_open and storage.station_open[player.index]
    local station = unit and storage.stations[unit]
    local keys = storage.station_targets and storage.station_targets[player.index]
    local key = keys and keys[index]
    if not (station and key) then return end
    station.view_target = key
    write_outputs(station, {})
    gui.refresh_station(unit)
    return
  end
  if action == "select" then
    if storage.gui_temp_band then storage.gui_temp_band[player.index] = nil end  -- another additive: its best band
    storage.gui_selected[player.index] = gui.visible_additives(player.force)[index].name
  elseif action == "model" then
    storage.gui_model[player.index] = index
  elseif action == "effect" then
    storage.gui_effect = storage.gui_effect or {}
    storage.gui_effect[player.index] = gui.views[index]
  elseif action == "theory-effect" then
    storage.gui_theory_effect = storage.gui_theory_effect or {}
    storage.gui_theory_effect[player.index] = gui.theory_effects[index]
  elseif action == "price-preset" then
    -- A preset replaces the prices; "custom" keeps the current ones (the sliders set it too).
    local preset = gui.price_presets[index]
    local P = gui.prices(player)
    if preset ~= "custom" and shared.prices[preset] then
      local fresh = shared.copy(shared.prices[preset])
      fresh.preset = preset
      storage.gui_prices[player.index] = fresh
    else
      P.preset = "custom"
    end
  elseif action == "mix-a" then
    storage.gui_mix_a[player.index] = gui.visible_additives(player.force)[index].name
  elseif action == "mix-b" then
    storage.gui_mix_b[player.index] = gui.visible_additives(player.force)[index].name
  elseif action == "mix-band-a" or action == "mix-band-b" then
    -- (0.72) A mixture member's temperature or ripeness band, kept per additive.
    local A, B = gui.selected_pair(player)
    local name = action == "mix-band-a" and A or B
    local bands = gui.band_kind(name) == "ripe" and shared.ripe_bands() or shared.all_bands()
    storage.gui_mix_band = storage.gui_mix_band or {}
    storage.gui_mix_band[player.index] = storage.gui_mix_band[player.index] or {}
    storage.gui_mix_band[player.index][name] = bands[index]
  elseif action == "screen-sort" or action == "screen-show" then
    storage.gui_screen = storage.gui_screen or {}
    local st = storage.gui_screen[player.index] or {sort = 1, show = 1}
    if action == "screen-sort" then st.sort = index else st.show = index end
    storage.gui_screen[player.index] = st
  elseif action == "temp-band" then
    storage.gui_temp_band = storage.gui_temp_band or {}
    local bands = storage.gui_band_kind and storage.gui_band_kind[player.index] == "ripe" and shared.ripe_bands()
      or shared.all_bands()
    storage.gui_temp_band[player.index] = index > #bands and "all" or bands[index]
  elseif action == "surface" then
    local known = storage.gui_surfaces and storage.gui_surfaces[player.index]
    local key = known and known.keys[index]
    if not key then return end
    storage.gui_view_surface = storage.gui_view_surface or {}
    storage.gui_view_surface[player.index] = key
  elseif action == "target" then
    local known = storage.gui_targets and storage.gui_targets[player.index]
    local key = known and known.keys[index]
    if not key then return end
    storage.gui_view_target = storage.gui_view_target or {}
    storage.gui_view_target[player.index] = key
    storage.gui_targets[player.index].signature = nil  -- (its counts refresh on a choice)
  else
    return
  end
  gui.refresh_player(player)
end

-- A price slider (the full cost view): the player's own prices from then on.
script.on_event(defines.events.on_gui_value_changed, function(event)
  local el = event.element
  if not (el.valid and el.tags and el.tags.es_action == "price") then return end
  local player = game.get_player(event.player_index)
  local P = gui.prices(player)
  P[el.tags.key] = el.slider_value
  P.preset = "custom"
  gui.refresh_player(player)
end)

script.on_event(defines.events.on_gui_selection_state_changed, function(event)
  local el = event.element
  local action = el.valid and el.tags and el.tags.es_action
  if not action then return end
  local player = game.get_player(event.player_index)
  if answer_key.on_selection(player, action, el.selected_index) then return end
  apply_selection(player, action, el.selected_index)
end)

-- The answer key (debug, spoilers): /es-answer-key.
commands.add_command("es-answer-key", {"es.ak-help"}, answer_key.command)

script.on_event(defines.events.on_gui_click, function(event)
  if event.element.valid and event.element.name == "es_dossier_summary_close" then
    local f = game.get_player(event.player_index).gui.screen.es_dossier_summary
    if f then f.destroy() end
    return
  end
  local el = event.element
  local action = el.valid and el.tags and el.tags.es_action
  if not action then return end
  local player = game.get_player(event.player_index)
  -- The dose panel (machines and benches).
  if action == "dose-slot" then dose_gui.on_slot(player, el.tags.row, event.button); return end
  if action == "dose-pick" then dose_gui.on_pick(player, el.tags.additive); return end
  if action == "open-science" then gui.open(player); return end
  if action == "ak-close" then answer_key.close(player); return end
  if action == "close-science" then gui.close(player); return end
  if not storage.open[player.index] then return end
  if action == "save-preset" then
    local options = storage.gui_adopt and storage.gui_adopt[player.index]
    local dose = options and options.values[el.parent.dose.selected_index]
    if not dose then return end
    local mix = {[el.tags.additive] = dose}
    local added = dosing.add_preset(player.force, el.tags.target, mix)
    player.force.print({added and "es.preset-saved" or "es.preset-exists", gui.mix_caption(mix),
      shared.target_caption(shared.target(el.tags.target))})
  elseif action == "save-preset-mix" then
    local options = storage.gui_mix_adopt[player.index]
    local mix = options and options.values[el.parent.choice.selected_index]
    if not mix then return end
    local added = dosing.add_preset(player.force, el.tags.target, mix)
    player.force.print({added and "es.preset-saved" or "es.preset-exists", gui.mix_caption(mix),
      shared.target_caption(shared.target(el.tags.target))})
  elseif action == "preset-delete" then
    dosing.remove_preset(player.force, el.tags.index)
  elseif action == "clear" then
    -- Per target, and only on a second click within a few seconds: the pool is the whole force's.
    storage.clear_armed = storage.clear_armed or {}
    local target = gui.view_target(player)
    local armed = storage.clear_armed[player.index]
    if armed and armed.target == target and game.tick - armed.tick <= CLEAR_CONFIRM_TICKS then
      clear_target(player.force, target, gui.view_surface(player))
      storage.clear_armed[player.index] = nil
      player.force.print({"es.cleared", player.name, shared.target_caption(shared.target(target))})
    else
      storage.clear_armed[player.index] = {target = target, tick = game.tick}
    end
  end
  gui.refresh_player(player)
end)

-- The screen from the shortcut bar and its hotkey.
script.on_event(defines.events.on_lua_shortcut, function(event)
  if event.prototype_name == "es-open-science" then gui.toggle(game.get_player(event.player_index)) end
  if event.prototype_name == "es-lab-blueprints" then give_blueprints(game.get_player(event.player_index)) end
end)
script.on_event("es-open-science", function(event) gui.toggle(game.get_player(event.player_index)) end)

-- A force's past experiments, run through the real trial and analysis code (0.51, the showcase save):
-- plan = {{target = key, mix = {name = dose}, n = samples, temps = {name = degrees}}...}; each sample is
-- measured as a bench would (truth plus noise, from this history's own generators) and analysed as a
-- station would (pool, research data, discoveries, premixes). Nothing about it reads the
-- truth except through the trial.
-- `quick` (0.72, the complete save): readings only, into the pool's cells, without the per-sample research
-- data, discovery and premix checks (each re-reads every result on the product: minutes for a full map).
local function simulate_history(force_name, surface_name, plan, seed, quick)
  local force, surface = game.forces[force_name], game.surfaces[surface_name]
  local skey = surface_key(surface)
  local pool = pool_of(force, skey)
  local base = seed or (surface.map_gen_settings.seed + 104729)
  local rngs = {yield = game.create_random_generator(scrambled_seed(base)),
                side = game.create_random_generator(scrambled_seed(base + 37))}
  local made = 0
  for _, step in ipairs(plan) do
    local target = shared.target(step.target)
    local mix = step.mix and next(step.mix) and step.mix or nil
    if not pool.obs[step.target] then pool.obs[step.target] = {control = {n = 0, sum = 0, sumsq = 0}} end
    for _ = 1, step.n do
      local y, sp, pp, ef, fr = measure_trial(force, step.target, mix, step.temps, surface, rngs, base, step.inherited)
      local qk, qb = roll_quality(step.target, mix, target.batch, rngs, base)
      local single, single_dose = next(mix or {})
      if single and next(mix, single) then single, single_dose = nil, nil end
      local tags = {target = step.target, mix = mix or {}, additive = single or "", dose = single_dose or 0,
        y = y, sp = sp, pp = pp, ef = ef, fr = fr, pack = storage.target_pack[step.target], v = 3, surface = skey,
        temps = step.temps, qk = qk, qb = qb}
      if quick then
        record(pool, tags, sample_key(tags), y)
        pool.analysed = pool.analysed + 1
      else
        ingest(force, pool, tags, skey, nil)
      end
      made = made + 1
    end
  end
  if quick then mark_pool(force) end
  return made
end

-- The core tips' scenes (0.72, user: the pages were dry and need scenes): small working builds placed by
-- script, fed from infinity chests and pipes (base game entities: a Tips window loads no other mod). Each
-- returns where the camera should look.
local N, E, S = defines.direction.north, defines.direction.east, defines.direction.south
local SCRIPTED = {}
local function scene_parts(s, force_name, origin)
  local ox, oy = origin and origin[1] or 0, origin and origin[2] or 0
  local function put(name, x, y, dir)
    local e = s.create_entity{name = name, position = {ox + x, oy + y}, force = force_name, direction = dir,
      raise_built = true}
    if not e then error("scene: could not place " .. name .. " at " .. x .. "," .. y) end
    return e
  end
  local function source(x, y, item, count)
    local c = put("infinity-chest", x, y)
    c.infinity_container_filters = {{name = item, count = count or 100, mode = "at-least", index = 1}}
    return c
  end
  local function hopper(x, y, item)
    local h = put("es-hopper", x, y)
    h.get_inventory(defines.inventory.chest).insert{name = item, count = 50}
    return h
  end
  return put, source, hopper, ox, oy
end
-- A test bench running a dosed gear trial: plates in from the top left, the hopper on top, products out below.
local function scene_bench(put, source, hopper, x, y, dose)
  local b = put("es-test-bench", x, y)
  b.set_recipe(shared.trial_recipe("gear"))
  source(x - 1, y - 3, "iron-plate"); put("inserter", x - 1, y - 2, N)
  if dose then hopper(x, y - 2, "coal"); dosing.set(b, {rows = {{name = "coal", dose = dose}}}) end
  return b
end
-- (Positions are tile centres: x.5 for one tile and three tile buildings; the fluid hopper, two tall, at a
-- whole y.)
SCRIPTED.first_experiment = function(s, force_name, origin)
  local put, source, hopper, ox, oy = scene_parts(s, force_name, origin)
  scene_bench(put, source, hopper, -2.5, 0.5, 3)
  put("inserter", -2.5, 2.5, N); put("wooden-chest", -2.5, 3.5)
  -- Beside it, the control: the same trial with no dose.
  scene_bench(put, source, hopper, 3.5, 0.5, nil)
  put("inserter", 3.5, 2.5, N); put("wooden-chest", 3.5, 3.5)
  return {ox + 0.5, oy + 1}
end
SCRIPTED.samples = function(s, force_name, origin)
  local put, source, hopper, ox, oy = scene_parts(s, force_name, origin)
  scene_bench(put, source, hopper, -3.5, 0.5, 3)
  -- Everything the bench makes goes out on a belt; the station takes the samples, the rest goes on.
  put("inserter", -3.5, 2.5, N)
  for x = -3.5, 4.5 do put("transport-belt", x, 3.5, E) end
  -- (A belt does not feed a chest: an inserter at its end takes what the station left into an empty sink.)
  put("inserter", 5.5, 3.5, defines.direction.west); put("infinity-chest", 6.5, 3.5)
  put("substation", 6, 6)
  put("es-analysis-station", 2.5, 0.5)
  local ins = put("fast-inserter", 2.5, 2.5, S)  -- from the belt below into the station
  ins.use_filters = true
  ins.set_filter(1, {name = shared.sample_of(shared.pack), quality = "normal"})
  source(5.5, 0.5, shared.pack, 20); put("inserter", 4.5, 0.5, E)
  return {ox + 0.5, oy + 1.5}
end
local function scene_machine(put, source, hopper, x, y, additive, dose)
  local m = put("assembling-machine-2", x, y)
  m.set_recipe("iron-gear-wheel")
  source(x - 1, y - 3, "iron-plate"); put("inserter", x - 1, y - 2, N)
  if additive then hopper(x, y - 2, additive); dosing.set(m, {rows = {{name = additive, dose = dose}}}) end
  return m
end
SCRIPTED.production = function(s, force_name, origin)
  local put, source, hopper, ox, oy = scene_parts(s, force_name, origin)
  for _, x in ipairs({-4.5, 0.5, 5.5}) do
    scene_machine(put, source, hopper, x, 0.5, "coal", 3)
    put("inserter", x, 2.5, N); put("wooden-chest", x, 3.5)
  end
  return {ox + 0.5, oy + 1}
end
SCRIPTED.residues = function(s, force_name, origin)
  local put, source, hopper, ox, oy = scene_parts(s, force_name, origin)
  scene_machine(put, source, hopper, 0.5, 0.5, "coal", 3)
  -- Products and residue leave by the same inserter; a filter inserter sorts the residue off the belt.
  put("fast-inserter", 0.5, 2.5, N)
  for x = 0.5, 6.5 do put("transport-belt", x, 3.5, E) end
  put("inserter", 7.5, 3.5, defines.direction.west); put("infinity-chest", 8.5, 3.5)
  local sorter = put("fast-inserter", 4.5, 4.5, N)
  sorter.use_filters = true
  sorter.set_filter(1, {name = "es-spent-coal", quality = "normal"})
  put("wooden-chest", 4.5, 5.5)
  put("substation", 2, 6)  -- (the tip's substations do not reach the sorter)
  return {ox + 3.5, oy + 2}
end
SCRIPTED.fluid_hoppers = function(s, force_name, origin)
  local put, source, hopper, ox, oy = scene_parts(s, force_name, origin)
  -- Two gear machines with a fluid hopper between them, fed lubricant by pipe from above.
  for _, x in ipairs({-1.5, 2.5}) do
    local m = put("assembling-machine-2", x, 0.5)
    m.set_recipe("iron-gear-wheel")
    source(x, -2.5, "iron-plate"); put("inserter", x, -1.5, N)
    put("inserter", x, 2.5, N); put("wooden-chest", x, 3.5)
    dosing.set(m, {rows = {{name = "lubricant", dose = 40}}})
  end
  put("es-fluid-hopper", 0.5, 0, N)
  local p = put("infinity-pipe", 0.5, -1.5)
  p.set_infinity_pipe_filter{name = "lubricant", percentage = 1, temperature = 25}
  return {ox + 0.5, oy + 1}
end

-- The circuit tips' scenes (data.lua) and their test: an example blueprint built for real, registered,
-- fed and set to circuit mode. Returns where the camera should look.
local function build_scene(key, surface_name, origin, force_name)
  force_name = force_name or "player"
  local s = game.surfaces[surface_name]
  if SCRIPTED[key] then return SCRIPTED[key](s, force_name, origin) end
  -- Imported and built as a player's blueprint is, ghosts revived (create_entities_from_blueprint_string
  -- works only inside a tips scene, so a test could not run it): tags restore circuit modes and port wires.
  local inv = game.create_inventory(1)
  inv.insert{name = "blueprint"}
  inv[1].import_stack(blueprints[key])
  local ghosts = inv[1].build_blueprint{surface = s, force = force_name, position = origin or {0, 0},
    build_mode = defines.build_mode.forced}
  inv.destroy()
  table.sort(ghosts, function(a, b)  -- stations last: a station reconnects its port to what is built
    return (a.ghost_name == STATION and 1 or 0) < (b.ghost_name == STATION and 1 or 0)
  end)
  for _, g in ipairs(ghosts) do if g.valid then g.revive{raise_revive = true} end end
  local function find(name)
    return s.find_entities_filtered{name = name, position = origin or {0, 0}, radius = 20, force = force_name}[1]
  end
  if key == "adopt_best" then
    -- (Directly: the test hooks' interface, which it once called, exists only in tests, not in a Tips window.)
    simulate_history(force_name, surface_name,
      {{target = "gear", n = 10}, {target = "gear", mix = {coal = 5}, n = 10}, {target = "gear", mix = {stone = 3}, n = 10}})
    local st, m = find("es-analysis-station"), find("assembling-machine-2")
    m.insert{name = "iron-plate", count = 1000}
    local h = find("es-hopper")
    h.insert{name = "coal", count = 50}; h.insert{name = "stone", count = 50}
    return {(st.position.x + m.position.x) / 2, m.position.y}
  end
  local b = find("es-test-bench")
  if not b then
    local seen = {}
    for _, e in pairs(s.find_entities_filtered{position = origin or {0, 0}, radius = 40}) do
      table.insert(seen, e.name .. "@" .. e.position.x .. "," .. e.position.y)
    end
    error("build_scene " .. key .. ": no bench; found " .. table.concat(seen, " "))
  end
  b.insert{name = "iron-plate", count = 1000}
  find("es-hopper").insert{name = "coal", count = 50}
  return b.position
end

-- The dose-signal scene steps its constant combinator through three doses.
local function scene_tick(surface_name, tick)
  if tick % 600 ~= 0 then return end
  local c = game.surfaces[surface_name].find_entities_filtered{name = "constant-combinator"}[1]
  if not c then return end
  local doses = {2, 5, 8}
  c.get_or_create_control_behavior().get_section(1).filters =
    {{value = {type = "item", name = "coal", quality = "normal"}, min = doses[(tick / 600) % 3 + 1]}}
end

-- The tips scenes (data.lua): their builds, always registered, since a Tips window loads only the mods a
-- scene lists (the test hooks below are absent there and in every player's game). They act only inside a
-- scene or a test run, so a console cannot use them to write evidence into a real game.
local function in_scene()
  local ok, sim = pcall(function() return game.simulation end)
  return ok and sim ~= nil
end
local function scenes_allowed()
  for name in pairs(script.active_mods) do if name:find("^es%-") then return true end end
  -- (0.72) The tips check runs the scenes as a Tips window does, without the test hooks (scripts/tips_check.sh).
  if script.active_mods["tips-check"] then return true end
  return in_scene()
end
local showcase = require("scripts.showcase")
remote.add_interface("empirical-science-scenes", {
  build_scene = function(...) if scenes_allowed() then return build_scene(...) end end,
  scene_tick = function(...) if scenes_allowed() then return scene_tick(...) end end,
  augment_showcase = function(key, surface_name, center, scripted)
    if scenes_allowed() then return showcase.augment(key, surface_name, center, scripted) end
  end,
  dose_of = function(unit) if scenes_allowed() then return dosing.rows(unit) end end,
})

-- Test and debug hooks. Reading the truth is a cheat; it exists for automated tests.
-- Test hooks (they read the hidden world: a cheat). Registered only when one of this mod's own test
-- mods is loaded (their names start with "es-"); a player's game never has one.
local TEST_HOOKS = false
for name in pairs(script.active_mods) do
  if name:find("^es%-") then TEST_HOOKS = true end
end
if TEST_HOOKS then
remote.add_interface("empirical-science", {
  simulate_history = simulate_history,
  truth = function() return storage.truth end,
  gain = gain,
  target_pack = function(target_key) return storage.target_pack[target_key] end,
  -- A station's own counts, with the summaries of its force's pool (the pool is what stations feed).
  -- Circuit interface (0.49), for tests: what a port outputs now, what it serves, hopper reports.
  port_filters = function(unit)
    local st = storage.stations[unit]
    local sec = st and st.port.valid and st.port.get_control_behavior() and st.port.get_control_behavior().get_section(1)
    local out = {}
    for _, f in ipairs(sec and sec.filters or {}) do
      if f.value then table.insert(out, {type = f.value.type or "item", name = f.value.name, value = f.min}) end
    end
    return out
  end,
  -- For tests: observations written into a station's own history (what its port reads in "this
  -- station only" mode), so a test can give the port data whose rankings it controls.
  -- (0.72) A pool's premix gate for a mixture key, and its interaction on yield (the Mixtures tab's tooltip).
  premix_state = function(force_name, skey, target_key, key)
    local force = game.forces[force_name]
    local obs = pool_of(force, skey).obs[target_key] or {}
    local gate = research.premix_gate(force, obs, key)
    if not gate then return nil end
    local g = gate.groups
    local inter = gate.ready and regress.interaction(stats.summary(g[1]), stats.summary(g[2]), stats.summary(g[3]),
      stats.summary(g[4]))
    return {counts = gate.counts, ready = gate.ready, enabled = gate.recipe.enabled, recipe = gate.recipe.name,
      p = inter and inter.p, estimate = inter and inter.estimate}
  end,
  -- (0.72) The additives the screen lists for a force.
  visible_additives = function(force_name)
    local out = {}
    for _, a in ipairs(gui.visible_additives(game.forces[force_name])) do out[a.name] = true end
    return out
  end,
  -- (0.72) The Screening row's dose for an additive, on a station's own history.
  screen_best = function(unit, target_key, additive)
    local row = gui.summaries(storage.stations[unit].history, target_key, "yield").additives[additive]
    return row and row.best
  end,
  -- (0.72) The floor rule's parts, for the test to recompute it.
  floor_parts = function(target_key)
    return {floor = research.floor_of(target_key), lost = research.lost_ore(target_key),
      richness = storage.truth.richness, strength = storage.truth.strength}
  end,
  -- (0.72) Side-effect evidence in a station's own history, for the port's Selected result page.
  seed_side = function(unit, effect, target_key, key, values)
    local h = storage.stations[unit].history
    h.side[effect] = h.side[effect] or {}
    local obs = h.side[effect]
    obs[target_key] = obs[target_key] or {control = {n = 0, sum = 0, sumsq = 0}}
    local acc = obs[target_key][key] or {n = 0, sum = 0, sumsq = 0}
    for _, v in ipairs(values) do acc.n, acc.sum, acc.sumsq = acc.n + 1, acc.sum + v, acc.sumsq + v * v end
    obs[target_key][key] = acc
    storage.evidence_version = (storage.evidence_version or 0) + 1
    storage.stations[unit].served = nil
  end,
  prune_routes = function() prune_routes() end,
  seed_history = function(unit, target_key, key, values)
    local obs = storage.stations[unit].history.obs
    obs[target_key] = obs[target_key] or {control = {n = 0, sum = 0, sumsq = 0}}
    local acc = obs[target_key][key] or {n = 0, sum = 0, sumsq = 0}
    for _, v in ipairs(values) do acc.n, acc.sum, acc.sumsq = acc.n + 1, acc.sum + v, acc.sumsq + v * v end
    obs[target_key][key] = acc
    storage.evidence_version = (storage.evidence_version or 0) + 1  -- (written past stats.add: indexes go stale)
    storage.stations[unit].served = nil  -- rewritten on the next analysis tick
  end,
  station_served = function(unit) return storage.stations[unit] and storage.stations[unit].served end,
  hopper_report_set = function(unit, on) hopper_report.set(unit, on) end,
  hopper_report_filters = function(unit)
    local rec = storage.hoppers[unit]
    local cb = rec and rec.reporter and rec.reporter.valid and rec.reporter.get_control_behavior()
    local sec = cb and cb.get_section(1)
    local out = {}
    for _, f in ipairs(sec and sec.filters or {}) do
      if f.value then table.insert(out, {type = f.value.type or "item", name = f.value.name, value = f.min}) end
    end
    return out
  end,
  price_on = function(P, skey) return research.price_on(P, skey) end,
  gui_views = function() return gui.views end,
  -- Other mods' targets (0.55), for tests: a world drawn as a new map's is, three ways: as loaded, with
  -- the registered targets left out, and with one more registered target. Returns whether every other
  -- target's draws (responses, responsiveness, quality) match the first, and the registered ones'.
  registered_check = function(seed)
    local function world()
      local base = base_responsiveness()
      local t = truth.generate(game.create_random_generator(scrambled_seed(seed)), seed + 113)
      t.responsiveness = truth.generate_responsiveness(base, game.create_random_generator(scrambled_seed(seed + 29)))
      truth.extend(t, game.create_random_generator(scrambled_seed(seed + 13)))
      if shared.quality_on then truth.generate_quality(t, game.create_random_generator(scrambled_seed(seed + 101))) end
      truth.extend_targets(t, game.create_random_generator(scrambled_seed(seed + 53)), base)
      truth.extend_registered(t, registered_streams(seed), base)
      return t
    end
    local function draws(t, key)
      local q = {}
      for name, by in pairs(t.quality or {}) do q[name] = by[key] end
      return serpent.line({t.targets[key], t.responsiveness[key], q}, {sortkeys = true, comment = false})
    end
    local all = shared.targets
    local with = world()
    local kept = {}
    for _, t in ipairs(all) do if not t.registered and not t.own_stream then table.insert(kept, t) end end
    local extra = {key = "es-test-extra", result = "iron-chest", batch = 8, process = {metalwork = 1}, registered = true}
    local ok1, without = pcall(function() shared.targets = kept; shared.refresh_target_lists(); return world() end)
    local ok2, more = pcall(function()
      shared.targets = {}
      for _, t in ipairs(all) do table.insert(shared.targets, t) end
      table.insert(shared.targets, 1 + #kept, extra)  -- before the others, as an earlier key would sort
      shared.refresh_target_lists()
      return world()
    end)
    shared.targets = all
    shared.refresh_target_lists()
    if not ok1 then error(without) end
    if not ok2 then error(more) end
    local out = {others_same = true, registered = {}, n_others = 0}
    for _, t in ipairs(all) do
      if t.registered or t.own_stream then
        local r = with.targets[t.key] or {}
        local n, activator = 0, false
        for _, a in ipairs(shared.additives) do
          if r[a.name] then n = n + 1 end
          if a.tier == 1 and r[a.name] and r[a.name].kind == "activator" then activator = true end
        end
        out.registered[t.key] = {n = n, activator = activator, same_with_extra = draws(with, t.key) == draws(more, t.key)}
      else
        out.n_others = out.n_others + 1
        if draws(with, t.key) ~= draws(without, t.key) or draws(with, t.key) ~= draws(more, t.key) then
          out.others_same = false
          out.first_moved = out.first_moved or t.key
        end
      end
    end
    out.live = storage.truth.targets["es-test-pipe"] ~= nil
    return out
  end,
  -- World strength (0.57), for tests: a new map's tier 1 responses on every built-in target, drawn from
  -- one seed at two strengths: whether the scores match, activator counts, and the best peak per target.
  strength_compare = function(seed, a, b)
    local function world(name)
      truth.set_strength(name)
      return truth.generate(game.create_random_generator(scrambled_seed(seed)), seed + 113)
    end
    local wa, wb = world(a), world(b)
    truth.set_strength(strength_of_map())
    local out = {same_scores = true, act = {[a] = 0, [b] = 0}, cells = 0, best = {[a] = {}, [b] = {}}, scores = {}}
    for _, t in ipairs(shared.targets) do
      if wa.targets[t.key] and not t.registered then
        local best = {[a] = 0, [b] = 0}
        for _, ad in ipairs(shared.additives) do
          local ra, rb = wa.targets[t.key][ad.name], wb.targets[t.key][ad.name]
          if ad.tier == 1 and ra and rb then
            out.cells = out.cells + 1
            if math.abs(ra.score - rb.score) > 1e-12 then out.same_scores = false end
            table.insert(out.scores, ra.score)
            for name, r in pairs({[a] = ra, [b] = rb}) do
              if r.kind == "activator" then
                out.act[name] = out.act[name] + 1
                best[name] = math.max(best[name], r.peak)
              end
            end
          end
        end
        table.insert(out.best[a], best[a])
        table.insert(out.best[b], best[b])
      end
    end
    return out
  end,
  -- Family-set shapes (0.58), for tests: on the live world, followers of one family on targets sharing a
  -- main class (agree / pairs), cliffs seen, and whether a world without the law keeps every drawn shape.
  shape_law_check = function()
    local t = storage.truth
    local main = function(p)
      local best, bw = nil, -1
      for _, c in ipairs(shared.process_classes) do if (p[c] or 0) > bw then best, bw = c, p[c] or 0 end end
      return best
    end
    local seen, agree, pairs_n, cliffs, acts = {}, 0, 0, 0, 0
    for _, tg in ipairs(shared.targets) do
      if t.targets[tg.key] and not tg.registered then
        for _, a in ipairs(shared.additives) do
          local r = t.targets[tg.key][a.name]
          if a.tier == 1 and r and r.kind == "activator" and t.traits[a.name] and t.traits[a.name].follows then
            local sh = truth.shape_of(t, tg.key, a.name, r)
            acts = acts + 1
            if sh == "cliff" then cliffs = cliffs + 1 end
            local k = shared.mix_family(a.name) .. "|" .. main(tg.process)
            if seen[k] then
              pairs_n = pairs_n + 1
              if seen[k] == sh then agree = agree + 1 end
            else
              seen[k] = sh
            end
          end
        end
      end
    end
    local old_same = true
    local old = {}
    for k, v in pairs(t) do old[k] = v end
    old.shape_law = nil
    for key, by in pairs(t.targets) do
      for name, r in pairs(by) do
        if r.kind == "activator" and truth.shape_of(old, key, name, r) ~= r.shape then old_same = false end
      end
    end
    return {law = t.shape_law == true, agree = agree, pairs = pairs_n, cliffs = cliffs, acts = acts, old_same = old_same}
  end,
  -- The early set (0.70), for tests: a world of `seed` made with the promotion and without it; every
  -- table the same except the promoted targets' promoted cells; the share of targets promoted; and wood
  -- hidden from the dose picker until Tree seeding (where it exists).
  early_law_check = function(seed)
    local function world()
      local base = base_responsiveness()
      local t = truth.generate(game.create_random_generator(scrambled_seed(seed)), seed + 113)
      t.responsiveness = truth.generate_responsiveness(base, game.create_random_generator(scrambled_seed(seed + 29)))
      truth.extend(t, game.create_random_generator(scrambled_seed(seed + 13)))
      truth.extend_targets(t, game.create_random_generator(scrambled_seed(seed + 53)), base)
      truth.extend_registered(t, registered_streams(seed), base)
      truth.generate_side(t, game.create_random_generator(scrambled_seed(seed + 31)))
      return t
    end
    local real = truth.promote_early
    local with = world()
    truth.promote_early = function() end
    local ok, without = pcall(world)
    truth.promote_early = real
    if not ok then error(without) end
    local line = function(x) return serpent.line(x, {sortkeys = true, comment = false}) end
    local out = {law = with.early_law == true, n = 0, promoted = 0, others_same = true, cells_ok = true}
    for key, by in pairs(with.targets) do
      out.n = out.n + 1
      local p = (with.promoted or {})[key]
      if p then out.promoted = out.promoted + 1 end
      for name, r in pairs(by) do
        local r0 = without.targets[key] and without.targets[key][name]
        if name == p then
          if not (r.kind == "activator" and r0 and r0.kind ~= "activator" and r.score == r0.score) then out.cells_ok = false end
        elseif line(r) ~= line(r0) then
          out.others_same = false; out.first_moved = out.first_moved or (key .. "/" .. name)
        end
      end
    end
    for _, field in ipairs({"traits", "chem", "routes", "responsiveness", "side", "quality"}) do
      if line(with[field]) ~= line(without[field]) then out.others_same = false; out.first_moved = out.first_moved or field end
    end
    local force = game.forces.player
    local tech = prototypes.technology["tree-seeding"] and force.technologies["tree-seeding"]
    local function wood_shown()
      for _, a in ipairs(gui.visible_additives(force)) do if a.name == "wood" then return true end end
      return false
    end
    if tech then
      local was = tech.researched
      tech.researched = false; out.wood_before = wood_shown()
      tech.researched = true; out.wood_after = wood_shown()
      tech.researched = was
    end
    out.space_age = tech ~= nil
    return out
  end,
  -- Side effects by class (0.70), for tests: on the live world, the speed leader among tier 1 and 2 solids
  -- per target, with the law and without it; whether a world without the law keeps the old rule exactly
  -- (an independent copy of it: own value x presence x responsiveness, within the caps).
  side_law_check = function()
    local t = storage.truth
    local old = {}
    for k, v in pairs(t) do old[k] = v end
    old.side_law = nil
    local function leader(w, key, effect)
      local best, bv
      for _, a in ipairs(shared.additives) do
        if (a.tier == 1 or a.tier == 2) and not a.fluid and not a.premix_of then
          local v = truth.effect_on(w, key, {[a.name] = a.max_dose}, effect)
          if not bv or v > bv then best, bv = a.name, v end
        end
      end
      return best
    end
    local out = {law = t.side_law == true, old_same = true, moved = 0, n = 0, leaders = {}}
    for _, tg in ipairs(shared.targets) do
      if t.targets[tg.key] and not tg.registered then
        local k = t.responsiveness and t.responsiveness[tg.key] or 1
        for _, a in ipairs(shared.additives) do
          local sd = t.side[a.name]
          if sd and not a.agent then
            local p = 1 - math.exp(-5 * shared.max_dose / a.max_dose / 3)
            local want = {speed = math.max(-0.5, math.min(0.5, k * (sd.speed * p))),
                          pollution = math.max(-0.9, math.min(0.6, k * (sd.pollution * p))),
                          efficiency = math.max(-0.5, math.min(0.5, k * ((t.efficiency[a.name] or 0) * p)))}
            for e, v in pairs(want) do
              if truth.effect_on(old, tg.key, {[a.name] = 5}, e) ~= v then out.old_same = false end
            end
          end
        end
        local now, before = leader(t, tg.key, "speed"), leader(old, tg.key, "speed")
        out.leaders[tg.key] = now
        out.n = out.n + 1
        if now ~= before then out.moved = out.moved + 1 end
      end
    end
    return out
  end,
  -- The temperature axis (0.61), for tests: bands, widths and the factor on a far best temperature, and a
  -- hopper fed a chilled twin: what a dose takes and at what temperature.
  temp_axis_check = function()
    local P = shared.premix
    local far = 300
    local t = {fluid_temp = {lubricant = far}}
    local edge, inside = truth.temp_factor(t, "lubricant", P.hot), truth.temp_factor(t, "lubricant", P.hot - 15)
    return {band90 = shared.temp_band(90), band91 = shared.temp_band(91), band_cold = shared.temp_band(-100),
      split = select(2, shared.split_band("lubricant@-3")), width_far = truth.temp_width_of(far),
      width_near = truth.temp_width_of(50), edge = edge, inside = inside, law = storage.truth.temp_axis == true,
      bands = #shared.all_bands()}
  end,
  -- Space platforms (0.63), for tests: a platform with a bench (gears, dosed coal from a hopper) and a
  -- station; later, the bench's samples moved into the station and what it analysed, under which pool.
  platform_setup = function()
    local force = game.forces.player
    local p = force.create_space_platform{name = "es-test-platform", planet = "nauvis", starter_pack = "space-platform-starter-pack"}
    if not p then return {error = "no platform"} end
    p.apply_starter_pack()
    local s = p.surface
    local tiles = {}
    for x = -30, -10 do for y = -6, 6 do table.insert(tiles, {name = "space-platform-foundation", position = {x, y}}) end end
    s.set_tiles(tiles)
    local bench = s.create_entity{name = BENCH, position = {-20.5, 0.5}, force = force, raise_built = true}
    local hop = s.create_entity{name = "es-hopper", position = {-18.5, 0.5}, force = force, raise_built = true}
    local station = s.create_entity{name = STATION, position = {-26.5, 0.5}, force = force, raise_built = true}
    if not (bench and hop and station) then return {error = "placement failed"} end
    bench.set_recipe(shared.trial_recipe("gear"))
    bench.insert{name = "iron-plate", count = 400}
    hop.get_inventory(defines.inventory.chest).insert{name = "coal", count = 50}
    dosing.set(bench, {rows = {{name = "coal", dose = 2}}})
    -- (0.72: the packs its samples need, space science's: a station takes the samples of the packs it holds)
    local sinv = station.get_inventory(defines.inventory.chest)
    sinv.insert{name = "automation-science-pack", count = 20}
    sinv.insert{name = storage.target_pack["space-science"] or "space-science-pack", count = 20}
    reserve_sample_slots(station)
    storage.platform_test = {bench = bench, station = station, surface = s.name, skey = shared.surface_key(s)}
    return {surface = s.name, skey = shared.surface_key(s)}
  end,
  platform_move = function()
    local pt = storage.platform_test
    if not (pt and pt.bench.valid) then return 0 end
    local out = pt.bench.get_inventory(defines.inventory.assembling_machine_output)
    local n = 0
    for i = 1, #out do
      local st = out[i]
      if st.valid_for_read and shared.is_sample(st.name) then
        local inv = pt.station.get_inventory(defines.inventory.chest)
          if inv.can_insert(st) then n = n + 1; inv.insert(st); st.clear() end
        end
    end
    return n
  end,
  platform_report = function()
    local pt = storage.platform_test
    if not pt then return {error = "not set up"} end
    local st = storage.stations[pt.station.unit_number]
    local pool = pool_of(game.forces.player, pt.skey)
    local dosed = 0
    for k, acc in pairs(pool.obs.gear or {}) do if k:find("^coal:") then dosed = dosed + acc.n end end
    return {skey = pt.skey, analysed = st and st.analysed or 0, dosed = dosed, control = pool.obs.gear and pool.obs.gear.control.n or 0}
  end,
  -- Additions move no world (0.62), for tests: a full new world drawn with every additive and with the
  -- late-filled ones (the living additives) left out; every other additive's draws compared, stream by stream.
  late_check = function(seed)
    local function world()
      local base = base_responsiveness()
      local t = truth.generate(game.create_random_generator(scrambled_seed(seed)), seed + 113)
      t.responsiveness = truth.generate_responsiveness(base, game.create_random_generator(scrambled_seed(seed + 29)))
      t.chem = t.chem or truth.generate_chemistry(game.create_random_generator(scrambled_seed(seed + 7)))
      truth.extend(t, game.create_random_generator(scrambled_seed(seed + 13)))
      truth.extend_targets(t, game.create_random_generator(scrambled_seed(seed + 53)), base)
      truth.generate_side(t, game.create_random_generator(scrambled_seed(seed + 31)))
      truth.generate_conditions(t, game.create_random_generator(scrambled_seed(seed + 67)))
      truth.generate_additive_conditions(t, game.create_random_generator(scrambled_seed(seed + 79)))
      truth.generate_fluid_temps(t, game.create_random_generator(scrambled_seed(seed + 83)))
      truth.generate_premix_temps(t, game.create_random_generator(scrambled_seed(seed + 71)))
      truth.generate_efficiency(t, game.create_random_generator(scrambled_seed(seed + 89)))
      truth.generate_freshness(t, game.create_random_generator(scrambled_seed(seed + 131)))
      return t
    end
    local function draws(t, name, family)
      local per_target = {}
      for key, by in pairs(t.targets) do per_target[key] = by[name] end
      return serpent.line({t.traits[name], per_target, t.side and t.side[name], t.efficiency and t.efficiency[name],
        t.freshness and t.freshness[name], t.fluid_temp and t.fluid_temp[name], t.premix_temp and t.premix_temp[name],
        t.cond and t.cond.family[family], t.cond and t.cond.additive and t.cond.additive[name], t.chem and t.chem[family],
        t.side_family and t.side_family[family], t.fresh_family and t.fresh_family[family]}, {sortkeys = true, comment = false})
    end
    local with = world()
    local keep_add, keep_all = shared.additives, shared.all_additives
    local function strip(list)
      local out = {}
      for _, a in ipairs(list) do if not a.fill_late then table.insert(out, a) end end
      return out
    end
    local ok, without = pcall(function()
      shared.additives, shared.all_additives = strip(keep_add), strip(keep_all)
      return world()
    end)
    shared.additives, shared.all_additives = keep_add, keep_all
    if not ok then error(without) end
    local compared, moved = 0, nil
    for _, a in ipairs(keep_add) do
      if not a.fill_late then
        compared = compared + 1
        if draws(with, a.name, a.family) ~= draws(without, a.name, a.family) and not moved then
          moved = a.name
          local parts = {"traits", "targets", "side", "efficiency", "freshness", "fluid_temp", "premix_temp", "cond_family",
            "cond_additive", "chem", "side_family", "fresh_family"}
          local function one(t, i)
            local per_target = {}
            for key, by in pairs(t.targets) do per_target[key] = by[a.name] end
            local v = ({t.traits[a.name], per_target, t.side and t.side[a.name], t.efficiency and t.efficiency[a.name],
              t.freshness and t.freshness[a.name], t.fluid_temp and t.fluid_temp[a.name], t.premix_temp and t.premix_temp[a.name],
              t.cond and t.cond.family[a.family], t.cond and t.cond.additive and t.cond.additive[a.name], t.chem and t.chem[a.family],
              t.side_family and t.side_family[a.family], t.fresh_family and t.fresh_family[a.family]})[i]
            return serpent.line(v, {sortkeys = true, comment = false})
          end
          for i, part in ipairs(parts) do
            if one(with, i) ~= one(without, i) then moved = moved .. " (" .. part .. ")"; break end
          end
        end
      end
    end
    local late = 0
    for _, a in ipairs(keep_add) do if a.fill_late and with.traits[a.name] then late = late + 1 end end
    return {compared = compared, moved = moved, late = late}
  end,
  -- Ripeness (0.62), for tests: a living additive's best ripeness and its factor there, fresh and far; a
  -- hopper's half-spoiled mash taken as a dose; an egg left to spoil in a hopper.
  ripe_check = function()
    local best = truth.ripe_best(storage.truth, "yumako-mash")
    local s = game.surfaces.nauvis
    local m = s.create_entity{name = "assembling-machine-2", position = {-250.5, -200.5}, force = "player", raise_built = true}
    m.set_recipe("iron-gear-wheel")
    local hop = s.create_entity{name = "es-hopper", position = {-252.5, -200.5}, force = "player", raise_built = true}
    local inv = hop.get_inventory(defines.inventory.chest)
    inv.insert{name = "yumako-mash", count = 10}
    for i = 1, #inv do if inv[i].valid_for_read and inv[i].name == "yumako-mash" then inv[i].spoil_percent = 0.5 end end
    local ok, _, temps = dosing.take(m, {["yumako-mash"] = 4})
    local key = sample_key({mix = {["yumako-mash"] = 4}, temps = temps})
    hop.destroy(); m.destroy()
    return {best = best, at_best = truth.ripe_factor(storage.truth, "yumako-mash", best),
      fresh = truth.ripe_factor(storage.truth, "yumako-mash", 0), ok = ok, ripe = temps and temps["yumako-mash"], key = key}
  end,
  egg_hopper = function()
    local s = game.surfaces.nauvis
    local hop = s.create_entity{name = "es-hopper", position = {-262.5, -200.5}, force = "player", raise_built = true}
    local inv = hop.get_inventory(defines.inventory.chest)
    inv.insert{name = "pentapod-egg", count = 1}
    for i = 1, #inv do if inv[i].valid_for_read then inv[i].spoil_percent = 0.9999 end end
    storage.egg_hopper = hop
    storage.egg_set_tick = game.tick
  end,
  egg_hatched = function()
    local hop = storage.egg_hopper
    if not (hop and hop.valid) then return {gone = true} end
    local n = hop.get_inventory(defines.inventory.chest).get_item_count("pentapod-egg")
    local around = hop.surface.count_entities_filtered{position = hop.position, radius = 20, type = {"unit", "spider-unit", "segmented-unit"}}
    local anywhere = hop.surface.count_entities_filtered{name = "big-wriggler-pentapod-premature"}
    return {eggs = n, creatures = around, anywhere = anywhere, tick = game.tick, set = storage.egg_set_tick}
  end,
  -- (0.70) A slurry dose leaves its solid member's residue at its share, the remainder carried to the next
  -- dose: doses of `amount` units `times` over, the residues left after each.
  slurry_take = function(slurry, amount, times)
    local s = game.surfaces.nauvis
    local m = s.create_entity{name = "assembling-machine-2", position = {-236.5, -200.5}, force = "player", raise_built = true}
    m.set_recipe("iron-gear-wheel")
    local hop = s.create_entity{name = "es-fluid-hopper", position = {-238.5, -200.5}, force = "player", raise_built = true}
    local rec = storage.hoppers[hop.unit_number]
    rec.port.insert_fluid{name = slurry, amount = amount * times}
    local trash = m.get_inventory(defines.inventory.crafter_trash)
    local after, shares = {}, shared.residue_shares(slurry)
    for i = 1, times do
      dosing.take(m, {[slurry] = amount})
      local n = 0
      for r in pairs(shares) do n = n + trash.get_item_count(r) end
      after[i] = n
    end
    hop.destroy(); m.destroy()
    return {after = after, shares = shares}
  end,
  -- (0.70) The frontier's ceiling: lubricant's best temperature far off, read at it, without and with the law.
  frontier_check = function()
    local old = {fluid_temp = {lubricant = 400}}
    local new = {fluid_temp = {lubricant = 400}, frontier_law = true}
    return {old = truth.temp_factor(old, "lubricant", 400), new = truth.temp_factor(new, "lubricant", 400),
      max = truth.frontier_max}
  end,
  -- (0.70) The science seed: the world init_storage builds from `seed`, as a fingerprint (the hidden world's
  -- responses on two targets, responsiveness, a side effect), and the live world's; the live world restored.
  science_seed_check = function(seed)
    local function print_of(t)
      return truth.fnv(serpent.line({t.targets.gear, t.targets.red, t.responsiveness, t.side and t.side.coal},
        {sortkeys = true, comment = false}))
    end
    local live, old_rng = storage.truth, storage.rng
    local out = {live_seed = live.science_seed, map_seed = game.surfaces[1].map_gen_settings.seed, live = print_of(live)}
    settings.global["es-science-seed"] = {value = seed}
    storage.truth = nil
    init_storage()
    out.seeded, out.seeded_seed = print_of(storage.truth), storage.truth.science_seed
    storage.truth, storage.rng = live, old_rng
    settings.global["es-science-seed"] = {value = 0}
    return out
  end,
  chilled_take = function()
    local s = game.surfaces.nauvis
    local m = s.create_entity{name = "assembling-machine-2", position = {-230.5, -200.5}, force = "player", raise_built = true}
    m.set_recipe("iron-gear-wheel")
    local hop = s.create_entity{name = "es-fluid-hopper", position = {-232.5, -200.5}, force = "player", raise_built = true}
    local rec = storage.hoppers[hop.unit_number]
    local n = rec and rec.port and rec.port.valid and rec.port.insert_fluid{name = shared.chilled_of("lubricant"), amount = 100, temperature = -100} or 0
    local ok, _, temps = dosing.take(m, {lubricant = 20})
    local out = {inserted = n, ok = ok, temp = temps and temps.lubricant, left = rec and rec.port.get_fluid_count(shared.chilled_of("lubricant"))}
    hop.destroy(); m.destroy()
    return out
  end,
  -- Fulgora scrap samples (0.60), for tests: n draws with a pack of `tier` on a scratch pool (counts per
  -- cell, duds, targets seen).
  scrap_draws = function(n, tier, seed)
    local pool, rng = {}, game.create_random_generator(seed or 4242)
    local duds, targets = 0, {}
    for _ = 1, n do
      local cell = draw_scrap(game.forces.player, pool, tier, rng)
      if cell then targets[cell.target] = (targets[cell.target] or 0) + 1 else duds = duds + 1 end
    end
    local max_cell, max_control = 0, 0
    for k, v in pairs(pool.scrap_counts or {}) do
      if k:find("|control|", 1, true) then max_control = math.max(max_control, v) else max_cell = math.max(max_cell, v) end
    end
    return {duds = duds, targets = targets, max_cell = max_cell, max_control = max_control}
  end,
  scrap_targets = function() return scrap_targets(game.forces.player) end,
  -- A temporary station fed scrap samples, a red and an electromagnetic pack, analysed n times: which packs
  -- went, how many results and duds, research data made (none expected).
  scrap_station = function(n, quality)
    local s = game.surfaces.nauvis
    -- Its own force: random scrap evidence would otherwise land in the player's pool (it unsettled a
    -- premix-discovery check on one map).
    local force = game.forces["es-scrap-test"] or game.create_force("es-scrap-test")
    local e = s.create_entity{name = STATION, position = {-200, -200}, force = force, raise_built = true}
    local station = storage.stations[e.unit_number]
    local inv = e.get_inventory(defines.inventory.chest)
    inv.insert{name = shared.scrap.item, count = n}
    -- With `quality`: one red pack of that quality and nothing else (how far one pack goes).
    inv.insert{name = "automation-science-pack", count = quality and 1 or 20, quality = quality or "normal"}
    local em = not quality and prototypes.item["electromagnetic-science-pack"]
      and inv.insert{name = "electromagnetic-science-pack", count = 1} or 0
    local data0 = station.data_made or 0
    for _ = 1, n do analyse(e.unit_number, station) end
    local out = {analysed = station.scrap_analysed or 0, duds = station.unreadable, data = (station.data_made or 0) - data0,
      red_left = inv.get_item_count("automation-science-pack"), em_left = inv.get_item_count("electromagnetic-science-pack"),
      em_given = em, left = inv.get_item_count(shared.scrap.item),
      per_pack = quality and pack_samples(force, prototypes.quality[quality]) or nil}
    e.destroy{raise_destroy = true}
    return out
  end,
  -- The Theory tab's shapes (0.59), for tests: gui.family_shapes on a given set of observations.
  family_shapes_of = function(obs) return gui.family_shapes({obs = obs, side = {}}) end,
  -- The shape an activator takes on a target (family law on new worlds), for tests and curve checks.
  shape_of = function(target_key, additive)
    return truth.shape_of(storage.truth, target_key, additive, storage.truth.targets[target_key][additive])
  end,
  fit_temperature = function(points, lo, hi)
    local f = regress.fit_temperature(points, lo, hi)
    return f and {temp = f.temp, lo = f.lo, hi = f.hi, gain = f.gain, width = f.width}
  end,
  -- The Theory model (0.53), for tests: a fit of given cells, and of a force's pool.
  theory_fit_cells = function(cells)
    local fit = theory.fit(cells)
    if not fit then return nil end
    local out = {families = fit.families, tau2 = fit.tau2, predictions = {}}
    for _, t in ipairs(shared.targets) do out.predictions[t.key] = fit.predict(cells[1].additive, t.key) end
    return out
  end,
  theory_pool = function(force_name, skey)
    local cells = theory.cells(pool_of(game.forces[force_name], skey).obs)
    local fit = theory.fit(cells)
    local untested = fit and theory.untested(fit, cells) or {}
    return {cells = #cells, fitted = fit ~= nil, untested = #untested, top = untested[1]}
  end,
  -- For the GUI test: the planet a player's screen shows.
  set_view_surface = function(player_index, key)
    storage.gui_view_surface = storage.gui_view_surface or {}
    storage.gui_view_surface[player_index] = key
    gui.refresh_player(game.get_player(player_index))
  end,
  station = function(unit, target_key, effect)
    local s = storage.stations[unit]
    if not s then return nil end
    local pool = pool_of(s.entity.force, surface_key(s.entity.surface))
    local out = {analysed = s.analysed, unreadable = s.unreadable, port = s.port, summaries = {},
      pool_analysed = pool.analysed, data_made = s.data_made or 0, failed = s.failed or 0, scrap_analysed = s.scrap_analysed or 0}
    local root = (not effect or effect == "yield") and pool.obs or (pool.side[effect] or {})
    for key, acc in pairs(root[target_key or shared.targets[1].key] or {}) do
      out.summaries[key] = stats.summary(acc) or {n = 0}
    end
    return out
  end,
  set_port_source = function(unit, source)
    storage.stations[unit].port_source = source
    write_outputs(storage.stations[unit], {})
  end,
  set_view_target = function(unit, target_key)
    storage.stations[unit].view_target = target_key
    write_outputs(storage.stations[unit], {})
  end,
  open_science = function(player_index) gui.open(game.get_player(player_index)) end,
  clear_target = function(force_name, target_key, skey) clear_target(game.forces[force_name], target_key, skey) end,
  station_alert = function(unit) return storage.station_alerts and storage.station_alerts[unit] end,
  -- Planet conditions: a composition's true gain on a surface, and a pool's summaries.
  gain_on_surface = function(target_key, mix, surface_name)
    return truth.gain_on(storage.truth, target_key, mix, surface_cond(game.surfaces[surface_name]))
  end,
  -- The planet migration on given tables (old-shape pools and memory), run twice (idempotent).
  migrate_to_planets = function(pools, memory)
    migrate_to_planets(pools, memory); migrate_to_planets(pools, memory)
    return {pools = pools, memory = memory}
  end,
  -- Liquid premixes: a composition's true gain with its fluids at given temperatures.
  gain_at_temps = function(target_key, mix, temps) return truth.gain_on(storage.truth, target_key, mix, nil, temps) end,
  premix_best_temp = function(name)
    return (storage.truth.premix_temp and storage.truth.premix_temp[name]) or (storage.truth.fluid_temp and storage.truth.fluid_temp[name])
  end,
  -- Migration test: a discovery recorded under a name, then the load routine (idempotent) run again.
  mark_discovered = function(force_name, name)
    local f = game.forces[force_name]
    storage.discovered[f.index] = storage.discovered[f.index] or {}
    storage.discovered[f.index][name] = true
  end,
  rerun_init = function() init_storage() end,
  pool_summaries = function(force_name, skey, target_key)
    local out = {}
    for key, acc in pairs(pool_of(game.forces[force_name], skey).obs[target_key] or {}) do
      out[key] = stats.summary(acc) or {n = 0}
    end
    return out
  end,
  -- A station's own history (what its port reads in "this station only" mode).
  -- (0.72) The Screening grid's row for an additive on a station's own history, as the port's Screening page reads it.
  station_row = function(unit, target_key, additive)
    local s = storage.stations[unit]
    local skey = shared.surface_key(s.entity.surface)
    return research.row(s.entity.force.index, s.history.obs[target_key] or {}, target_key, additive, skey,
      s.history.quality and s.history.quality[target_key])
  end,
  station_history = function(unit, target_key)
    local s = storage.stations[unit]
    local out = {}
    for key, acc in pairs(s and s.history.obs[target_key] or {}) do out[key] = stats.summary(acc) or {n = 0} end
    return out
  end,
  -- Research data: what a sample under `key` would be paid now, and what the force has made.
  data_rate = function(force_name, target_key, key, skey)
    local force = game.forces[force_name]
    local pool = pool_of(force, skey)
    return research.rate(force.index, pool.obs[target_key] or {}, target_key, key, skey,
      pool.quality and pool.quality[target_key])
  end,
  data_made = function(force_name)
    local sum = 0
    for _, pool in pairs(storage.pools[game.forces[force_name].index] or {}) do sum = sum + (pool.data_made or 0) end
    return sum
  end,
  question_state = function(force_name, target_key, question, skey)
    local o, best = research.question_state(pool_of(game.forces[force_name], skey).obs[target_key] or {}, target_key, question)
    return {openness = o, best = best}
  end,
  tau = function(target_key, mix) return research.tau(target_key, mix) end,
  samples_per_pack = function(force_name) return samples_per_pack(game.forces[force_name]) end,
  noise_factor = function(force_name) return noise_factor(game.forces[force_name]) end,
  fit = function(unit, target_key, additive, model)
    local st = storage.stations[unit]
    local fit, why = regress.fit(gui.points(pool_of(st.entity.force, surface_key(st.entity.surface)), target_key, additive), model)
    if not fit then return {error = why} end
    fit.curve = nil
    return fit
  end,
  fit_points = function(points, model)
    local fit, why
    if model == "auto" then fit, why = regress.auto(points) else fit, why = regress.fit(points, model) end
    if not fit then return {error = why} end
    local out = {}
    for d = 0, 9 do out[d + 1] = fit.curve(d) end
    fit.curve = nil
    fit.values = out
    return fit
  end,
  draw_chart = function(player_index, data) return chart.draw(player_index, data) end,
  chart_objects_mix = function(player_index)
    local state = storage.charts and storage.charts[player_index .. ":mix"]
    return state and #state.line_ids or 0
  end,
  chart_objects_progress = function(player_index)
    local state = storage.charts and storage.charts[player_index .. ":progress"]
    return state and #state.line_ids or 0
  end,
  chart_objects = function(player_index)
    local state = storage.charts and storage.charts[player_index]
    return state and #state.line_ids or 0
  end,
  visible_names = function(player_index)
    local out = {}
    for i, a in ipairs(gui.visible_additives(game.get_player(player_index).force)) do out[i] = a.name end
    return out
  end,
  gui_set = function(player_index, choice)
    local player = game.get_player(player_index)
    if choice.mix_a then apply_selection(player, "mix-a", choice.mix_a) end
    if choice.mix_b then apply_selection(player, "mix-b", choice.mix_b) end
    if choice.mix_band_a then apply_selection(player, "mix-band-a", choice.mix_band_a) end
    if choice.mix_band_b then apply_selection(player, "mix-band-b", choice.mix_band_b) end
    if choice.target then apply_selection(player, "target", choice.target) end
    if choice.additive then apply_selection(player, "select", choice.additive) end
    if choice.temp_band then apply_selection(player, "temp-band", choice.temp_band) end
    if choice.screen_sort then apply_selection(player, "screen-sort", choice.screen_sort) end
    if choice.screen_show then apply_selection(player, "screen-show", choice.screen_show) end
    if choice.model then apply_selection(player, "model", choice.model) end
    if choice.effect then apply_selection(player, "effect", choice.effect) end
    if choice.theory_effect then apply_selection(player, "theory-effect", choice.theory_effect) end
    if not next(choice) then gui.refresh_player(player) end  -- (a refresh, as a tab change does)
    if choice.all_targets ~= nil then
      storage.gui_all_targets = storage.gui_all_targets or {}
      storage.gui_all_targets[player.index] = choice.all_targets
      if storage.gui_targets then storage.gui_targets[player.index] = nil end
      gui.refresh_player(player)
    end
  end,
  missed_tags = function() return storage.missed_tags end,
  -- Diagnostics: mean and sd of n normal draws from a fresh generator seeded like the map's trial noise.
  normal_stats = function(n)
    local rng = game.create_random_generator(scrambled_seed(game.surfaces[1].map_gen_settings.seed))
    local sum, sumsq = 0, 0
    for _ = 1, n do local z = truth.normal(rng); sum = sum + z; sumsq = sumsq + z * z end
    local mean = sum / n
    return {mean = mean, sd = math.sqrt(sumsq / n - mean * mean)}
  end,
  crafter_state = function(unit)
    local c = storage.crafters[unit]
    return c and {last = c.last, debt = c.debt, bonus_total = c.bonus_total or 0, dose_made = c.dose_made,
      dose_extra = c.dose_extra, inputs_taken = c.inputs_taken or 0,
      outputs_taken = c.outputs_taken or 0, has_power = c.power ~= nil and c.power.valid,
      fresh_f = c.fresh_f, fresh_restored = c.fresh_restored or 0, fresh_missed = c.fresh_missed or 0,
      polluted = c.polluted or 0, upgraded_total = c.upgraded_total or 0, quality_owed = c.quality_owed or 0,
      quality_earned = c.quality_earned or 0, quality_rolled = c.quality_rolled or 0, quality_qc = c.quality_qc, quality_lost = c.quality_lost or 0,
      power_usage = c.power and c.power.valid and c.power.power_usage or 0,
      power_production = c.power and c.power.valid and c.power.power_production or 0,
      power_energy = c.power and c.power.valid and c.power.energy or 0,
      efficiency = storage.doses[unit] and storage.doses[unit].active and storage.doses[unit].active.efficiency or nil,
      working = c.entity.status == defines.entity_status.working,
      base_draw = (c.entity.prototype.energy_usage or 0) * (1 + (c.entity.consumption_bonus or 0))}
  end,
  -- For tests: the quirk hash on a reference string, and the quirks' mean and SD over many keys.
  quirk_stats = function()
    local n, sum, sumsq = 0, 0, 0
    for i = 1, 4000 do
      local q = truth.quirk({quirk_seed = 99}, "a" .. i, "t" .. (i % 7))
      n, sum, sumsq = n + 1, sum + q, sumsq + q * q
    end
    return {ref = truth.fnv("12345:coal:gear:1"), mean = sum / n, sd = math.sqrt(sumsq / n - (sum / n) ^ 2),
            sd_want = truth.quirk_sd, none = truth.quirk({}, "coal", "gear")}
  end,
  -- For tests: a crafter's hidden consumer set to draw this much (J/tick), whatever its dose.
  restore_power = function(unit)  -- what the machine's next poll would set (undoes force_power_draw)
    local c, d = storage.crafters[unit], storage.doses[unit]
    set_power(c, c.entity, d and d.active and d.active.efficiency or 0)
  end,
  force_power_draw = function(unit, joules)
    local c = storage.crafters[unit]
    set_power(c, c.entity, -1)
    c.power.power_usage = joules
    c.power.electric_buffer_size = joules * 2 + 1
  end,
  -- Dosing: settings {rows = {{name, dose}...}, circuit}, state, and the panel for the GUI test.
  set_dose = function(unit, settings)
    local c = storage.crafters[unit] or storage.benches[unit]
    dosing.set(c.entity, settings)
  end,
  unlock_activation = function(force_name, residue) unlock_activation(game.forces[force_name], residue) end,
  mix_family = function(name) return shared.mix_family(name) end,
  full_saving = function(target_key, mix, g, sp, cl, ef, P) return research.full_saving(target_key, mix, g, sp, cl, ef, P) end,
  -- One map's hidden world as a table (scripts/ground_truth.sh): per target, every dosable additive at
  -- its best dose by yield and by net ore, with speed, cleanliness and the quality chance; alternative
  -- recipes; family chemistry. For reading what a game would uncover, never shown in game.
  ground_truth = function() return answer_key.compute() end,
  -- The best two-additive mixtures per target and effect (answer_key.pairs), for the ground-truth export.
  ground_truth_pairs = function()
    local d = answer_key.compute()
    local out = {}
    for _, t in ipairs(d.targets) do
      out[t.key] = {}
      for _, r in ipairs({"yield", "net", "speed", "cleanliness", "efficiency"}) do
        local p = answer_key.pairs(t, r)
        local top = {}
        for i = 1, math.min(6, #p) do top[i] = p[i] end
        out[t.key][r] = top
      end
    end
    return out
  end,
  -- (Tests) The answer key's data without its screen: per effect, how many additives rank on gears and the
  -- best value; the best gear pair by yield; and the major findings on offer per effect.
  answer_key_probe = function()
    local d = answer_key.compute()
    local th = dossiers.thresholds()
    local out = {ranked = {}, majors = {}, top = {}}
    local gear
    for _, t in ipairs(d.targets) do if t.key == "gear" then gear = t end end
    for _, r in ipairs(answer_key.READOUTS) do
      local n, top = 0, nil
      for _, row in ipairs(gear.rows) do
        if row.best[r] then
          n = n + 1
          if not top or row.best[r].v > top then
            top = row.best[r].v
            out.who = out.who or {}
            out.who[r] = row.name .. "@" .. row.best[r].d .. " clean " .. tostring(row.by_dose[row.best[r].d].cleanliness)
              .. " eff " .. tostring(row.by_dose[row.best[r].d].efficiency)
          end
        end
      end
      out.ranked[r], out.top[r] = n, top
    end
    local p = answer_key.pairs(gear, "yield")
    out.pair = p[1] and {v = p[1].v, alone = p[1].alone, size = table_size(p[1].mix)} or nil
    for _, r in ipairs(dossiers.EXCEPTIONAL) do
      local n = 0
      for _, t in ipairs(d.targets) do
        for _, row in ipairs(t.rows) do if row.best[r] and row.best[r].v >= th.exceptional[r] then n = n + 1 end end
      end
      out.majors[r] = n
    end
    return out
  end,
  open_answer_key = function(player_index) answer_key.open(game.get_player(player_index)) end,
  answer_key_select = function(player_index, action, index)
    return answer_key.on_selection(game.get_player(player_index), action, index)
  end,
  mix_constants = function() return {overlap = truth.overlap, stack_cap = truth.stack_cap} end,
  -- Quality agents: the pooled counts for a target, and the hidden chance for a composition.
  quality_pool = function(force_name, target_key)
    local pool = pool_of(game.forces[force_name], "nauvis")
    return pool.quality and pool.quality[target_key] or {}
  end,
  quality_chance = function(key, mix) return truth.quality_chance(storage.truth, key, mix) end,
  -- The dose picker's choices and the screen's targets for a force (keys), and a hopper's spent state.
  pickable = function(force_name)
    local out = {}
    for _, a in ipairs(gui.pickable_additives(game.forces[force_name])) do out[a.name] = true end
    return out
  end,
  targets_for = function(force_name)
    local force = game.forces[force_name]
    local out = {}
    for _, t in ipairs(gui.targets_for(pool_of(force, "nauvis"), force, nil)) do out[t.key] = true end
    return out
  end,
  trash_full = function(unit)
    local rec = storage.trash_full and storage.trash_full[unit]
    return {full = rec and rec.residue, icon = rec and rec.warn ~= nil and rec.warn.valid or false}
  end,
  -- Staged reveal: grant (or revoke) a force's pre-staging access to every staged tool.
  set_legacy_stages = function(force_name, on)
    storage.legacy_stages = storage.legacy_stages or {}
    storage.legacy_stages[game.forces[force_name].index] = on or nil
  end,
  -- Dossiers (tests): the force's dossiers judged now, flattened; production added by hand; the slow
  -- update run now; when the force finished (a tick, or nil).
  dossier_state = function(force_name)
    local force = game.forces[force_name]
    local r = dossiers.evaluate(force)
    local function flat(b)
      local e = b.entry
      return {state = b.state, target = e and e.target, readout = e and e.readout, key = e and e.key, lb = e and e.lb,
        threshold = e and e.threshold, made = e and e.made, volume = e and e.volume}
    end
    local out = {planets = {}, exceptional = {}, exc_done = r.exc_done, exc_needed = r.exc_needed, finished = r.finished}
    for name, p in pairs(r.planets) do
      local ts = {}
      for _, b in ipairs(p.targets) do ts[b.target.key] = flat(b) end
      out.planets[name] = {quota = p.quota, done = p.done, reached = p.reached, targets = ts}
    end
    for readout, b in pairs(r.exceptional) do out.exceptional[readout] = flat(b) end
    return out
  end,
  dossier_bars = function() return dossiers.thresholds() end,
  -- The Theory tab on one effect (0.70), for tests: its cells and fit on the force's Nauvis pool.
  theory_check = function(force_name, effect, given)
    local pool = (storage.pools[game.forces[force_name].index] or {}).nauvis or {obs = {}, side = {}}
    local cells = given or theory.cells(effect == "yield" and pool.obs or ((pool.side or {})[effect] or {}))
    local fit = #cells > 0 and theory.fit(cells) or nil
    local finite = fit ~= nil
    local bad
    for f, fam in pairs(fit and fit.families or {}) do
      for c = 1, #fam.est do
        for _, v in ipairs({fam.est[c], fam.lo[c], fam.hi[c]}) do
          if v ~= v or v == math.huge or v == -math.huge then finite = false; bad = bad or f end
        end
      end
    end
    return {n = #cells, first = cells[1], finite = finite, bad = bad, tau2 = fit and fit.tau2}
  end,
  dossier_add_made = function(force_name, target_key, key, n)
    dossiers.record_made(game.forces[force_name], target_key, key, n, true)  -- (written: not on the Progress tab)
  end,
  dossier_made = function(force_name, target_key, key)
    local by = storage.dossier_made and storage.dossier_made[game.forces[force_name].index]
    return by and by[target_key] and by[target_key][key] or 0
  end,
  dossier_summary_open = function(player_index)  -- (GUI test) the summary as completion shows it
    local player = game.get_player(player_index)
    gui.open_dossier_summary(player, dossiers.evaluate(player.force))
  end,
  -- (Tests) The finding messages for a force now; returns the findings announced so far.
  dossier_announce = function(force_name)
    local force = game.forces[force_name]
    dossiers.announce(force, dossiers.evaluate(force))
    local out = {}
    for id in pairs(storage.dossier_announced[force.index] or {}) do table.insert(out, id) end
    return out
  end,
  -- (Tests) The settle estimate on given figures: samples left, and whether settled at that count and one before.
  settle_check = function(net, se, n, nc)
    local k = research.samples_to_settle({net = net, se = se, n = n}, nc)
    local function at(j) return research.settled(net, se * math.sqrt((n + nc) / (n + nc + j))) end
    local before = nil  -- (not "k > 0 and at(k - 1) or nil": a false would become nil)
    if k > 0 then before = at(k - 1) end
    return {k = k, at = at(k), before = before}
  end,
  -- (Tests) A machine's alt-mode dose drawing: its signature and how many drawings are alive and alt-mode only.
  badges = function(unit)
    local b = storage.badges and storage.badges[unit]
    if not b then return nil end
    local alive, alt = 0, 0
    for _, obj in ipairs(b.ids) do
      if obj.valid then alive = alive + 1; if obj.only_in_alt_mode then alt = alt + 1 end end
    end
    return {sig = b.sig, alive = alive, alt = alt}
  end,
  -- A blueprint of an area, tagged as the player's blueprint tool tags it, as an export string (the
  -- example blueprints, tests/es-blueprints).
  blueprint_of = function(surface_name, area, label)
    local inv = game.create_inventory(1)
    inv.insert{name = "blueprint"}
    local bp = inv[1]
    local mapping = bp.create_blueprint{surface = game.surfaces[surface_name], force = "player", area = area,
      always_include_tiles = false}
    tag_blueprint(bp, mapping)
    bp.label = label
    local out = bp.export_stack()
    inv.destroy()
    return out
  end,
  example_blueprints = function() return blueprints end,
  -- (Tests) One dose taken from a machine's hoppers now: ok and why.
  take_now = function(unit, needs)
    local m = (storage.crafters[unit] or storage.benches[unit] or {}).entity
    if not (m and m.valid) then return {error = "no machine"} end
    local ok, why = dosing.take(m, needs)
    return {ok = ok, why = why}
  end,
  give_blueprints = function(player_index) give_blueprints(game.get_player(player_index)) end,
  -- (Tests) The ending's report for a force, whether or not it finished (the tab shows it only once it has).
  dossier_report = function(force_name)
    local r = dossiers.report_fn(game.forces[force_name])
    return {planets = r.planets, majors = r.majors, truth = r.truth, look = r.look}
  end,
  dossier_volume = function(target_key) return dossiers.volume(shared.target(target_key)) end,
  -- (Tests only) Evidence written straight into a force's pool: n readings of a cell around a gain (per
  -- mille), and n of its control around nothing. Readout: yield, speed, pollution, efficiency, freshness.
  dossier_seed = function(force_name, skey, target_key, key, readout, gain, n)
    local pool = pool_of(game.forces[force_name], skey)
    local tbl
    if readout == "yield" then
      pool.obs[target_key] = pool.obs[target_key] or {control = {n = 0, sum = 0, sumsq = 0}}
      tbl = pool.obs[target_key]
    else
      pool.side[readout] = pool.side[readout] or {}
      pool.side[readout][target_key] = pool.side[readout][target_key] or {control = {n = 0, sum = 0, sumsq = 0}}
      tbl = pool.side[readout][target_key]
    end
    tbl[key] = tbl[key] or {n = 0, sum = 0, sumsq = 0}
    for i = 1, n do
      local wobble = (i % 2 == 0) and 10 or -10
      stats.add(tbl[key], gain + wobble)
      stats.add(tbl.control, wobble)
    end
    pool.changed = pool.changed or {}
    pool.changed[target_key] = storage.evidence_version  -- (as record() does: findings' cache reads it)
    pool.analysed = pool.analysed + n
  end,
  analysis_ticks = function(ticks) storage.analysis_ticks = ticks end,  -- (0.72) the mechanics test's pace
  -- (0.72) The waiting slots re-filtered now (play does it every analysis period).
  station_refilter = function(unit)
    local st = storage.stations[unit]
    if st then reserve_sample_slots(st.entity) end
  end,
  -- (0.72) Every free waiting slot unfiltered, for a test lab that moves samples of several kinds by script.
  samples_migrated = function() return storage.samples_migrated or 0 end,  -- (0.72) old samples made tiered
  -- (0.72) What one more sample of `key` would earn on the evidence `obs` (constructed by a test), without
  -- the force's memory of questions.
  achieved = function(force_name) return storage.achieved and storage.achieved[game.forces[force_name].index] or {} end,
  progress = function(force_name) return storage.progress and storage.progress[game.forces[force_name].index] end,
  progress_now_extra = function(force_name) return storage.extra_total and storage.extra_total[game.forces[force_name].index] or 0 end,
  -- (0.72) A made-up history for the GUI test's screenshot (a short run records none): n snapshots spread over
  -- the time played so far, rising to the force's real totals, red science first and green from halfway.
  progress_seed = function(force_name, n)
    local force = game.forces[force_name]
    local now = progress_now(force)
    storage.progress = storage.progress or {}
    local P = {t = {}, tiers = {}, data = {}, settled = {}, findings = {}}
    for i = 1, n do
      local f = i / (n + 1)
      P.t[i] = math.floor(game.tick * f)
      for pack, count in pairs(now.tiers) do
        P.tiers[pack] = P.tiers[pack] or {}
        P.tiers[pack][i] = math.floor(count * f * f)
      end
      P.data[i] = now.data * math.sqrt(f)
      P.settled[i] = math.floor(now.settled * f)
      P.findings[i] = math.floor(now.findings * f)
      P.dosed = P.dosed or {}; P.extra = P.extra or {}
      P.dosed[i] = math.floor(now.dosed * f)
      P.extra[i] = math.floor(now.extra * f)
    end
    storage.progress[force.index] = P
  end,
  -- (Findings are judged only for forces with players: a headless test asks for it.)
  judge_now = function(force_name)
    local force = game.forces[force_name]
    dossiers.on_judged(force, dossiers.evaluate(force))
  end,
  rate_on = function(obs, target_key, key) return research.rate(1, obs, target_key, key, "es-test-only", nil, true) end,
  -- (0.72) Time what the screen computes on a force's evidence, piece by piece (the complete save froze it).
  profile_screen = function(force_name, skey)
    local force = game.forces[force_name]
    local pool = gui.pool(force, skey or "nauvis")
    local out = {}
    local function time(name, fn)
      local p = game.create_profiler()
      fn()
      p.stop()
      table.insert(out, {name, p})
    end
    local n_cells = 0
    for _, obs in pairs(pool.obs) do for _ in pairs(obs) do n_cells = n_cells + 1 end end
    time("summaries, gear, 5 effects", function()
      for _, e in ipairs(gui.effects) do gui.summaries(pool, "gear", e) end
    end)
    time("research rows, gear, every additive", function()
      for _, a in ipairs(gui.visible_additives(force)) do research.row(force.index, pool.obs.gear, "gear", a.name, skey or "nauvis") end
    end)
    time("research rows, every target x additive (Coverage)", function()
      for key, obs in pairs(pool.obs) do
        for _, a in ipairs(gui.visible_additives(force)) do research.row(force.index, obs, key, a.name, skey or "nauvis") end
      end
    end)
    time("theory cells and fit", function() local c = theory.cells(pool.obs); theory.fit(c) end)
    time("dossiers.evaluate", function() dossiers.evaluate(force) end)
    local lines = {"cells in pool: " .. n_cells}
    for _, row in ipairs(out) do table.insert(lines, {"", row[1], ": ", row[2]}) end
    for _, l in ipairs(lines) do log(l) end
    -- Milliseconds, for a guard: profilers can only be printed, so the same pieces timed again by tick count
    -- would be too coarse; a second pass, cached as a reopened screen is, is what the player waits for.
    return n_cells
  end,
  station_any = function(unit)
    local st = storage.stations[unit]
    if not st then return false end
    st.test_any = true
    reserve_sample_slots(st.entity)
    return true
  end,
  -- (0.72) Additives with evidence in the force's pools that its screen does not list (should be none).
  unlisted_evidence = function(force_name)
    local force = game.forces[force_name]
    local listed, out = {}, {}
    for _, a in ipairs(gui.visible_additives(force)) do listed[a.name] = true end
    for _, pool in pairs(storage.pools[force.index] or {}) do
      for _, cells in pairs(pool.obs or {}) do
        for key, acc in pairs(cells) do
          for part in key:gmatch("[^+]+") do
            local name = part:match("^(.+):%d+$")
            name = name and shared.split_band(name)
            local a = name and shared.additive(name)
            if a and (acc.n or 0) > 0 and not listed[name] and shared.unlocked(force, a) and not a.agent
              and not a.premix_of and a.tier ~= 3 then out[name] = true end
          end
        end
      end
    end
    local list = {}
    for name in pairs(out) do table.insert(list, name) end
    table.sort(list)
    return list
  end,
  chillers = function()  -- (0.71) how many fluid chillers the mod keeps
    local n = 0
    for _ in pairs(storage.chillers or {}) do n = n + 1 end
    return n
  end,
  dose_state = function(unit)
    local d = storage.doses[unit]
    local c = storage.crafters[unit] or storage.benches[unit]
    local hoppers = 0
    if c and c.entity.valid then for _ in pairs(dosing.hoppers_of(c.entity)) do hoppers = hoppers + 1 end end
    return {mix = dosing.mix(unit), status = d and d.status, hoppers = hoppers, settings = dosing.settings(unit)}
  end,
  bridges = function(unit)
    local h, n = storage.hoppers[unit], 0
    for _, obj in ipairs(h and h.bridges or {}) do if obj.valid then n = n + 1 end end
    return n
  end,
  bridge_sprites = function(unit)  -- each joint's sprite, offset from the hopper and layer
    local h, out = storage.hoppers[unit], {}
    for _, obj in ipairs(h and h.bridges or {}) do
      if obj.valid then
        local t = obj.target
        table.insert(out, {sprite = obj.sprite, offset = t and t.offset, layer = obj.render_layer, visible = obj.visible,
          at = t and t.position, tick = obj.id})
      end
    end
    return out
  end,
  chutes = function(unit)
    local h = storage.hoppers[unit]
    local n = 0
    for _, obj in ipairs(h and h.chutes or {}) do if obj.valid then n = n + 1 end end
    return n
  end,
  dose_panel_pick = function(player_index, row, additive)
    local player = game.get_player(player_index)
    dose_gui.on_slot(player, row)
    dose_gui.on_pick(player, additive)
  end,
  dose_panel_click = function(player_index, row, button)
    dose_gui.on_slot(game.get_player(player_index), row, defines.mouse_button_type[button])
  end,
  dose_panel_preset = function(player_index, index) dose_gui.on_preset(game.get_player(player_index), index) end,
  presets = function(force_name) return dosing.presets(game.forces[force_name or "player"]) end,
  -- Blueprint path without a player: the tags a station would carry, and a station built from them.
  port_wire_tags = function(unit) return port_wire_tags(storage.stations[unit], function() return true end) end,
  prune = function() dosing.prune() end,
  add_preset = function(force_name, target_key, mix) return dosing.add_preset(game.forces[force_name], target_key, mix) end,
  sample_worlds = function(n, strength)
    -- World strength: the same draws read at that strength; the noise goes
    -- out in params (balance.py measures with it).
    local ws = shared.world_strength[strength or "standard"]
    truth.set_strength(strength or "standard")
    local worlds = {}
    -- The planets' conditions, from their prototypes (and platforms').
    PLANET_CONDS = {}
    for _, name in ipairs({"vulcanus", "gleba", "fulgora", "aquilo"}) do
      local loc = prototypes.space_location[name]
      if loc then table.insert(PLANET_CONDS, {name = name, cond = truth.condition_of(loc.surface_properties or {})}) end
    end
    if prototypes.surface and prototypes.surface["space-platform"] then
      table.insert(PLANET_CONDS, {name = "space-platform",
        cond = truth.condition_of(prototypes.surface["space-platform"].surface_properties or {})})
    end
    local base = base_responsiveness()
    for i = 1, n do
      local t = truth.generate(game.create_random_generator(scrambled_seed(1000003 * i)), 1000003 * i + 113)
      t.responsiveness = truth.generate_responsiveness(base,
        game.create_random_generator(scrambled_seed(1000003 * i + 29)))
      t.chem = t.chem or truth.generate_chemistry(game.create_random_generator(scrambled_seed(1000003 * i + 7)))
      truth.extend(t, game.create_random_generator(scrambled_seed(1000003 * i + 13)))
      truth.generate_route_responses(t, game.create_random_generator(scrambled_seed(1000003 * i + 23)))
      -- Targets drawn after the first ones (smelting, 0.50), as a map gets them (its stream + 53).
      truth.extend_targets(t, game.create_random_generator(scrambled_seed(1000003 * i + 53)), base)
      truth.extend_registered(t, registered_streams(1000003 * i), base)
      truth.generate_side(t, game.create_random_generator(scrambled_seed(1000003 * i + 31)))
      truth.generate_conditions(t, game.create_random_generator(scrambled_seed(1000003 * i + 67)))
      -- Fluid additives' best temperatures (as a map draws them, its stream + 83): the temperature axis (0.61).
      truth.generate_fluid_temps(t, game.create_random_generator(scrambled_seed(1000003 * i + 83)))
      truth.generate_premix_temps(t, game.create_random_generator(scrambled_seed(1000003 * i + 71)))
      truth.generate_science_richness(t, game.create_random_generator(scrambled_seed(1000003 * i + 137)))
      local ripe = {}
      for _, a in ipairs(shared.additives) do if a.living then ripe[a.name] = truth.ripe_best(t, a.name) end end
      local w = {responsiveness = t.responsiveness, side = t.side, planets = {}, fluid_temp = t.fluid_temp,
        premix_temp = t.premix_temp, ripe_best = ripe, richness = t.richness}
      truth.generate_additive_conditions(t, game.create_random_generator(scrambled_seed(1000003 * i + 79)))
      if shared.quality_on then
        truth.generate_quality(t, game.create_random_generator(scrambled_seed(1000003 * i + 101)))
      end
      truth.generate_efficiency(t, game.create_random_generator(scrambled_seed(1000003 * i + 109)))
      truth.generate_freshness(t, game.create_random_generator(scrambled_seed(1000003 * i + 131)))
      w.promoted = t.promoted or {}  -- (0.70) targets whose early activator the early law supplied
      w.efficiency = {}  -- (0.64: the dossier model reads every readout)
      for _, a in ipairs(shared.additives) do
        if (a.tier == 1 or a.tier == 2) and t.efficiency[a.name] then w.efficiency[a.name] = t.efficiency[a.name] end
      end
      -- Freshness (0.52): per spoilable target, the best tier 1 single by freshness (and its restoration)
      -- and the best by yield; and the largest freshness on any target that does not spoil (must be 0).
      w.fresh, w.fresh_elsewhere = {}, 0
      for _, target in ipairs(shared.targets) do
        local bf, bfn, by, byn = -1, nil, -1e9, nil
        for _, a in ipairs(shared.tier1) do  -- (all five: spoilage is Gleba's, where Tree seeding is in reach)
          for d = 1, shared.max_dose do
            local f = truth.effect_on(t, target.key, {[a.name] = d}, "freshness")
            local g = truth.gain(t, target.key, a.name, d)
            if f > bf then bf, bfn = f, a.name end
            if g > by then by, byn = g, a.name end
          end
        end
        if truth.spoilable(target.key) then
          w.fresh[target.key] = {best = bf, by_fresh = bfn, by_yield = byn}
        else
          w.fresh_elsewhere = math.max(w.fresh_elsewhere, bf)
        end
      end
      -- Planet conditions (0.26): per planet and target, the best Tier 1 single there and on Nauvis.
      for _, pc in ipairs(PLANET_CONDS) do
        local per = {}
        for _, target in ipairs(shared.targets) do
          local bn, bna, bp, bpa = -1e9, nil, -1e9, nil
          for _, a in ipairs(shared.early) do
            for d = 1, shared.max_dose do
              local gn = truth.gain(t, target.key, a.name, d)
              local gp = truth.gain(t, target.key, a.name, d, pc.cond)
              if gn > bn then bn, bna = gn, a.name end
              if gp > bp then bp, bpa = gp, a.name end
            end
          end
          per[target.key] = {nauvis = bn, planet = bp, same = bna == bpa}
        end
        w.planets[pc.name] = per
      end
      -- Quality agents: per agent and target, the best-dose chance, that dose, and its speed cost.
      w.quality = {}
      for _, a in ipairs(shared.agents) do
        w.quality[a.name] = {}
        for _, target in ipairs(shared.targets) do
          local best, best_d = -1, 1
          for d = 1, shared.max_dose do
            local c = truth.quality_chance(t, target.key, {[a.name] = d})
            if c > best then best, best_d = c, d end
          end
          w.quality[a.name][target.key] = {chance = best, dose = best_d,
            speed = truth.effect_on(t, target.key, {[a.name] = best_d}, "speed"),
            yield = truth.gain_on(t, target.key, {[a.name] = best_d})}
        end
      end
      for _, target in ipairs(shared.targets) do
        w[target.key] = {}
        for _, a in ipairs(shared.additives) do
          if a.premix_of then goto next_additive end  -- premixes: a compact summary below
          local r = t.targets[target.key][a.name]
          local gains = {}
          for d = 1, a.max_dose do gains[d] = truth.gain(t, target.key, a.name, d) end
          -- A living additive at its best ripeness, where a player doses it (0.70; the model read it fresh,
          -- up to four times weaker); its fresh gains kept beside.
          local fresh
          if a.living then
            fresh, gains = gains, {}
            local ripe = truth.ripe_best(t, a.name)
            for d = 1, a.max_dose do gains[d] = truth.gain_on(t, target.key, {[a.name] = d}, nil, {[a.name] = ripe}) end
          end
          -- Speed, pollution and efficiency on this target at full presence, times its responsiveness,
          -- before the game's caps (0.70: the model reads them here instead of copying the formula).
          local k = t.responsiveness and t.responsiveness[target.key] or 1
          local sp, po, ef = truth.side_base(t, target.key, a.name)
          w[target.key][a.name] = {kind = r.kind, shape = truth.shape_of(t, target.key, a.name, r), peak = r.peak,
            opt = r.opt, gains = gains, family = shared.mix_family(a.name),
            tier = a.tier, fluid = a.fluid or false, side = {k * sp, k * po, k * ef},
            early = shared.is_early(a.name), unlock = a.unlock or false, gains_fresh = fresh}
          ::next_additive::
        end
        -- Premixes (first 300 worlds, like mixtures): per target, the best (stable) premix and its dose,
        -- and the median of every premix's best gain (what a random unlock tends to give).
        if i <= 300 then
          local pbest, pdose, bests = -1e9, 0, {}
          for _, a in ipairs(shared.premixes) do
            local own = -1e9
            for d = 1, a.max_dose do
              local g = truth.gain(t, target.key, a.name, d)
              if g > own then own = g end
              if g > pbest then pbest, pdose = g, d end
            end
            table.insert(bests, own)
          end
          table.sort(bests)
          w.premix = w.premix or {}
          w.premix[target.key] = {gain = pbest, dose = pdose, typical = bests[math.ceil(#bests / 2)]}
          -- The frontier (0.70, rule F1): the best yield at the usual temperature (every single additive,
          -- living ones at their ripeness, and every premix), and the best with each fluid additive and
          -- liquid premix at its best temperature.
          local usual = pbest
          for _, c in pairs(w[target.key]) do
            for _, g in ipairs(c.gains or {}) do if g > usual then usual = g end end
          end
          local frontier, fname, fdose, ftemp = usual, nil, nil, nil
          for _, a in ipairs(shared.additives) do
            local temp = a.fluid and not a.volatile
              and ((t.premix_temp and t.premix_temp[a.name]) or (t.fluid_temp and t.fluid_temp[a.name]))
            if temp then
              local step = a.max_dose > shared.max_dose and 10 or 1
              for d = step, a.max_dose, step do
                local g = truth.gain(t, target.key, a.name, d, nil, temp)
                if g > frontier then frontier, fname, fdose, ftemp = g, a.name, d, temp end
              end
            end
          end
          w.frontier = w.frontier or {}
          -- (and what makes it: the fluid, its dose and temperature, its heat capacity in kJ per unit and degree)
          local hc = fname and prototypes.fluid[fname] and prototypes.fluid[fname].heat_capacity / 1000 or nil
          w.frontier[target.key] = {usual = usual, frontier = frontier, name = fname, dose = fdose, temp = ftemp, hc = hc}
        end
        -- Best net ore per product by kind (first 300 worlds): gain minus the dose's ore over the batch's
        -- (research.tau, the mod's own break-even), best dose; fluids every 10 units. For the balance
        -- model's rules on tier 2 coverage and premixes against catalysts (decided 2026-10-02).
        if i <= 300 then
          -- Each dose's gain and side effects are computed once, then priced three ways (net ore, and the
          -- full cost at each price set): the sampler's slowest part, computed three times before 0.48.
          local function has_catalyst(a)
            return shared.additive(a.premix_of[1]).refined_from or shared.additive(a.premix_of[2]).refined_from
          end
          local best = {tier1 = -1e9, tier2 = -1e9, residue = -1e9, catalyst = -1e9, premix = -1e9, cat_premix = -1e9}
          -- (0.68) The same with each residue a dose leaves credited at its own ore (rule R1: activation can
          -- use it; spoilage never credited, it has no activation).
          local cbest = {tier1 = -1e9, tier2 = -1e9, residue = -1e9, catalyst = -1e9, premix = -1e9, cat_premix = -1e9}
          local fbest = {}
          for set in pairs(shared.prices) do
            fbest[set] = {tier1 = -1e9, tier2 = -1e9, residue = -1e9, catalyst = -1e9, premix = -1e9, cat_premix = -1e9}
          end
          for _, a in ipairs(shared.additives) do
            local kind = a.premix_of and (not a.volatile and (has_catalyst(a) and "cat_premix" or "premix"))
              or a.refined_from and "catalyst"
              -- ("tier1" is the early set since 0.70; wood, gated, counts with the later additives.)
              or a.residue_of and "residue" or (shared.is_early(a.name) and "tier1")
              or ((a.tier == 1 or a.tier == 2) and "tier2")
            if kind then
              local step = a.fluid and 10 or 1
              for d = step, a.max_dose, step do
                local mix = {[a.name] = d}
                local g = truth.gain_on(t, target.key, mix)
                local net = g - research.tau(target.key, mix) / 1000
                if net > best[kind] then best[kind] = net end
                local credit = 0
                for r, share in pairs(shared.residue_shares(a.name)) do
                  if r ~= "spoilage" then credit = credit + share * research.tau(target.key, {[r] = d}) / 1000 end
                end
                if net + credit > cbest[kind] then cbest[kind] = net + credit end
                local sp, pp, ef = truth.effect_on(t, target.key, mix, "speed"),
                  truth.effect_on(t, target.key, mix, "pollution"), truth.effect_on(t, target.key, mix, "efficiency")
                for set, P in pairs(shared.prices) do
                  local saving = research.full_saving(target.key, mix, g, sp, pp, ef, P)
                  if saving and saving > fbest[set][kind] then fbest[set][kind] = saving end
                end
              end
            end
          end
          w.net = w.net or {}
          w.net[target.key] = best
          w.net_credited = w.net_credited or {}
          w.net_credited[target.key] = cbest
          -- The same kinds by full cost: the fraction of the vanilla product's cost
          -- (ore + machine time + power + pollution, priced) a dose saves, best dose, at each price set.
          w.full = w.full or {early = {}, late = {}}
          for set in pairs(shared.prices) do
            if fbest[set].tier1 > -1e9 then w.full[set][target.key] = fbest[set] end  -- targets with a recipe only
          end
        end
      end
      -- Mixtures, on the first 300 worlds: best single (tier 1), best tier 1 pair over every dose
      -- combination, and the naive stack (the two best singles, each at its own best dose).
      if i <= 300 then
        w.mix = {}
        for _, target in ipairs(shared.targets) do
          local best = {}
          for _, a in ipairs(shared.early) do
            local bd, bg = 1, -1e9
            for d = 1, shared.max_dose do
              local g = truth.gain(t, target.key, a.name, d)
              if g > bg then bd, bg = d, g end
            end
            table.insert(best, {name = a.name, dose = bd, gain = bg})
          end
          table.sort(best, function(x, y) return x.gain > y.gain end)
          local pair_best = -1e9
          for x = 1, #shared.early do
            for y = x + 1, #shared.early do
              local an, bn = shared.early[x].name, shared.early[y].name
              for da = 1, shared.max_dose do
                for db = 1, shared.max_dose do
                  local mix = {[an] = da, [bn] = db}
                  local g = truth.gain_mix(t, target.key, mix)
                  if g > pair_best then pair_best = g end
                end
              end
            end
          end
          w.mix[target.key] = {single = best[1].gain, pair = pair_best,
            naive = truth.gain_mix(t, target.key, {[best[1].name] = best[1].dose, [best[2].name] = best[2].dose})}
        end
      end
      worlds[i] = w
    end
    -- Trial ingredients, time and survivors as built in the data stage (read from the prototypes).
    local targets = {}
    for _, target in ipairs(shared.targets) do
      local r = prototypes.recipe[shared.trial_recipe(target.key)]
      local ingredients, survivors = {}, 0
      -- World strength: the prototypes carry the startup setting's trial cost; rescale to the sampled one.
      local vr = prototypes.recipe[shared.target_recipe(target)]
      local out = 1
      for _, p in pairs(vr.products) do if p.name == target.result then out = p.amount end end
      local base = target.batch / out
      local scale = shared.trial_crafts(base, strength) / shared.trial_crafts(base, settings.startup["es-world-strength"].value)
      for _, ing in pairs(r.ingredients) do table.insert(ingredients, {ing.name, ing.amount * scale}) end
      for _, res in pairs(r.products) do if res.name == target.result then survivors = res.amount end end
      targets[target.key] = {result = target.result, batch = target.batch, survivors = survivors,
        trial_time = r.energy * scale, ingredients = ingredients, pack = storage.target_pack[target.key],
        process = target.process}
    end
    truth.set_strength(strength_of_map())
    return {worlds = worlds, params = {noise_sd = shared.noise_sd * ws.noise, max_dose = shared.max_dose,
      pressure_charge = shared.pressure_charge, cold_charge = shared.cold_charge,
      residues = (function()  -- (0.68) what each additive leaves, for the balance model's credited view
        local out = {}
        for _, a in ipairs(shared.all_additives) do out[a.name] = shared.residues_of(a.name) end
        return out
      end)(),
      residue_shares = (function()  -- (0.70) per unit dosed: a slurry leaves a share
        local out = {}
        for _, a in ipairs(shared.all_additives) do out[a.name] = shared.residue_shares(a.name) end
        return out
      end)(),
      -- (0.64, the dossier model) the other readouts' noise, at this strength; efficiency shares speed's.
      noise_side = {speed = shared.noise_speed * ws.noise, cleanliness = shared.noise_pollution * ws.noise,
        efficiency = shared.noise_speed * ws.noise, freshness = shared.noise_freshness * ws.noise},
      world_strength = strength or "standard", trial_cost = ws.trial_cost, scrap = shared.scrap,
      -- (0.72) The hidden world's size for the mod page (docs/balance.py, The size of the hidden world): how
      -- many temperature and ripeness bands evidence is kept in, and how many additives a machine takes.
      world_size = {temp_bands = (function()
          local seen, n = {}, 0
          for T = shared.temp_axis.min, shared.temp_axis.max do
            local band = shared.temp_band(T)
            if not seen[band] then seen[band], n = true, n + 1 end
          end
          return n
        end)(), ripe_bands = shared.ripe.bands, mix_rows = shared.hopper.rows},
      temp_axis = {cold = shared.premix.cold, hot = shared.premix.hot, width = truth.premix_temp_width,
        defaults = (function()
          local out = {}
          for _, a in ipairs(shared.additives) do
            if a.fluid and not a.premix_of and prototypes.fluid[a.name] then out[a.name] = prototypes.fluid[a.name].default_temperature end
          end
          return out
        end)()},
      conditions_sd = truth.conditions_sd,
      stages = shared.stages, agents = shared.agents,
      quality_min_units = shared.quality_min_units,
      samples_per_pack = ws.samples_per_pack,
      analysis_ticks = shared.analysis_ticks,
      batch_ore = shared.batch_ore, data = shared.data, refine = shared.refine,
      families = (function()
        local f = {}
        for _, a in ipairs(shared.additives) do if not a.premix_of then f[a.name] = a.family end end
        return f
      end)(),
      targets = targets}}
  end,
  discovered = function(force_name) return storage.discovered[game.forces[force_name].index] or {} end,
  gain_mix = function(target_key, mix) return truth.gain_mix(storage.truth, target_key, mix) end,
  gain_on = function(key, mix) return truth.gain_on(storage.truth, key, mix) end,
  effect_on = function(key, mix, effect) return truth.effect_on(storage.truth, key, mix, effect) end,
  gain_scale = function(target_key, additive) return truth.scale(storage.truth, target_key, additive) end,
  pair_strength = function(a, b)
    return truth.pair_strength(storage.truth, shared.additive(a).family, shared.additive(b).family)
  end,
  fit_surface_points = function(points)
    local fit, why = regress.fit_surface(points)
    if not fit then return {error = why} end
    fit.surface = nil
    return fit
  end,
  interaction = function(unit, target_key, mix_key, a_key, b_key)
    local st = storage.stations[unit]
    local obs = pool_of(st.entity.force, surface_key(st.entity.surface)).obs[target_key]
    local function s(k) return stats.summary(obs[k] or {n = 0, sum = 0, sumsq = 0}) end
    return regress.interaction(s(mix_key), s(a_key), s(b_key), s("control"))
  end,
  p_two = stats.p_two,
  t_crit = stats.t_crit,
  f_upper = stats.f_upper,
  wilson = stats.wilson,
  welch = stats.welch,
})
end
