-- Headless integration test. Builds a lab on map creation, runs, asserts, writes results.
-- Benches and machines are dosed from hoppers (scripts/dosing.lua); the test fills the hoppers,
-- carries samples from chests to the station (standing in for belts), feeds packs, and checks what
-- the station concludes and what production makes.
local END_TICK = 36000
local GREEN_FROM = 18000          -- green packs arrive halfway: engine samples wait until then
local OUT = "es-test-results.txt"
local es = function(fn, ...) return remote.call("empirical-science", fn, ...) end
-- One handler per interval: registering a second one for an interval replaces the first, silently (an
-- animation probe on 301 once disabled the platform test's sample carrier).
local taken_intervals = {}
local function on_nth_tick(n, f)
  if taken_intervals[n] then error("es-test: two handlers for on_nth_tick(" .. tostring(n) .. ")") end
  taken_intervals[n] = true
  script.on_nth_tick(n, f)
end
local N = defines.direction.north

local lines, failed = {}, 0
local failed_names = {}
local function check(name, ok, detail)
  if not ok then failed = failed + 1; table.insert(failed_names, name) end
  table.insert(lines, (ok and "PASS " or "FAIL ") .. name .. (detail ~= nil and ("  " .. tostring(detail)) or ""))
end
local function info(s) table.insert(lines, "INFO " .. s) end

local function place(name, x, y, dir, surface)
  local e = (surface or game.surfaces.nauvis).create_entity{name = name, position = {x, y},
    force = "player", raise_built = true, direction = dir}
  if not e then error("could not place " .. name .. " at " .. x .. "," .. y) end
  return e
end

-- Batch and survivors are the mod's (shared.lua and the trial prototype), never typed here.
local shared = require("__empirical-science__.shared")
local RICHNESS = {standard = require("__empirical-science__.scripts.richness_standard"),
  harsh = require("__empirical-science__.scripts.richness_harsh")}
local RED_SAMPLE = shared.sample_of("automation-science-pack")  -- (0.72: one sample item per science pack)
-- A constant combinator's signals: {{type, name, value}...}.
local function set_cc(cc, list)
  local cb = cc.get_or_create_control_behavior()
  local sec = cb.get_section(1) or cb.add_section()
  local filters = {}
  for _, x in ipairs(list) do table.insert(filters, {value = {type = x[1], name = x[2], quality = "normal"}, min = x[3]}) end
  sec.filters = filters
end
local function wire(a, b)
  local red = defines.wire_connector_id.circuit_red
  a.get_wire_connector(red, true).connect_to(b.get_wire_connector(red, true))
end

local GEAR_BATCH = shared.target("gear").batch
local function gear_survivors()
  for _, p in pairs(prototypes.recipe["es-trial-gear-control"].products) do
    if p.name == "iron-gear-wheel" then return p.amount end
  end
  return 0
end

-- A fluid additive (vanilla fluids and liquid premixes alike): the mod's own definition.
local function is_fluid(name) local a = shared.additive(name); return a and a.fluid or false end
local FLUIDS = {water = true, ["crude-oil"] = true, ["heavy-oil"] = true, ["light-oil"] = true,
  ["petroleum-gas"] = true, lubricant = true, ["sulfuric-acid"] = true}
local TIER1 = {coal = true, wood = true, stone = true, ["stone-brick"] = true, ["copper-cable"] = true}

local function rows_of(doses)
  local rows = {}
  for name, dose in pairs(doses) do table.insert(rows, {name = name, dose = dose}) end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows
end

-- A fluid hopper (0.71: 1x2, as the pump): its near tile at (x, y), touching the machine, the other one step
-- (dx, dy) away; returns it and where a pipe meets its far end.
local function fluid_hopper(x, y, dx, dy)
  local tx, ty = math.floor(x) + 0.5, math.floor(y) + 0.5
  local e = place("es-fluid-hopper", tx + dx * 0.5, ty + dy * 0.5, dx ~= 0 and defines.direction.east or defines.direction.north)
  return e, tx + dx * 2, ty + dy * 2
end

-- An infinity pipe holding a fluid, at a fluid hopper's end.
local function fluid_source(x, y, fluid)
  local p = place("infinity-pipe", x, y)
  p.set_infinity_pipe_filter{name = fluid, percentage = 1, temperature = fluid == "water" and 15 or 25}
  return p
end

-- Bench (3x3) at (x, y), a hopper on its top edge, an inserter taking its output south into a chest.
-- `doses` {name = dose} are set in the bench's panel; a fluid comes by a fluid hopper on the top edge's right
-- tile (0.71; the bench's own fluid input is on the left), from an infinity pipe above it.
local function rig(x, y, recipe, doses)
  local b = place("es-test-bench", x, y)
  b.set_recipe(recipe)
  -- (0.72: a bench takes a fluid ingredient in the middle of its top edge; its hopper moves left of it.)
  local h = place("es-hopper", recipe:find("plastic") and x - 1 or x, y - 2)
  place("fast-inserter", x, y + 2, N)
  local r = {entity = b, hopper = h, chest = place("iron-chest", x, y + 3), doses = doses, trials = 0, untagged = 0,
    items = {}, spent = 0, keys = {}}
  if doses then
    es("set_dose", b.unit_number, {rows = rows_of(doses)})
    for name in pairs(doses) do
      if is_fluid(name) then
        local fx, fy
        if not r.fluid_hopper then r.fluid_hopper, fx, fy = fluid_hopper(x + 1, y - 2, 0, -1); r.fluid_end = {fx, fy} end
        fluid_source(r.fluid_end[1], r.fluid_end[2], name)
      end
    end
  end
  return r
end

-- Production machine (3x3) at (x, 12) running `recipe`, with a hopper on its top edge unless told not to, and
-- for a fluid dose a fluid hopper on that edge's right tile (assembling machines take fluid in the middle).
local function machine(name, x, recipe, doses, opts)
  opts = opts or {}
  local m = place(name, x, 12)
  if recipe then m.set_recipe(recipe, opts.quality) end
  local h = not opts.no_hopper and place("es-hopper", x, 10) or nil
  local r = {entity = m, hopper = h, doses = doses, made = 0, by_quality = {}, taken = {}, spent = 0,
    fill = not opts.empty, crafts = 0}
  if doses then
    es("set_dose", m.unit_number, {rows = rows_of(doses)})
    for fname in pairs(doses) do
      if is_fluid(fname) and h then
        if not r.fluid_hopper then
          local fx, fy
          r.fluid_hopper, fx, fy = fluid_hopper(x + 1, 10, 0, -1)
          r.fluid_end = {fx, fy}
        end
        fluid_source(r.fluid_end[1], r.fluid_end[2], fname)
      end
    end
  end
  return r
end

-- The strongest tier 1 activator for gears on this map, for the sweep and production rigs.
local function gear_activator()
  local best, best_peak
  for name, r in pairs(es("truth").targets.gear) do
    if TIER1[name] and r.kind == "activator" and (not best_peak or r.peak > best_peak) then best, best_peak = name, r.peak end
  end
  return best
end

script.on_init(function()
  -- This lab was built for stations reading a sample every half second (0.72: every 5 s); it keeps that pace
  -- here, and the kit and the playthrough run at the real one.
  es("analysis_ticks", 10)  -- (0.72: and 10, not 30, since a station holds only four waiting: the rigs together
                            -- make more than two samples a second)
  -- Trials unlock with their target's technology.
  for _, tech in ipairs({"es-empirical-method", "electronics", "engine", "quality-module", "steel-processing", "plastics", "carbon-fiber",
                           "es-mixtures", "es-thermal-studies"}) do
    -- (Some exist only with Quality or Space Age: ES_BASE_ONLY=1 runs without them.)
    if game.forces.player.technologies[tech] then game.forces.player.technologies[tech].researched = true end
  end
  -- The lab doses wood, which waits for Tree seeding on new maps (0.70, Space Age only).
  if prototypes.technology["tree-seeding"] then game.forces.player.technologies["tree-seeding"].researched = true end
  -- Side effects and circuit mode open with Precision instruments 1 and Circuit instrumentation 1, whose
  -- other effects (noise, the O signal) are checked on their own: the pre-staging grant opens them here.
  es("set_legacy_stages", "player", true)
  local s = game.surfaces.nauvis
  s.request_to_generate_chunks({0, 0}, 4)
  s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities_filtered{area = {{-60, -60}, {90, 60}}}) do e.destroy() end
  local tiles = {}
  for x = -60, 89 do for y = -60, 59 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
  s.set_tiles(tiles)
  place("electric-energy-interface", -10, 10)
  for x = -10, 70, 6 do place("substation", x, 6) end
  for x = -10, 70, 6 do place("substation", x, -8) end

  storage.station = place("es-analysis-station", 0, 20)
  -- A second station for the premix benches: one station analyses two samples a second.
  storage.station2 = place("es-analysis-station", 20, 20)
  -- (0.72) This lab moves samples of several kinds into each station by script: the layout before 0.72.
  es("station_any", storage.station.unit_number)
  es("station_any", storage.station2.unit_number)
  do
    local gas = place("infinity-pipe", 55, -16)
    gas.set_infinity_pipe_filter{name = "petroleum-gas", percentage = 1, temperature = 25}
  end

  -- Alerts: a station with a sample and no packs says so; one with its pack does not.
  local function tagged_sample(inv)
    inv.insert{name = RED_SAMPLE, count = 1}
    inv.find_item_stack(RED_SAMPLE).tags = {target = "gear", route = "", additive = "", dose = 0, y = 100, sp = 100,
      pp = 100, pack = "automation-science-pack", v = 3}
  end
  storage.alert_starved = place("es-analysis-station", 100, 30)
  tagged_sample(storage.alert_starved.get_inventory(defines.inventory.chest))
  storage.alert_fed = place("es-analysis-station", 106, 30)
  local fed = storage.alert_fed.get_inventory(defines.inventory.chest)
  tagged_sample(fed)
  fed.insert{name = "automation-science-pack", count = 1}
  -- A station holding one uncommon red pack and one plain control sample: it must take the pack.
  storage.qstation = place("es-analysis-station", 60, 50)
  local qinv = storage.qstation.get_inventory(defines.inventory.chest)
  storage.quality_pack_inserted = qinv.insert{name = "automation-science-pack", count = 1, quality = "uncommon"}
  qinv.insert{name = RED_SAMPLE, count = 1}
  local qs = qinv.find_item_stack(RED_SAMPLE)
  qs.tags = {target = "gear", route = "", additive = "", dose = 0, y = 100, sp = 100, pp = 100,
    pack = "automation-science-pack", v = 3}
  local a = gear_activator()
  storage.activator = a
  -- Row 0: single additives on gears, a control, engines (green packs), circuit mode, a dose sweep,
  -- route trials, fluids.
  storage.rigs = {
    control = rig(0, 0, "es-trial-gear-control"),
    coal = rig(5, 0, "es-trial-gear-control", {coal = 3}),
    stone = rig(10, 0, "es-trial-gear-control", {stone = 5}),
    wood = rig(15, 0, "es-trial-gear-control", {wood = 5}),
    cable = rig(20, 0, "es-trial-gear-control", {["copper-cable"] = 4}),
    engine = rig(25, 0, "es-trial-engine-control", {coal = 2}),
    circuit = rig(30, 0, "es-trial-circuit-control"),
    sweep = rig(35, 0, "es-trial-gear-control", {[a] = 1}),
    -- A fluid-fed target (0.25): petroleum gas into the bench's top-left fluid input.
    plastic = rig(55, -14, "es-trial-plastic-control"),
    lub = rig(45, 0, "es-trial-gear-control", {lubricant = 40}),
    sulfur = rig(50, 0, "es-trial-gear-control", {sulfur = 3}),
    -- Row -14: two fluids from two hoppers, the 2x2 mixture, residue and refined catalyst, and a bench
    -- whose hopper is never filled (its samples must say control).
    two = rig(0, -14, "es-trial-gear-control", {lubricant = 30}),
    mix = rig(5, -14, "es-trial-gear-control", {lubricant = 40, sulfur = 3}),
    residue = rig(10, -14, "es-trial-gear-control", {["es-spent-stone"] = 5}),
    refined = rig(15, -14, "es-trial-gear-control", {["es-refined-stone"] = 2}),
    honest = rig(20, -14, "es-trial-gear-control", {sulfur = 3}),
  }
  storage.rigs.honest.no_fill = true
  -- Premixes (slice 3): the pair of tier 1 additives from different families with the strongest true
  -- synergy on gears at dose 5 each, run as a 2x2 (mixture, each alone, and the control rig).
  local T1F = {coal = "carbon", wood = "organic", stone = "mineral", ["copper-cable"] = "metal"}
  local best_i, pa, pb = -1, nil, nil
  for x in pairs(T1F) do
    for y in pairs(T1F) do
      if x < y then
        local inter = es("gain_mix", "gear", {[x] = 5, [y] = 5}) - es("gain", "gear", x, 5) - es("gain", "gear", y, 5)
        if inter > best_i then best_i, pa, pb = inter, x, y end
      end
    end
  end
  storage.premix_pair = {a = pa, b = pb, inter = best_i, fa = T1F[pa], fb = T1F[pb]}
  storage.rigs.pair_mix = rig(30, -14, "es-trial-gear-control", {[pa] = 5, [pb] = 5})
  storage.rigs.pair_a = rig(35, -14, "es-trial-gear-control", {[pa] = 5})
  storage.rigs.pair_b = rig(40, -14, "es-trial-gear-control", {[pb] = 5})
  storage.rigs.pair_control = rig(50, -14, "es-trial-gear-control")
  storage.premix_locked_before = true
  -- A machine with no room for residues (fed by its own handler, not tended; 0.65): no output inserter,
  -- its trash slots full of wood, so its stone dose must wait.
  -- Rigs east of the cleared area: clear their ground first (trees, rocks, water on some maps).
  do
    local surf = game.surfaces.nauvis
    for _, e in pairs(surf.find_entities_filtered{area = {{74, -35}, {96, -21}}}) do
      if e.type ~= "character" then e.destroy() end
    end
    local tiles = {}
    for x = 74, 95 do for y = -35, -22 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
    surf.set_tiles(tiles)
  end
  local sf = rig(77, -30, "es-trial-gear-control", {stone = 5})  -- powered by the substation at (70, -24)
  local gone = 0
  for _, e in pairs(game.surfaces.nauvis.find_entities_filtered{name = "fast-inserter", area = {{76, -29}, {78, -27}}}) do
    e.destroy(); gone = gone + 1
  end
  if gone ~= 1 then error("es-test layout: the residue rig's output inserter was not found (" .. gone .. ")") end
  local trash = sf.entity.get_inventory(defines.inventory.crafter_trash)
  for i = 1, #trash do trash[i].set_stack{name = "wood", count = 100} end
  sf.hopper.get_inventory(defines.inventory.chest).insert{name = "stone", count = 50}
  storage.spent_rig = sf
  -- Where residues go (0.65): a bench dosed with a mixture from a coal hopper (top) and a stone hopper
  -- (left) sends both residues out through its output inserter; the hoppers get none. On free ground only
  -- (create_entity does not check).
  local function free(name, x, y)
    local s = game.surfaces.nauvis
    if not s.can_place_entity{name = name, position = {x, y}, force = "player"} then
      error("es-test layout: " .. name .. " at " .. x .. "," .. y .. " would overlap")
    end
    return place(name, x, y)
  end
  free("substation", 86, -24)
  local function two_hopper_bench(x)
    local b = free("es-test-bench", x, -30)
    b.set_recipe("es-trial-gear-control")
    local r = {entity = b, coal = free("es-hopper", x, -32), stone = free("es-hopper", x - 2, -30), residues = {}}
    free("fast-inserter", x, -28, N)
    r.chest = free("iron-chest", x, -27)
    es("set_dose", b.unit_number, {rows = rows_of({coal = 3, stone = 5})})
    return r
  end
  storage.mix_rig = two_hopper_bench(92)
  -- Circuit interface (0.49): a station whose target and page a constant combinator sets (its window
  -- says circuits, the wire says gears), and a bench whose recipe a circuit sets (vanilla set recipe).
  do
    free("substation", 44, 44)
    local cst = free("es-analysis-station", 40, 40)
    es("station_any", cst.unit_number)
    local cc = free("constant-combinator", 36, 40)
    wire(cc, cst)
    es("set_view_target", cst.unit_number, "circuit")
    -- Its port reads its own history, seeded so the rankings disagree: coal at 3 has the higher mean
    -- (two wild samples), coal at 5 the higher lower bound (thirty tight ones); an agent is in it too.
    es("set_port_source", cst.unit_number, "station")
    local function series(mean, spread, n)
      local v = {}
      for i = 1, n do v[i] = mean + spread * ((i % 2 == 0) and 1 or -1) end
      return v
    end
    es("seed_history", cst.unit_number, "gear", "control", series(0, 10, 20))
    es("seed_history", cst.unit_number, "gear", "coal:3", {200, 40})
    es("seed_history", cst.unit_number, "gear", "coal:5", series(60, 5, 30))
    if shared.agents[1] then es("seed_history", cst.unit_number, "gear", shared.agents[1].name .. ":2", series(5, 5, 4)) end
    -- (0.72, the Screening page's selected dose) Stone: settled at 1, still open at 4, so its most open dose is neither its lowest nor
    -- its best by lower bound. Both stay below coal at 5 by lower bound (pages 3 and 5).
    es("seed_history", cst.unit_number, "gear", "stone:1", series(-40, 3, 20))
    es("seed_history", cst.unit_number, "gear", "stone:4", {150, 10, 90})
    -- The target by recipe signal; an item signal never names one (plastic bars are both).
    set_cc(cc, {{"recipe", "iron-gear-wheel", 1}, {"item", "plastic-bar", 5}, {"virtual", "es-page", 1}})
    local bb = free("es-test-bench", 50, 40)
    local cc2 = free("constant-combinator", 54, 40)
    wire(cc2, bb)
    bb.get_or_create_control_behavior().circuit_set_recipe = true
    -- Set recipe takes only recipes the force has (trials unlock with their technology).
    game.forces.player.recipes["es-trial-red-control"].enabled = true
    set_cc(cc2, {{"recipe", "es-trial-red-control", 1}})
    storage.circ = {station = cst, cc = cc, bench = bb}
  end
  -- A quality agent (with the quality mod) at its true best dose on gears: samples count upgrades.
  if shared.quality_on and shared.agents[1] then
    local agent, best_d, best_c = shared.agents[1].name, 1, -1
    for d = 1, shared.max_dose do
      local c = es("quality_chance", "gear", {[agent] = d})
      if c > best_c then best_d, best_c = d, c end
    end
    -- Outside the cleared area: clear the ground first (trees, rocks, water on some maps).
    local surf = game.surfaces.nauvis
    for _, e in pairs(surf.find_entities_filtered{area = {{96, -35}, {106, -21}}}) do
      if e.type ~= "character" then e.destroy() end
    end
    local tiles = {}
    for x = 96, 105 do for y = -35, -22 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
    surf.set_tiles(tiles)
    free("substation", 102, -24)
    local b = free("es-test-bench", 100, -30)
    b.set_recipe("es-trial-gear-control")
    local r = {entity = b, hopper = free("es-hopper", 100, -32), doses = {[agent] = best_d}, trials = 0, untagged = 0,
      items = {}, spent = 0, keys = {}}
    free("fast-inserter", 100, -28, N)
    r.chest = free("iron-chest", 100, -27)
    es("set_dose", b.unit_number, {rows = rows_of({[agent] = best_d})})
    storage.rigs.agent = r
    storage.agent = {name = agent, dose = best_d, chance = best_c}
  end
  -- A premix dosed on a bench (supplied by the test), to check its estimate against the truth.
  storage.rigs.premix = rig(45, -14, "es-trial-gear-control", {["es-premix-coal-stone"] = 2})
  for _, name in ipairs({"pair_mix", "pair_a", "pair_b", "pair_control", "premix"}) do storage.rigs[name].station2 = true end
  -- The two-fluid bench: water from a second fluid hopper on its right edge (one fluid per hopper).
  local _, wx, wy = fluid_hopper(2, -14, 1, 0)
  fluid_source(wx, wy, "water")
  es("set_dose", storage.rigs.two.entity.unit_number, {rows = rows_of({lubricant = 30, water = 20})})
  -- Circuit mode: a combinator sends stone = 4 to the circuit bench; its panel rows are ignored.
  local comb = place("constant-combinator", 32, -3)
  comb.get_or_create_control_behavior().get_section(1).filters =
    {{value = {type = "item", name = "stone", quality = "normal"}, min = 4}}
  storage.rigs.circuit.entity.get_wire_connector(defines.wire_connector_id.circuit_red, true)
    .connect_to(comb.get_wire_connector(defines.wire_connector_id.circuit_red, true))
  es("set_dose", storage.rigs.circuit.entity.unit_number, {rows = rows_of({coal = 9}), circuit = true})
  storage.rigs.circuit.doses = {stone = 4}
  storage.discovery_before = game.forces.player.recipes["es-refine-stone"].enabled

  -- A losing effect with instant pickup (0.72: an additive's, since alternative recipes are retired): the most
  -- harmful early dose on gears, its output emptied by a real inserter as soon as products appear, so the loss
  -- must come out of the inputs.
  local worst, worst_g = nil, 0
  for _, name in ipairs({"coal", "wood", "stone", "stone-brick", "copper-cable"}) do
    for d = 1, shared.max_dose do
      local g = es("gain_mix", "gear", {[name] = d})
      if g < worst_g then worst, worst_g = {name = name, dose = d}, g end
    end
  end
  local nasm = place("assembling-machine-2", -12, 0)
  nasm.set_recipe("iron-gear-wheel")
  place("fast-inserter", -12, 2, N)
  if worst then
    local nh = place("es-hopper", -12, -2)
    nh.get_inventory(defines.inventory.chest).insert{name = worst.name, count = 1000}
    es("set_dose", nasm.unit_number, {rows = rows_of({[worst.name] = worst.dose})})
  end
  storage.neg_rig = {entity = nasm, chest = place("iron-chest", -12, 3), worst = worst, gain = worst_g, fed = {}, gears = 0}

  -- Production (row y = 12): the activator at its best dose on the vanilla gear recipe; at uncommon
  -- quality; with quality modules; two machines sharing one hopper; a machine with no hopper and one
  -- with an empty hopper; a mixture with a fluid on circuits; steel in
  -- a furnace. A probe runs vanilla gears with modules and no dose.
  local best_d, best_g = 1, -1
  for d = 1, 9 do local g = es("gain", "gear", a, d); if g > best_g then best_d, best_g = d, g end end
  storage.best_dose = best_d
  local P = {}
  P.ind = machine("assembling-machine-2", 10, "iron-gear-wheel", {[a] = best_d})
  P.quality = machine("assembling-machine-2", 15, "iron-gear-wheel", {[a] = best_d}, {quality = "uncommon"})
  P.module = machine("assembling-machine-2", 20, "iron-gear-wheel", {[a] = best_d})
  P.module.entity.get_inventory(defines.inventory.crafter_modules).insert{name = "quality-module-3", count = 2}
  P.probe = machine("assembling-machine-2", 25, "iron-gear-wheel", nil, {no_hopper = true})
  P.probe.entity.get_inventory(defines.inventory.crafter_modules).insert{name = "quality-module-3", count = 2}
  P.pair_a = machine("assembling-machine-2", 30, "iron-gear-wheel", {[a] = best_d}, {no_hopper = true})
  P.pair_b = machine("assembling-machine-2", 34, "iron-gear-wheel", {[a] = best_d}, {no_hopper = true})
  storage.shared_hopper = place("es-hopper", 32, 12)  -- touches both
  P.none = machine("assembling-machine-2", 40, "iron-gear-wheel", {[a] = best_d}, {no_hopper = true})
  P.empty = machine("assembling-machine-2", 45, "iron-gear-wheel", {[a] = best_d}, {empty = true})
  P.mixture = machine("assembling-machine-2", 55, "electronic-circuit", {sulfur = 3, lubricant = 40})
  P.steel = machine("electric-furnace", 60, nil, {coal = 3})
  -- A hopper filled by an inserter (0.65: to the top; residues leave by the machine, not the hopper).
  P.full = machine("assembling-machine-2", 65, "iron-gear-wheel", {[a] = best_d}, {empty = true})
  -- Hopper reports (0.49): the fed machine's hopper and the empty one's.
  es("hopper_report_set", P.ind.hopper.unit_number, true)
  es("hopper_report_set", P.empty.hopper.unit_number, true)
  storage.report_expect = {additive = a, dose = best_d}
  local fc = place("infinity-chest", 65, 8)
  fc.infinity_container_filters = {{name = a, count = 100, mode = "at-least", index = 1}}
  place("fast-inserter", 65, 9, N)
  -- Speed (7d): the tier 1 additive with the largest speed effect on gears, dosed at 9, against an
  -- identical undosed machine.
  local fastest, fastest_s = "coal", 0
  for _, name in ipairs({"coal", "wood", "stone", "stone-brick", "copper-cable"}) do
    local sp = es("effect_on", "gear", {[name] = 9}, "speed")
    if math.abs(sp) > math.abs(fastest_s) then fastest, fastest_s = name, sp end
  end
  storage.speed_additive = fastest
  place("substation", 74, 6); place("substation", 80, 6)
  P.speed = machine("assembling-machine-2", 75, "iron-gear-wheel", {[fastest] = 9})
  P.speed_ctrl = machine("assembling-machine-2", 80, "iron-gear-wheel", nil, {no_hopper = true})
  -- Output kept at 99 of 100: every craft lands in a nearly full slot, so extra products often find no
  -- room. They must wait for it, not spill.
  P.blocked = machine("assembling-machine-2", 86, "iron-gear-wheel", {[a] = best_d})
  P.blocked.keep_output = true
  P.blocked.entity.get_inventory(defines.inventory.crafter_output).insert{name = "iron-gear-wheel", count = 99}
  -- Productivity cap: red science (no other rig runs its vanilla recipe), dosed with its best tier 1
  -- additive and dose, research set so the gap to the +300% cap is a third of that gain (whatever the
  -- map). Near: no modules, so the mod may add only the gap. At: two productivity modules on top, P
  -- clamped at the cap, so the mod adds nothing.
  local red_best, red_dose, red_g = "coal", 1, -1
  for _, name in ipairs({"coal", "wood", "stone", "stone-brick", "copper-cable"}) do
    for dose = 1, 9 do
      local gv = es("gain", "red", name, dose)
      if gv > red_g then red_best, red_dose, red_g = name, dose, gv end
    end
  end
  local research = 4 / (1 + red_g / 3) - 1
  storage.red_cap = {additive = red_best, dose = red_dose, gain = red_g, research = research}
  game.forces.player.recipes["automation-science-pack"].enabled = true  -- a trigger tech's recipe in 2.0
  game.forces.player.recipes["automation-science-pack"].productivity_bonus = research
  place("substation", 92, 6)
  P.cap_near = machine("assembling-machine-2", 91, "automation-science-pack", {[red_best] = red_dose})
  P.cap_at = machine("assembling-machine-3", 96, "automation-science-pack", {[red_best] = red_dose})
  P.cap_at.entity.get_module_inventory().insert{name = "productivity-module-3", count = 4}
  -- A quality agent in production (with the quality mod): gears at its best dose, on cleared ground.
  if storage.agent then
    local surf = game.surfaces.nauvis
    for _, e in pairs(surf.find_entities_filtered{area = {{99, 2}, {112, 18}}}) do
      if e.type ~= "character" then e.destroy() end
    end
    local tiles = {}
    for x = 99, 111 do for y = 2, 17 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
    surf.set_tiles(tiles)
    place("substation", 108, 6)
    -- Assembling machine 3: more gears, a tighter estimate (the check below is at 3 standard errors).
    P.agent = machine("assembling-machine-3", 104, "iron-gear-wheel", {[storage.agent.name] = storage.agent.dose})
    -- Real logistics: an inserter empties it into a chest, so its output is usually empty when the mod
    -- looks (the kit showed upgrades lost that way while script collection hid it).
    place("fast-inserter", 104, 14, N)
    P.agent.chest = place("steel-chest", 104, 15)
    P.agent.keep_output = true
    -- And fed by an inserter from an endless chest, not by the test's once-a-second insert.
    local feeder = place("infinity-chest", 105, 15)
    feeder.infinity_container_filters = {{name = "iron-plate", count = 100, mode = "at-least", index = 1}}
    place("fast-inserter", 105, 14, defines.direction.south)  -- picks from the chest below, drops into the machine
    P.agent.no_feed = true
    -- A slowed machine with an exact stock of plates (no feeding): every plate must go into a gear,
    -- or into what the yield path takes on purpose (a speed nudge once cancelled crafts and lost them).
    P.slow = machine("assembling-machine-2", 110, "iron-gear-wheel", {[storage.agent.name] = storage.agent.dose})
    P.slow.entity.get_inventory(defines.inventory.crafter_input).insert{name = "iron-plate", count = 100}
    P.slow.no_feed, P.slow.stock = true, 100
  end
  -- The main gain through a player's logistics: the activator at its best dose, fed and emptied by
  -- inserters (script feeding and collection hid three bugs, 2026-10-02).
  do
    local surf = game.surfaces.nauvis
    for _, e in pairs(surf.find_entities_filtered{area = {{113, 2}, {124, 18}}}) do
      if e.type ~= "character" then e.destroy() end
    end
    local tiles = {}
    for x = 113, 123 do for y = 2, 17 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
    surf.set_tiles(tiles)
    place("substation", 120, 6)
    P.real = machine("assembling-machine-2", 116, "iron-gear-wheel", {[a] = best_d})
    place("fast-inserter", 116, 14, N)
    P.real.chest = place("steel-chest", 116, 15)
    local feeder = place("infinity-chest", 117, 15)
    feeder.infinity_container_filters = {{name = "iron-plate", count = 100, mode = "at-least", index = 1}}
    place("fast-inserter", 117, 14, defines.direction.south)
    P.real.no_feed, P.real.keep_output = true, true
  end
  -- Burner machines and additive quality (outside review, 2026-10-02): a stone furnace dosed with the
  -- additive whose power effect on steel is largest gets no electric consumer or producer (it has no
  -- electric connection); a gear machine whose hopper holds only uncommon stone is dosed with it.
  do
    local surf = game.surfaces.nauvis
    for _, e in pairs(surf.find_entities_filtered{area = {{123, 2}, {141, 20}}}) do
      if e.type ~= "character" then e.destroy() end
    end
    local tiles = {}
    for x = 123, 140 do for y = 2, 19 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
    surf.set_tiles(tiles)
    place("substation", 130, 6)
    local best, beff = nil, 0
    for _, ad in ipairs(shared.tier1) do
      local ef = es("effect_on", "steel", {[ad.name] = 3}, "efficiency")
      if not shared.additive(ad.name).fluid and math.abs(ef) > math.abs(beff) then best, beff = ad.name, ef end
    end
    local f = place("stone-furnace", 126, 12)
    f.get_inventory(defines.inventory.fuel).insert{name = "coal", count = 50}
    f.get_inventory(defines.inventory.furnace_source).insert{name = "iron-plate", count = 100}
    local fh = place("es-hopper", 126, 10)
    fh.get_inventory(defines.inventory.chest).insert{name = best, count = 100}
    es("set_dose", f.unit_number, {rows = rows_of({[best] = 3})})
    storage.burner = {entity = f, additive = best, efficiency = beff}
    local q = place("assembling-machine-2", 134, 12)
    q.set_recipe("iron-gear-wheel")
    q.get_inventory(defines.inventory.crafter_input).insert{name = "iron-plate", count = 200}
    local qh = place("es-hopper", 134, 10)
    qh.get_inventory(defines.inventory.chest).insert{name = "stone", count = 50, quality = "uncommon"}
    es("set_dose", q.unit_number, {rows = rows_of({stone = 2})})
    storage.uncommon = {entity = q, hopper = qh}
    -- (0.72) A machine whose dose changes halfway: its dose panel's count starts again.
    P.redose = machine("assembling-machine-2", 139, "iron-gear-wheel", {coal = 3})
  end
  -- The quality cascade before the recycler (0.50): a furnace smelting iron with an agent makes some
  -- uncommon plates; a gear machine set to uncommon, fed uncommon plates and dosed again, makes rare.
  if storage.agent then
    local surf = game.surfaces.nauvis
    for _, e in pairs(surf.find_entities_filtered{area = {{141, 2}, {160, 20}}}) do
      if e.type ~= "character" then e.destroy() end
    end
    local tiles = {}
    for x = 141, 159 do for y = 2, 19 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
    surf.set_tiles(tiles)
    place("substation", 146, 6)  -- within wire reach of the one at 130
    local agent = storage.agent.name
    local function best_dose(key)
      local bd, bc = 1, -1
      for d = 1, shared.max_dose do
        local c = es("quality_chance", key, {[agent] = d})
        if c > bc then bd, bc = d, c end
      end
      return bd, bc
    end
    local fd, fc = best_dose("iron-plate")
    local f = place("electric-furnace", 143, 12)
    f.get_inventory(defines.inventory.furnace_source).insert{name = "iron-ore", count = 50}
    local fh = place("es-hopper", 143, 10)
    fh.get_inventory(defines.inventory.chest).insert{name = agent, count = 50}
    es("set_dose", f.unit_number, {rows = rows_of({[agent] = fd})})
    place("fast-inserter", 143, 14, N)
    local fchest = place("steel-chest", 143, 15)
    local gd, gc = best_dose("gear")
    local g = place("assembling-machine-2", 150, 12)
    g.set_recipe("iron-gear-wheel", "uncommon")
    -- Enough for ~400 gears: at a few percent, 60 gears made no rare one about one run in six (2026-10-05,
    -- when the showcase moved the engine's random stream). The input slot takes 120 plates; the rest wait in a chest.
    g.get_inventory(defines.inventory.crafter_input).insert{name = "iron-plate", count = 200, quality = "uncommon"}
    place("steel-chest", 147, 12).insert{name = "iron-plate", count = 600, quality = "uncommon"}
    place("fast-inserter", 148, 12, defines.direction.west)  -- (it picks from the west)
    local gh = place("es-hopper", 150, 10)
    gh.get_inventory(defines.inventory.chest).insert{name = agent, count = 1000}
    es("set_dose", g.unit_number, {rows = rows_of({[agent] = gd})})
    place("fast-inserter", 150, 14, N)
    local gchest = place("steel-chest", 150, 15)
    storage.cascade = {furnace = f, fchest = fchest, fchance = fc, gears = g, gchest = gchest, gchance = gc}
  end
  -- Freshness (0.52): two biochambers making bioflux from half-spoiled mash and jelly, emptied by
  -- inserters into chests; one undosed, one dosed with the item additive that restores most on bioflux.
  if prototypes.recipe["bioflux"] then
    local surf = game.surfaces.nauvis
    for _, e in pairs(surf.find_entities_filtered{area = {{161, 2}, {180, 20}}}) do
      if e.type ~= "character" then e.destroy() end
    end
    local tiles = {}
    for x = 161, 179 do for y = 2, 19 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
    surf.set_tiles(tiles)
    place("substation", 162, 6)
    place("substation", 171, 6)  -- the dosed rig at 174.5 is past the first one's reach
    game.forces.player.recipes["bioflux"].enabled = true
    local best, bf = nil, 0
    for _, ad in ipairs(shared.tier1) do
      local f = es("effect_on", "bioflux", {[ad.name] = 5}, "freshness")
      if not shared.additive(ad.name).fluid and f > bf then best, bf = ad.name, f end
    end
    local rigs = {}
    for i, x in ipairs({166.5, 174.5}) do
      local b = place("biochamber", x, 12.5)
      b.set_recipe("bioflux")
      b.get_fuel_inventory().insert{name = "nutrients", count = 100}
      place("fast-inserter", x, 14.5, N)
      rigs[i] = {entity = b, chest = place("steel-chest", x, 15.5)}
    end
    if best then
      local h = place("es-hopper", 176.5, 12.5)
      h.get_inventory(defines.inventory.chest).insert{name = best, count = 1000}  -- the whole run (200 ran out)
      es("set_dose", rigs[2].entity.unit_number, {rows = rows_of({[best] = 5})})
    end
    storage.fresh = {control = rigs[1], dosed = rigs[2], additive = best, f = bf,
      speed = best and es("effect_on", "bioflux", {[best] = 5}, "speed")}
    -- And on benches: a control and a dosed bioflux trial on half-spoiled ingredients; their samples
    -- record the freshness restored.
    local benches = {}
    for i, x in ipairs({166.5, 174.5}) do
      local b = place("es-test-bench", x, 4.5)
      game.forces.player.recipes["es-trial-bioflux-control"].enabled = true  -- Gleba's trigger tech
      b.set_recipe("es-trial-bioflux-control")
      place("fast-inserter", x, 6.5, N)
      benches[i] = {entity = b, chest = place("steel-chest", x, 7.5)}
    end
    if best then
      local h = place("es-hopper", 176.5, 4.5)
      h.get_inventory(defines.inventory.chest).insert{name = best, count = 1000}  -- the whole run (200 ran out)
      es("set_dose", benches[2].entity.unit_number, {rows = rows_of({[best] = 5})})
    end
    storage.fresh_benches = benches
  end
  storage.P = P
  storage.hopper_to_remove = place("es-hopper", 65, 20)

  -- The automation wing, closed loop (endgame 4): a station's port (its own history) paces a dose sweep
  -- through real combinators. Coal = (samples / 6) mod 9 + 1 on a separate green network into three benches in
  -- circuit mode; a fourth bench runs the control. (0.72: es-n on page 0, the samples in the station's own history.)
  local ax, ay = 110, 45
  for x = ax - 2, ax + 26, 6 do place("substation", x, ay - 6) end
  place("electric-energy-interface", ax - 6, ay - 6)  -- its own power: too far from the lab's grid
  storage.auto_station = place("es-analysis-station", ax + 10, ay + 10)
  es("station_any", storage.auto_station.unit_number)
  storage.auto_station.get_inventory(defines.inventory.chest).insert{name = "automation-science-pack", count = 200}
  local aport = es("station", storage.auto_station.unit_number).port
  es("set_port_source", storage.auto_station.unit_number, "station")
  es("set_view_target", storage.auto_station.unit_number, "gear")
  local function arith(x, y, first, op, const, out)
    local c = place("arithmetic-combinator", x, y)
    c.get_or_create_control_behavior().parameters = {first_signal = {type = "virtual", name = first},
      second_constant = const, operation = op, output_signal = out}
    return c
  end
  local c1 = arith(ax, ay - 4, "es-n", "/", 6, {type = "virtual", name = "signal-X"})
  local c2 = arith(ax + 2, ay - 4, "signal-X", "%", 9, {type = "virtual", name = "signal-Y"})
  local c3 = arith(ax + 4, ay - 4, "signal-Y", "+", 1, {type = "item", name = "coal"})
  local W = defines.wire_connector_id
  aport.get_wire_connector(W.circuit_red, true).connect_to(c1.get_wire_connector(W.combinator_input_red, true), false)
  c1.get_wire_connector(W.combinator_output_red, true).connect_to(c2.get_wire_connector(W.combinator_input_red, true), false)
  c2.get_wire_connector(W.combinator_output_red, true).connect_to(c3.get_wire_connector(W.combinator_input_red, true), false)
  storage.auto_rigs = {}
  for i = 0, 3 do
    local r = rig(ax + i * 6, ay, "es-trial-gear-control", i < 3 and {coal = 1} or nil)
    r.station_entity = storage.auto_station
    if i < 3 then
      es("set_dose", r.entity.unit_number, {rows = rows_of({coal = 1}), circuit = true})
      c3.get_wire_connector(W.combinator_output_green, true).connect_to(r.entity.get_wire_connector(W.circuit_green, true), false)
    end
    storage.rigs["auto" .. i] = r
  end

  -- Planet conditions (0.26): a dosed gear bench and a dosed gear assembler on Vulcanus. Its samples,
  -- analysed by the station on Nauvis, count for Vulcanus; the assembler follows Vulcanus's gain.
  if game.planets and game.planets["vulcanus"] then
    local vs = game.planets["vulcanus"].create_surface()
    vs.request_to_generate_chunks({0, 0}, 2); vs.force_generate_chunk_requests()
    for _, e in pairs(vs.find_entities_filtered{area = {{-20, -20}, {20, 20}}}) do e.destroy() end
    local tiles = {}
    for x = -20, 19 do for y = -20, 19 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
    vs.set_tiles(tiles)
    place("electric-energy-interface", -8, -8, nil, vs)
    place("substation", -4, -4, nil, vs); place("substation", 6, -4, nil, vs)
    local b = place("es-test-bench", 0, 0, nil, vs)
    b.set_recipe("es-trial-gear-control")
    local h = place("es-hopper", 0, -2, nil, vs)
    place("fast-inserter", 0, 2, defines.direction.north, vs)
    -- The map's gear activator at its best dose: a condition scales an effect, never flips it.
    local vd = {[storage.activator] = storage.best_dose}
    storage.vulcanus_dose = vd
    local r = {entity = b, hopper = h, chest = place("iron-chest", 0, 3, nil, vs), doses = vd, trials = 0,
      untagged = 0, items = {}, spent = 0, keys = {}}
    es("set_dose", b.unit_number, {rows = rows_of(vd)})
    storage.rigs.vulcanus = r
    local m = place("assembling-machine-2", 8, 0, nil, vs)
    m.set_recipe("iron-gear-wheel")
    local mh = place("es-hopper", 8, -2, nil, vs)
    es("set_dose", m.unit_number, {rows = rows_of(vd)})
    storage.P.vulcanus = {entity = m, hopper = mh, doses = vd, made = 0, by_quality = {}, taken = {},
      spent = 0, fill = true, crafts = 0}
  end

  -- Liquid premixes (0.27): the same premix at 15 and 90 degrees, on benches (samples record it) and on
  -- gear lines (each follows the gain at its own temperature).
  -- The liquid premix with the best gear gain at dose 40 (at its best temperature): a temperature scales
  -- an effect, never flips it, so both lines gain and their outputs can be checked.
  local LP, lp_best = nil, -1e9
  for _, pm in ipairs(shared.premixes) do
    if pm.fluid then
      local g = es("gain", "gear", pm.name, 40)
      if g > lp_best then LP, lp_best = pm.name, g end
    end
  end
  storage.lp = LP
  local function hot_source(x, y, temp)
    local p = place("infinity-pipe", x, y)
    p.set_infinity_pipe_filter{name = LP, percentage = 1, temperature = temp}
  end
  for i, temp in ipairs({15, 90}) do
    local x = 55 + 6 * i
    local r = rig(x, -14, "es-trial-gear-control")
    r.doses = {[LP] = 40}
    r.no_fill = true
    es("set_dose", r.entity.unit_number, {rows = rows_of({[LP] = 40})})
    local hx, hy
    r.fluid_hopper, hx, hy = fluid_hopper(x + 1, -16, 0, -1)
    hot_source(hx, hy, temp)
    storage.rigs["lp" .. temp] = r
  end
  -- A burner fluid heater: lubricant (25 degrees, a vanilla fluid whose ceiling the mod raised) in, a pipe out.
  do
    local hx, hy = 112, 20
    local h = place("es-fluid-heater", hx, hy, defines.direction.north)
    h.insert{name = "coal", count = 50}
    storage.heater = h
    -- Its input and output connections, from the prototype, one tile outside the entity.
    local W = game.surfaces.nauvis
    for _, fb in ipairs({1, 2}) do
      local conns = h.fluidbox.get_pipe_connections(fb)
      for _, c in ipairs(conns) do
        if fb == 1 then
          local p = place("infinity-pipe", c.target_position.x, c.target_position.y)
          p.set_infinity_pipe_filter{name = "lubricant", percentage = 1, temperature = 25}
          break
        else
          storage.heater_out = place("pipe", c.target_position.x, c.target_position.y)
        end
      end
    end
  end
  -- (0.71) Fluid chillers, with Space Age: the liquid premix in at 15, out at the chilled cold, burning cold
  -- charges; a second one with no charge passes nothing.
  if prototypes.entity["es-fluid-chiller"] then
    storage.chill = {}
    for i, fuel in ipairs({5, 0}) do
      local c = place("es-fluid-chiller", 118 + 6 * (i - 1), 20, defines.direction.north)
      if fuel > 0 then c.insert{name = "es-cold-charge", count = fuel} end
      local inp = c.fluidbox.get_pipe_connections(1)[1].target_position
      local out = c.fluidbox.get_pipe_connections(2)[1].target_position
      local ip = place("infinity-pipe", inp.x, inp.y)
      ip.set_infinity_pipe_filter{name = LP, percentage = 1, temperature = 15}
      -- A line of pipes beyond it (a write that lost the line's fluid would show as charges burned refilling it).
      local first = place("pipe", out.x, out.y)
      for j = 1, 4 do place("pipe", out.x, out.y - j) end
      storage.chill[i] = {entity = c, out = first, fuel = fuel}
    end
  end
  place("substation", 104, 6)
  -- (Past the row's last machine: at 102 and 108 they overlapped the quality agent's machine and the one at
  -- 110, and the agent's upgrades came out at a third of its chance on some layouts.)
  place("substation", 128, 6)
  for i, temp in ipairs({15, 90}) do
    local x = 116 + 6 * i
    local m = machine("assembling-machine-2", x, "iron-gear-wheel", {[LP] = 40})
    -- machine() places the fluid source for a fluid dose: set its temperature.
    local p = game.surfaces.nauvis.find_entities_filtered{name = "infinity-pipe", position = m.fluid_end, radius = 0.6}[1]
    p.set_infinity_pipe_filter{name = LP, percentage = 1, temperature = temp}
    storage.P["lp" .. temp] = m
  end

  -- Spoilage (0.28): carbon fibre trials, one bench on stale yumako mash (80% spoiled, never refilled),
  -- one fed fresh. The stale runs fail and are counted; the fresh ones are analysed.
  if prototypes.recipe["es-trial-carbon-fiber-control"] then
    local stale = rig(67, -30, "es-trial-carbon-fiber-control")
    stale.no_feed = true
    local inv = stale.entity.get_inventory(defines.inventory.crafter_input)
    inv.insert{name = "yumako-mash", count = 190}
    inv.insert{name = "carbon", count = 20}
    for i = 1, #inv do
      if inv[i].valid_for_read and inv[i].name == "yumako-mash" then inv[i].spoil_percent = 0.8 end
    end
    storage.rigs.stale = stale
    storage.rigs.fresh_fiber = rig(73, -30, "es-trial-carbon-fiber-control")
    place("substation", 70, -24)  -- 16 from the grid: at exactly 18 a substation never connects
    -- Carbon fibre samples cost agricultural packs (its planet's).
    storage.station.get_inventory(defines.inventory.chest).insert{name = "agricultural-science-pack", count = 50}
  end


  -- Presets: saved once; the same composition again is refused.
  storage.preset_first = es("add_preset", "player", "gear", {[a] = best_d})
  storage.preset_again = es("add_preset", "player", "gear", {[a] = best_d})

  storage.packs_fed, storage.samples_fed, storage.green_fed = 0, 0, 0
  storage.engine_waiting_before_green = 0
end)

local function feed(e, quality)
  local recipe = e.get_recipe()
  if not recipe then return end
  local inv = e.get_inventory(defines.inventory.crafter_input)
  for _, ing in pairs(recipe.ingredients) do
    if ing.type ~= "fluid" then inv.insert{name = ing.name, count = ing.amount * 4, quality = quality} end
  end
end

-- Residues out of an inventory, counted (an additive dosed as itself stays).
local function take_residues(r, inv)
  if not inv then return end
  for _, item in pairs(inv.get_contents()) do
    if item.name:find("^es%-spent%-") and not (r.doses and r.doses[item.name]) then
      r.spent = r.spent + inv.remove{name = item.name, count = item.count, quality = item.quality}
    end
  end
end

-- Keep a hopper's items topped up (fluids come by pipe), recording what went in; take residues out of
-- the machine (0.65: its trash slots, and the chest its output inserter fills).
local function tend_hopper(r, h)
  if r.entity and r.entity.valid then take_residues(r, r.entity.get_inventory(defines.inventory.crafter_trash)) end
  if r.chest and r.chest.valid then take_residues(r, r.chest.get_inventory(defines.inventory.chest)) end
  h = h or r.hopper
  if not (h and h.valid) then return end
  local inv = h.get_inventory(defines.inventory.chest)
  if r.no_fill or r.fill == false or not r.doses then return end
  for name in pairs(r.doses) do
    if not is_fluid(name) then
      local have = inv.get_item_count(name)
      if have < 30 then
        local put = inv.insert{name = name, count = 30 - have}
        r.put = r.put or {}
        r.put[name] = (r.put[name] or 0) + put
      end
    end
  end
end

on_nth_tick(60, function(event)
  if event.tick == 0 or event.tick > END_TICK then return end
  local station_inv = storage.station.get_inventory(defines.inventory.chest)
  -- Sweep rig steps through doses 1..9 of the activator (set in its panel).
  if event.tick % 1200 == 0 then
    local d = (event.tick / 1200) % 9 + 1
    storage.rigs.sweep.doses = {[storage.activator] = d}
    es("set_dose", storage.rigs.sweep.entity.unit_number, {rows = rows_of(storage.rigs.sweep.doses)})
  end
  for _, r in pairs(storage.rigs) do
    if not r.no_feed then feed(r.entity) end
    tend_hopper(r)
    local chest = r.chest.get_inventory(defines.inventory.chest)
    for i = 1, #chest do
      local st = chest[i]
      if st.valid_for_read then
        -- (0.72) A sample moves only when its station has room (four waiting, as an inserter would find it);
        -- otherwise it waits in the chest and is counted when it moves.
        local dest = shared.is_sample(st.name) and (r.station_entity and r.station_entity.get_inventory(defines.inventory.chest)
          or r.station2 and storage.station2.get_inventory(defines.inventory.chest) or station_inv)
        local moved = dest and dest.can_insert(st)
        if dest and not moved then
          -- (waits; counted once, the first time it is seen)
          if st.item and not st.item.get_tag("es_test_counted") then
            r.trials = r.trials + 1
            if not (st.item.get_tag("y") or st.item.get_tag("failed")) then r.untagged = r.untagged + 1 end
            local mix = st.item.get_tag("mix")
            local key = mix and next(mix) and "dosed" or "control"
            r.keys[key] = (r.keys[key] or 0) + 1
            r.ysum = r.ysum or {}
            r.ysum[key] = (r.ysum[key] or 0) + (st.item.get_tag("y") or 0)
            local tt = st.item.get_tag("temps")
            if tt and storage.lp and tt[storage.lp] then r.last_temp = tt[storage.lp] end
            st.item.set_tag("es_test_counted", true)
          end
        elseif shared.is_sample(st.name) and st.item and st.item.get_tag("es_test_counted") then
          if dest.insert(st) == 1 and dest == station_inv then storage.samples_fed = storage.samples_fed + 1 end
          st.clear()
        elseif shared.is_sample(st.name) then
          r.trials = r.trials + 1
          -- Tagged: a yield, or a failed run (stale inputs: no yield by design).
          if not (st.item and (st.item.get_tag("y") or st.item.get_tag("failed"))) then r.untagged = r.untagged + 1 end
          local mix = st.item and st.item.get_tag("mix")
          local tt = st.item and st.item.get_tag("temps")
          if tt and storage.lp and tt[storage.lp] then r.last_temp = tt[storage.lp] end
          local key = mix and next(mix) and "dosed" or "control"
          r.keys[key] = (r.keys[key] or 0) + 1
          r.ysum = r.ysum or {}
          r.ysum[key] = (r.ysum[key] or 0) + (st.item.get_tag("y") or 0)
          if dest.insert(st) == 1 and dest == station_inv then storage.samples_fed = storage.samples_fed + 1 end
          st.clear()
        else
          r.items[st.name] = (r.items[st.name] or 0) + st.count
          st.clear()
        end
      end
    end
  end

  -- Production: feed, tend hoppers, count products by quality.
  local shared_rec = {doses = {[storage.activator] = storage.best_dose}, spent = 0}
  storage.shared_rec = storage.shared_rec or shared_rec
  tend_hopper(storage.shared_rec, storage.shared_hopper)
  for key, r in pairs(storage.P) do
    local e = r.entity
    if r.no_feed then  -- fed by its own inserter
    elseif key == "quality" then feed(e, "uncommon")
    elseif key == "steel" then e.get_inventory(defines.inventory.furnace_source).insert{name = "iron-plate", count = 50}
    else feed(e) end
    tend_hopper(r)
    local out = e.get_inventory(key == "steel" and defines.inventory.furnace_result or defines.inventory.crafter_output)
    for _, item in pairs(r.keep_output and {} or out.get_contents()) do
      r.made = r.made + item.count
      r.by_quality[item.quality] = (r.by_quality[item.quality] or 0) + item.count
    end
    if not r.keep_output then out.clear()
    else
      local over = out.get_item_count("iron-gear-wheel") - 99
      if over > 0 then out.remove{name = "iron-gear-wheel", count = over} end
    end
    -- Crafts counted at collection time: the mod applied their effect earlier this tick (it loads first).
    r.crafts = e.products_finished
  end

  -- Losing rig: feed (counting what goes in), count gears the inserter delivered.
  local nr = storage.neg_rig
  local nin = nr.entity.get_inventory(defines.inventory.crafter_input)
  for _, ing in pairs(nr.entity.get_recipe().ingredients) do
    local have = nin.get_item_count(ing.name)
    if have < ing.amount * 4 then
      nr.fed[ing.name] = (nr.fed[ing.name] or 0) + nin.insert{name = ing.name, count = ing.amount * 4 - have}
    end
  end
  local nchest = nr.chest.get_inventory(defines.inventory.chest)
  nr.gears = nr.gears + nchest.get_item_count("iron-gear-wheel")
  nchest.clear()


  -- Red packs until the last minute (a deliberate shortage); green from halfway.
  local have = station_inv.get_item_count("automation-science-pack")
  if event.tick < END_TICK - 3600 and have < 10 then
    storage.packs_fed = storage.packs_fed + station_inv.insert{name = "automation-science-pack", count = 10 - have}
  end
  if event.tick == GREEN_FROM - 60 then
    for i = 1, #station_inv do
      local st = station_inv[i]
      if st.valid_for_read and shared.is_sample(st.name) and st.item.get_tag("target") == "engine" then
        storage.engine_waiting_before_green = storage.engine_waiting_before_green + 1
      end
    end
  end
  if event.tick >= GREEN_FROM then
    local g = station_inv.get_item_count("logistic-science-pack")
    if g < 5 then storage.green_fed = storage.green_fed + station_inv.insert{name = "logistic-science-pack", count = 5 - g} end
  end
  if event.tick == 600 then station_inv.insert{name = RED_SAMPLE, count = 1} end  -- untagged: must be discarded
  local s2 = storage.station2.get_inventory(defines.inventory.chest)
  if s2.get_item_count("automation-science-pack") < 10 then s2.insert{name = "automation-science-pack", count = 10} end
end)

local function stats_selftest()
  check("t_crit df=30", math.abs(es("t_crit", 30) - 2.0423) < 1e-3, es("t_crit", 30))
  check("p_two t=2 df=10", math.abs(es("p_two", 2.0, 10) - 0.07339) < 1e-4, es("p_two", 2.0, 10))
  -- Exact for d1 = 2: P(F > f) = (1 + 2f/d2)^(-d2/2) = 1.6^-5.
  check("f_upper F=3 df=(2,10)", math.abs(es("f_upper", 3.0, 2, 10) - 1.6 ^ -5) < 1e-9, es("f_upper", 3.0, 2, 10))
end

-- Regression on synthetic per-dose data with known answers.
local function regression_selftest()
  local function points(f, sd)
    local pts = {}
    for d = 0, 9 do table.insert(pts, {dose = d, n = 10, mean = f(d), ss = 9 * sd * sd}) end
    return pts
  end
  local quad = points(function(d) return 100 + 50 * d - 5 * d * d end, 20)
  local q = es("fit_points", quad, "quadratic")
  check("quadratic recovers coefficients", math.abs(q.coef[1] - 100) < 1e-6 and math.abs(q.coef[2] - 50) < 1e-6
    and math.abs(q.coef[3] + 5) < 1e-6, string.format("%.3f %.3f %.3f", q.coef[1], q.coef[2], q.coef[3]))
  check("quadratic optimum 5 inside its CI", q.optimum and q.optimum.lo < 5 and 5 < q.optimum.hi
    and math.abs(q.optimum.dose - 5) < 1e-6,
    q.optimum and string.format("%.2f [%.2f, %.2f]", q.optimum.dose, q.optimum.lo, q.optimum.hi))
  check("quadratic on quadratic data fits", q.lof_p > 0.99, q.lof_p)
  local l = es("fit_points", quad, "linear")
  check("linear on quadratic data fails lack of fit", l.lof_p < 0.001, l.lof_p)
  local sat = es("fit_points", points(function(d) return 200 * (1 - math.exp(-d / 2)) end, 20), "saturating")
  check("saturating recovers scale", sat.tau == 2 and math.abs(sat.coef[2] - 200) < 1e-6,
    string.format("tau %.2f b %.2f", sat.tau, sat.coef[2]))
  local th = es("fit_points", points(function(d) return d >= 4 and 150 or 0 end, 20), "threshold")
  check("threshold recovers step", th.at == 4 and math.abs(th.coef[2] - 150) < 1e-6,
    string.format("at %d b %.2f", th.at, th.coef[2]))
  -- Automatic: a curve when the data bends clearly, a line when it does not.
  local aq = es("fit_points", quad, "auto")
  -- A line with wobble well inside its noise: a curve fits it a little better, not clearly.
  local al = es("fit_points", points(function(d) return 20 + 8 * d + (d % 3 - 1) * 3 end, 20), "auto")
  check("automatic model: a curve on curved data, a line on straight data",
    aq.model ~= "linear" and al.model == "linear", string.format("curved -> %s, straight -> %s", aq.model, al.model))
  -- Cliff (0.59): data from the world's cliff (optimum 3: rises, collapses from 4.8) makes Automatic choose
  -- Cliff, its best dose below the collapse; curved data without a collapse does not.
  local cl = es("fit_points", points(function(d)
    return 150 * (1 - math.exp(-d)) - 300 / (1 + math.exp(-4 * (d - 4.8)))
  end, 20), "auto")
  check("automatic model: a cliff on cliff data, best dose below the collapse; not a cliff on a quadratic",
    cl.model == "cliff" and math.abs(cl.cliff_at - 4.8) < 0.3 and cl.best_dose < cl.cliff_at and aq.model ~= "cliff",
    string.format("cliff data -> %s (collapse at %s, best %.1f); quadratic -> %s", cl.model, tostring(cl.cliff_at),
      cl.best_dose or -1, aq.model))
  local few = es("fit_points", {{dose = 0, n = 5, mean = 0, ss = 10}, {dose = 3, n = 5, mean = 50, ss = 10}}, "quadratic")
  check("too few doses refused", few.error == "need-doses", few.error)
  -- Exactly as many doses as parameters: fitted, through every mean, CI from replicate scatter.
  local three = {{dose = 0, n = 6, mean = 0, ss = 5 * 400}, {dose = 3, n = 6, mean = 150, ss = 5 * 400},
                 {dose = 6, n = 6, mean = 60, ss = 5 * 400}}
  local q3 = es("fit_points", three, "quadratic")
  check("quadratic fits with 3 doses", q3.error == nil and q3.lof_exact and q3.lof_p == nil, q3.error)
  check("3-dose quadratic passes through the means", q3.values and math.abs(q3.values[4] - 150) < 1e-6
    and math.abs(q3.values[7] - 60) < 1e-6)
  check("3-dose quadratic has an optimum CI", q3.optimum ~= nil and q3.optimum.lo < q3.optimum.dose,
    q3.optimum and string.format("%.2f [%.2f, %.2f]", q3.optimum.dose, q3.optimum.lo, q3.optimum.hi))
  local l2 = es("fit_points", {{dose = 0, n = 4, mean = 0, ss = 900}, {dose = 5, n = 4, mean = 100, ss = 900}}, "linear")
  check("linear fits with 2 doses", l2.error == nil and l2.lof_exact, l2.error)
end

-- Every activator: zero at dose 0 and reaching most of its peak at some integer dose.
local function shapes_selftest()
  local truth = es("truth")
  local seen = {}
  for _, target in pairs(truth.targets) do for _, r in pairs(target) do seen[r.shape] = true end end
  local list = {}
  for s in pairs(seen) do table.insert(list, s) end
  table.sort(list)
  info("shapes drawn on this map: " .. table.concat(list, ", "))
  for _, target in pairs({"gear", "circuit", "engine"}) do
    for name, r in pairs(truth.targets[target]) do
      if es("gain", target, name, 0) ~= 0 then check(target .. "/" .. name .. " gain(0) = 0", false) end
      if r.kind == "activator" then
        local best = -1
        for d = 1, (shared.additive(name).max_dose) do best = math.max(best, es("gain", target, name, d)) end
        local peak = r.peak * es("gain_scale", target, name)  -- scaled by the target's responsiveness
        check(target .. "/" .. name .. " (" .. r.shape .. ") reaches most of peak", best > 0.6 * peak,
          string.format("%.3f of %.3f", best, r.peak))
      end
    end
  end
end

-- Staged reveal: the pre-staging grant revoked 40 seconds before the end; samples in transit then
-- (measured with instruments) are analysed within a trial's length, and the counts start 20 seconds
-- later, leaving 20 seconds of new samples before the checks at END_TICK + 120.

-- Circuit interface (0.49), on the station set up for it: each step one tick after an analysis tick (the
-- port is rewritten on that tick), each expectation recomputed here from the pool's raw summaries.
local CIRC = END_TICK - 4800
local function port_of(unit)
  local out = {}
  for _, f in ipairs(es("port_filters", unit)) do out[f.type .. "/" .. f.name] = f.value end
  return out
end
local function item_rows(unit)
  -- {additive = {d = summary}} for item additives tested alone on gears, and the control.
  local sums = es("station_history", unit, "gear")
  local rows = {}
  for key, sm in pairs(sums) do
    local name, d = key:match("^([%w%-]+):(%d+)$")
    local ad = name and shared.additive(name)
    if ad and not ad.fluid and not ad.premix_of then
      rows[name] = rows[name] or {}
      rows[name][tonumber(d)] = sm
    end
  end
  return rows, sums
end
local function best_by_lo(doses)
  local bd
  for d, sm in pairs(doses) do if sm.lo and (not bd or sm.lo > doses[bd].lo) then bd = d end end
  return bd
end
on_nth_tick(CIRC + 1, function(event)
  if event.tick == 0 then return end
  local c = storage.circ
  local served = es("station_served", c.station.unit_number) or {}
  local port = port_of(c.station.unit_number)
  check("station input: the wire's recipe target wins over the window's and an item signal; page 1 waits for its technology",
    served.target == "gear" and served.page == 0 and port["virtual/es-page"] == nil,
    serpent.line(served))
  check("a bench's recipe set by circuit (vanilla set recipe)",
    c.bench.get_recipe() and c.bench.get_recipe().name == "es-trial-red-control",
    c.bench.get_recipe() and c.bench.get_recipe().name or "none")
  for _, t in ipairs({"es-circuit-instrumentation-2", "es-circuit-instrumentation-3"}) do
    game.forces.player.technologies[t].researched = true
  end
end)
-- (0.72) The four-page port: an additive on the input selects it on every page.
on_nth_tick(CIRC + 31, function(event)
  if event.tick == 0 then return end
  local c = storage.circ
  set_cc(c.cc, {{"recipe", "iron-gear-wheel", 1}, {"item", "coal", 1}})
end)
on_nth_tick(CIRC + 61, function(event)
  if event.tick == 0 then return end
  local c = storage.circ
  local port = port_of(c.station.unit_number)
  local rows, sums = item_rows(c.station.unit_number)
  local bad, seen = {}, 0
  for name, doses in pairs(rows) do
    local bd = best_by_lo(doses)
    if bd then
      seen = seen + 1
      local want = math.floor(doses[bd].lo + 0.5)
      if (port["item/" .. name] or 0) ~= want then table.insert(bad, name .. " " .. tostring(port["item/" .. name]) .. " vs " .. want) end
    end
  end
  local total = 0
  for _, sm in pairs(sums) do total = total + (sm.n or 0) end
  check("port page 0, Results: each additive's lower bound at its best dose, the target's samples, the selected additive's best dose (coal: 5, not the higher mean at 3), no page echo",
    seen > 0 and #bad == 0 and port["virtual/es-n"] == total and port["virtual/es-dose"] == 5 and port["virtual/es-page"] == nil,
    string.format("%d additives, samples %s vs %d, dose %s, mismatches: %s", seen, tostring(port["virtual/es-n"]), total,
      tostring(port["virtual/es-dose"]), table.concat(bad, "; ")))
  set_cc(c.cc, {{"recipe", "iron-gear-wheel", 1}, {"virtual", "es-page", 1}, {"item", "stone", 1}})
end)
on_nth_tick(CIRC + 91, function(event)
  if event.tick == 0 then return end
  local c = storage.circ
  local port = port_of(c.station.unit_number)
  local bad, seen = {}, 0
  for _, a in ipairs(shared.all_additives) do
    local row = es("station_row", c.station.unit_number, "gear", a.name)
    local want = row and math.floor(row.rate * 1000 + 0.5) or nil
    if want == 0 then want = nil end
    local got = port[shared.signal_type(a.name) .. "/" .. a.name]
    if got ~= want then table.insert(bad, a.name .. " " .. tostring(got) .. " vs " .. tostring(want)) else seen = seen + 1 end
  end
  local rates = {}
  for k, v in pairs(port) do if k:find("^item/") or k:find("^fluid/") then rates[v] = true end end
  -- The selected additive's most open tested dose, recomputed: stone is settled at 1 and open at 4.
  local rows, sums = item_rows(c.station.unit_number)
  local ctl = sums.control
  local function phi(x)
    local t = 1 / (1 + 0.3275911 * math.abs(x) / math.sqrt(2))
    local y = 1 - (((((1.061405429 * t - 1.453152027) * t) + 1.421413741) * t - 0.284496736) * t + 0.254829592) * t
      * math.exp(-x * x / 2)
    return x >= 0 and (1 + y) / 2 or (1 - y) / 2
  end
  local function openness(d, sm)
    if sm.n < 2 then return 1 end
    local se = math.max(math.sqrt(sm.var / sm.n + ctl.var / ctl.n), 1e-9)
    local net = sm.mean - ctl.mean - es("tau", "gear", {stone = d})
    return math.min(1, (1.96 * se / (shared.data.band * 1000)) ^ 2) * (1 - phi(-net / se))
  end
  local most, lowest = -1, math.huge
  for d, sm in pairs(rows.stone or {}) do most = math.max(most, openness(d, sm)); lowest = math.min(lowest, d) end
  local d = port["virtual/es-dose"]
  local open_ok = d and rows.stone and rows.stone[d] and math.abs(openness(d, rows.stone[d]) - most) < 1e-3
    and d ~= lowest and d ~= best_by_lo(rows.stone) and port["virtual/es-n"] == rows.stone[d].n
  check("port page 1, Screening: each additive's packs per next sample as Screening shows them; the selected additive's most open tested dose (neither its lowest nor its best) and its samples there",
    port["virtual/es-page"] == 1 and port["recipe/iron-gear-wheel"] == 1 and #bad == 0 and seen > 0 and table_size(rates) > 1 and open_ok,
    string.format("%d additives, %d distinct rates, stone dose %s n %s, mismatches: %s", seen, table_size(rates), tostring(d),
      tostring(port["virtual/es-n"]), table.concat(bad, "; ")))
  -- Side effects for the selected cell, seeded in the station's own history: speed +40, cleanliness -20.
  es("seed_side", c.station.unit_number, "speed", "gear", "coal:5", {38, 42, 40, 40})
  es("seed_side", c.station.unit_number, "pollution", "gear", "coal:5", {-20, -20, -22, -18})
  set_cc(c.cc, {{"recipe", "iron-gear-wheel", 1}, {"virtual", "es-page", 2}, {"item", "coal", 1}, {"virtual", "es-dose", 5}})
end)
on_nth_tick(CIRC + 121, function(event)
  if event.tick == 0 then return end
  local c = storage.circ
  local port = port_of(c.station.unit_number)
  local sm = item_rows(c.station.unit_number).coal[5]
  local function r(x) return x and math.floor(x + 0.5) end
  check("port page 2, Selected result: the cell's count, mean, half-width, lower bound and side effects",
    port["virtual/es-page"] == 2 and port["virtual/es-n"] == sm.n and port["virtual/es-mean"] == r(sm.mean)
      and (port["virtual/es-half"] or 0) == r(sm.half) and (port["virtual/es-lo"] or 0) == r(sm.lo)
      and port["virtual/es-speed"] == 40 and port["virtual/es-cleanliness"] == -20 and port["virtual/es-efficiency"] == nil,
    string.format("coal:5 port n %s mean %s half %s lo %s; want %d %d %d %d", tostring(port["virtual/es-n"]),
      tostring(port["virtual/es-mean"]), tostring(port["virtual/es-half"]), tostring(port["virtual/es-lo"]), sm.n, r(sm.mean),
      r(sm.half), r(sm.lo)))
  set_cc(c.cc, {{"recipe", "iron-gear-wheel", 1}, {"virtual", "es-page", 3}})
end)
on_nth_tick(CIRC + 151, function(event)
  if event.tick == 0 then return end
  local c = storage.circ
  local port = port_of(c.station.unit_number)
  local _, sums = item_rows(c.station.unit_number)
  local ctl, best = sums.control, nil
  for key, sm in pairs(sums) do
    if key ~= "control" and not key:find("^route:") and (sm.n or 0) >= 2 then
      local mix, ok = {}, true
      for part in key:gmatch("[^+]+") do
        local name, d = part:match("^(.+):(%d+)$")
        if not name then ok = false; break end
        mix[shared.split_band(name)] = tonumber(d)
      end
      if ok then
        local se = math.max(math.sqrt(sm.var / sm.n + ctl.var / ctl.n), 1e-9)
        local net = sm.mean - ctl.mean - es("tau", "gear", mix)
        if not best or net - 1.96 * se > best.lo then best = {mix = mix, lo = net - 1.96 * se, n = sm.n, key = key} end
      end
    end
  end
  local same = best ~= nil and port["virtual/es-n"] == best.n and port["virtual/es-lo"] == math.floor(best.lo + 0.5)
  for name, d in pairs(best and best.mix or {}) do
    if port[shared.signal_type(name) .. "/" .. name] ~= d then same = false end
  end
  check("port page 3, Best composition: the best tested composition by lower bound of net gain, as doses (coal 5, not 3)",
    port["virtual/es-page"] == 3 and same and port["item/coal"] == 5,
    string.format("want %s (n %s, lo %.1f); port %s", best and best.key or "none", best and best.n or "-",
      best and best.lo or 0, serpent.line(port)))
  set_cc(c.cc, {{"recipe", "iron-gear-wheel", 1}, {"virtual", "es-page", 9}})
end)
on_nth_tick(CIRC + 181, function(event)
  if event.tick == 0 then return end
  local c = storage.circ
  local served = es("station_served", c.station.unit_number) or {}
  check("a page that does not exist serves page 0", served.page == 0, serpent.line(served))
  -- (0.72) The screening loop the four-page port was redesigned for: Screening on the port, a selector picking the
  -- strongest signal, a decider turning it into 1, back into the station's input on the green wire.
  set_cc(c.cc, {{"recipe", "iron-gear-wheel", 1}, {"virtual", "es-page", 1}})
  local s = c.station.surface
  local W = defines.wire_connector_id
  local sel = s.create_entity{name = "selector-combinator", position = {c.station.position.x - 3, c.station.position.y + 4},
    force = "player"}
  sel.get_or_create_control_behavior().parameters = {operation = "select", select_max = true, index_constant = 0}
  local dec = s.create_entity{name = "decider-combinator", position = {c.station.position.x - 1, c.station.position.y + 4},
    force = "player"}
  dec.get_or_create_control_behavior().parameters = {
    conditions = {{first_signal = {type = "virtual", name = "signal-each"}, comparator = ">", constant = 0}},
    outputs = {{signal = {type = "virtual", name = "signal-each"}, copy_count_from_input = false, constant = 1}}}
  local port = es("station", c.station.unit_number).port
  port.get_wire_connector(W.circuit_red, true).connect_to(sel.get_wire_connector(W.combinator_input_red, true), false)
  sel.get_wire_connector(W.combinator_output_red, true).connect_to(dec.get_wire_connector(W.combinator_input_red, true), false)
  dec.get_wire_connector(W.combinator_output_green, true).connect_to(c.station.get_wire_connector(W.circuit_green, true), false)
  -- (Combinators draw power; the circuit area had none, stations needing none.)
  local eei = s.create_entity{name = "electric-energy-interface", position = {c.station.position.x - 2, c.station.position.y + 7},
    force = "player"}
  eei.power_production, eei.electric_buffer_size = 1e7, 1e7
  s.create_entity{name = "medium-electric-pole", position = {c.station.position.x - 2, c.station.position.y + 5}, force = "player"}
  storage.circ.loop = {sel = sel, dec = dec}
end)
on_nth_tick(CIRC + 301, function(event)
  if event.tick == 0 then return end
  local c = storage.circ
  local served = es("station_served", c.station.unit_number) or {}
  local port = port_of(c.station.unit_number)
  local top, top_v = nil, -1
  for k, v in pairs(port) do
    if (k:find("^item/") or k:find("^fluid/")) and v > top_v then top, top_v = k, v end
  end
  local chosen = served.selected and (shared.signal_type(served.selected) .. "/" .. served.selected)
  check("a screening loop of a selector and a decider selects the additive with the most packs per sample",
    served.page == 1 and chosen ~= nil and port[chosen] == top_v,
    string.format("selected %s at %s; top %s at %d; selector %s, decider %s out %s", tostring(served.selected),
      tostring(chosen and port[chosen]), tostring(top), top_v, tostring(c.loop.sel.status), tostring(c.loop.dec.status),
      serpent.line(c.loop.dec.get_signals(defines.wire_connector_id.combinator_output_green))))
end)

on_nth_tick(END_TICK - 2400, function(event)
  if event.tick == 0 then return end
  es("set_legacy_stages", "player", false)
end)
local function gear_totals(effect)
  local n = 0
  for _, sm in pairs(es("station", storage.station.unit_number, "gear", effect).summaries) do n = n + (sm.n or 0) end
  return n
end
-- Space platforms (0.63): a platform with a dosed bench and a station, 40 s before the end; its samples
-- moved into the station every 5 s (no inserters on the test platform). (Its own interval: registering a
-- second handler for one interval replaces the first, which removed the staged-reveal step.)
on_nth_tick(END_TICK - 2390, function(event)
  if event.tick == 0 or storage.platform_set or not prototypes.item["space-platform-starter-pack"] then return end
  storage.platform_set = es("platform_setup")
end)
on_nth_tick(301, function(event)
  if storage.platform_set and not storage.platform_set.error then es("platform_move") end
end)
-- Hopper animations (0.72): a hopper that hands out a dose draws its iris (item) or its turning pump (fluid);
-- counted twice a second, the most seen at once kept.
on_nth_tick(29, function(event)
  storage.anim_seen = storage.anim_seen or {iris = 0, pump = 0}
  local n = {iris = 0, pump = 0}
  for _, o in pairs(rendering.get_all_objects("empirical-science")) do
    if o.valid and o.type == "animation" then
      local a = o.animation
      if a == "es-hopper-iris" then n.iris = n.iris + 1 elseif a and a:find("^es%-fluid%-hopper%-") then n.pump = n.pump + 1 end
    end
  end
  for k, v in pairs(n) do storage.anim_seen[k] = math.max(storage.anim_seen[k], v) end
end)
on_nth_tick(END_TICK - 61, function(event)
  if event.tick == 0 then return end
  local seen = storage.anim_seen or {}
  check("a hopper handing out a dose shows it: an item hopper's iris, a fluid hopper's pump",
    (seen.iris or 0) > 0 and (seen.pump or 0) > 0, "most at once: iris " .. (seen.iris or 0) .. ", pump " .. (seen.pump or 0))
end)
-- The circuit tips' scenes (0.67), each on a surface of its own as the Tips window gives it: built by the
-- same remote the scene calls, 80 s before the end, judged at the end.
on_nth_tick(END_TICK - 4801, function(event)
  if event.tick == 0 or storage.scenes then return end
  storage.scenes = {}
  -- Their own force, everything researched, as in the Tips window.
  local f = game.create_force("es-scenes")
  for _, t in pairs(f.technologies) do t.researched = true end
  for _, key in ipairs({"dose_signal", "dose_sweep", "adopt_best"}) do
    local s = game.create_surface("es-scene-" .. key)
    s.request_to_generate_chunks({0, 0}, 1); s.force_generate_chunk_requests()
    for _, e in pairs(s.find_entities_filtered{area = {{-30, -30}, {30, 30}}}) do e.destroy() end
    local tiles = {}
    for x = -30, 29 do for y = -30, 29 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
    s.set_tiles(tiles)
    local eei = s.create_entity{name = "electric-energy-interface", position = {-12, -8}, force = f}
    eei.power_production, eei.electric_buffer_size = 1e8, 1e8
    s.create_entity{name = "substation", position = {-6, -6}, force = f}
    s.create_entity{name = "substation", position = {6, -6}, force = f}
    -- Through the always-registered scenes interface, as the Tips window calls it (0.68: the test hooks
    -- interface is absent in a player's game and in a scene).
    storage.scenes[key] = {surface = s.name,
      camera = remote.call("empirical-science-scenes", "build_scene", key, s.name, nil, f.name)}
  end
end)
-- The egg (0.62): a second after it was set to spoil, what is left of it and what came out.
on_nth_tick(END_TICK - 1190, function(event)
  if event.tick == 0 or not storage.egg_set then return end
  storage.egg_early = es("egg_hatched")
end)
on_nth_tick(END_TICK - 1140, function(event)
  if event.tick == 0 or not storage.egg_set then return end
  storage.egg_result = es("egg_hatched")
end)
on_nth_tick(END_TICK - 1200, function(event)
  if event.tick == 0 then return end  -- (on_nth_tick also fires at tick 0)
  -- A pentapod egg nearly spoiled in a hopper (0.62); the report checks it hatched.
  if prototypes.item["pentapod-egg"] and not storage.egg_set then es("egg_hopper"); storage.egg_set = true end
  -- Scrap samples (0.60): three, nearly spoiled, in a chest; the report checks they are gone.
  if prototypes.item["es-scrap-sample"] and not storage.scrap_chest then
    storage.scrap_chest = game.surfaces.nauvis.create_entity{name = "wooden-chest", position = {-210, -200}, force = "player"}
    local cinv = storage.scrap_chest.get_inventory(defines.inventory.chest)
    cinv.insert{name = "es-scrap-sample", count = 3}
    cinv[1].spoil_percent = 0.9999
  end
  storage.staged_before = {yield = gear_totals("yield"), speed = gear_totals("speed")}
end)
-- The spent-full rig: fed and emptied here, its samples discarded (they would add to gear's stone:5).
-- The freshness rigs' inputs: half-spoiled mash and jelly, topped up (both rigs alike).
on_nth_tick(300, function(event)
  if event.tick == 0 or not storage.fresh or event.tick > END_TICK then return end
  -- Collect what the chests hold every 300 ticks (count and spoil sum), so stored products barely age:
  -- aging in a chest is the same for both and not scaled by the dose, so it skews a ratio of averages.
  for _, r in ipairs({storage.fresh.control, storage.fresh.dosed}) do
    local inv = r.chest.get_inventory(defines.inventory.chest)
    for i = 1, #inv do
      local st = inv[i]
      if st.valid_for_read and st.name == "bioflux" then
        r.n, r.sum = (r.n or 0) + st.count, (r.sum or 0) + st.spoil_percent * st.count
        -- (0.72) Per stack too: a craft's products share their spoilage, so a stack is the unit of spread.
        r.k, r.ks, r.kss = (r.k or 0) + 1, (r.ks or 0) + st.spoil_percent, (r.kss or 0) + st.spoil_percent ^ 2
        st.clear()
      end
    end
  end
  for _, r in ipairs(storage.fresh_benches or {}) do
    local inv = r.entity.get_inventory(defines.inventory.crafter_input)
    -- 0.3 spoiled: stale enough to show a restoration, under shared.spoil_fail (a trial fails at 0.5).
    for name, n in pairs({["yumako-mash"] = 90, jelly = 72}) do
      local have = inv.get_item_count(name)
      if have < n then inv.insert{name = name, count = n - have, spoil_percent = 0.3} end
    end
  end
end)
-- The biochambers get one craft's ingredients at a time, at 0.5 spoiled: with a stock, the dosed one's
-- speed effect changed how long ingredients waited, so the two inherited different spoilage.
on_nth_tick(20, function(event)
  if event.tick == 0 or not storage.fresh or event.tick > END_TICK then return end
  for _, r in ipairs({storage.fresh.control, storage.fresh.dosed}) do
    local inv = r.entity.get_inventory(defines.inventory.crafter_input)
    if inv.get_item_count("yumako-mash") == 0 and inv.get_item_count("jelly") == 0 then
      inv.insert{name = "yumako-mash", count = 15, spoil_percent = 0.5}
      inv.insert{name = "jelly", count = 12, spoil_percent = 0.5}
    end
  end
end)

on_nth_tick(90, function(event)
  if event.tick == 0 or event.tick > END_TICK then return end
  local r = storage.spent_rig
  feed(r.entity)
  r.chest.get_inventory(defines.inventory.chest).clear()
  for _, x in ipairs({storage.mix_rig}) do
    feed(x.entity)
    local out = x.chest.get_inventory(defines.inventory.chest)
    for _, res in ipairs({"es-spent-coal", "es-spent-stone"}) do
      x.residues[res] = (x.residues[res] or 0) + out.get_item_count(res)
    end
    out.clear()
    for item, h in pairs({coal = x.coal, stone = x.stone}) do
      local inv = h.get_inventory(defines.inventory.chest)
      if inv.get_item_count(item) < 30 then inv.insert{name = item, count = 30 - inv.get_item_count(item)} end
    end
  end
  local st = r.hopper.get_inventory(defines.inventory.chest)
  if st.get_item_count("stone") < 30 then st.insert{name = "stone", count = 30} end
end)

-- The hidden consumer takes power from the vanilla interface that runs this map, as from any network
-- (0.46.1: at "tertiary" it took nothing and showed a no-power icon). Set early so a poll restores the
-- machine's own power before the checks at END_TICK + 120.
-- Forced on the tick right after the machine's own poll (its slot: unit % 60) and read two ticks later, so no
-- poll restores its power in between (0.71: at fixed ticks, a shift in unit numbers put a poll there); then
-- restored, as the next poll would, before the checks.
on_nth_tick(END_TICK + 30, function(event)
  if event.tick == 0 then return end
  local unit = storage.P.speed.entity.unit_number
  local f = event.tick + 1
  while f % 60 ~= (unit + 1) % 60 do f = f + 1 end
  on_nth_tick(f, function() es("force_power_draw", unit, 1000) end)
  on_nth_tick(f + 2, function()
    storage.forced_power = es("crafter_state", unit)
    es("restore_power", unit)   -- (as its next poll would, before the checks read its power)
  end)
end)

on_nth_tick(END_TICK - 1507, function(event)
  if event.tick == 0 or storage.redose_at then return end
  local m = storage.P.redose.entity
  storage.redose_at = m.products_finished
  es("set_dose", m.unit_number, {rows = rows_of({stone = 3})})
  storage.P.redose.doses = {stone = 3}
end)
on_nth_tick(END_TICK - 600, function(event)
  if event.tick == 0 then return end
  -- The machine with full trash, seen waiting, then given room (and an empty output): its warning must
  -- clear by the end.
  local r = storage.spent_rig
  storage.spent_seen = {trash = es("trash_full", r.entity.unit_number), status = es("dose_state", r.entity.unit_number).status}
  r.entity.get_inventory(defines.inventory.crafter_trash).clear()
  r.entity.get_inventory(defines.inventory.crafter_output).clear()
end)

on_nth_tick(END_TICK + 60, function(event)
  if event.tick == 0 then return end
  local h = storage.hopper_to_remove
  -- (0.71: no hopper carries a hidden fluid port any more; none should exist anywhere.)
  storage.hidden_ports = 0
  for _, surf in pairs(game.surfaces) do
    storage.hidden_ports = storage.hidden_ports + surf.count_entities_filtered{name = "es-hopper-fluid-port"}
  end
  h.destroy{raise_destroy = true}
  -- Staged reveal: the grant revoked, Mixtures unresearched. Samples from now on record yield only; a second dose
  -- row and circuit mode wait.
  local techs = game.forces.player.technologies
  techs["es-mixtures"].researched = false
  local cu = storage.rigs.circuit.entity.unit_number
  local circuit_mix = es("dose_state", cu).mix
  es("set_dose", cu, {rows = {{name = "coal", dose = 2}, {name = "stone", dose = 3}}})
  local rows_mix, k = es("dose_state", cu).mix or {}, 0
  for _ in pairs(rows_mix) do k = k + 1 end
  storage.staged_doses = {circuit = circuit_mix == nil, one = k == 1 and rows_mix.coal == 2}
  techs["es-mixtures"].researched = true
  -- One of the two machines sharing a hopper goes: the hopper redraws its chutes.
  storage.chutes_before = es("chutes", storage.shared_hopper.unit_number)
  storage.bridges_before = es("bridges", storage.shared_hopper.unit_number)
  storage.P.pair_b.entity.destroy{raise_destroy = true}
end)

-- 0.72: a bench with speed modules crafts faster than one without (its base, assembling machine 1, ignores
-- modules; the bench had slots and no effect). Built off the lab, compared at the end.
-- (Three analysis periods after the quality stations were built, at tick 0 by nth-tick 61's first firing:
-- before either runs out of samples.)
on_nth_tick(31, function(event)
  if event.tick == 0 or storage.q_counts or not storage.q_stations then return end
  storage.q_counts = {es("station", storage.q_stations[1].unit_number).analysed,
    es("station", storage.q_stations[2].unit_number).analysed}
end)

-- (Mid-run, while the lab's main station is busy: its animation, counted at the end.)
on_nth_tick(307, function(event)
  -- (Sampled through the run: at the test's pace a station empties its four waiting slots in seconds, and its
  -- animation rightly stops between bursts. Any moment with it running counts.)
  if event.tick == 0 or (storage.anim_busy or 0) > 0 then return end
  storage.anim_busy = 0
  for _, o in pairs(rendering.get_all_objects("empirical-science")) do
    if o.valid and o.type == "animation" and o.target and o.target.entity == storage.station then
      storage.anim_busy = storage.anim_busy + 1
    end
  end
end)

on_nth_tick(61, function(event)
  if storage.moduled then return end
  -- 0.72: a legendary station analyses faster, by the quality's lab research speed. Two stations, each with
  -- tagged red samples and packs; counted at the end.
  if prototypes.quality.legendary then
    storage.q_stations = {}
    for i, q in ipairs({"normal", "legendary"}) do
      local st = game.surfaces.nauvis.create_entity{name = "es-analysis-station", position = {-300 + 8 * i, 340},
        force = "player", quality = q, raise_built = true}
      es("station_any", st.unit_number)
      local inv = st.get_inventory(defines.inventory.chest)
      for _ = 1, 20 do inv.insert{name = RED_SAMPLE, count = 1, tags = {target = "gear", additive = "", dose = 0, y = 100, v = 3}} end
      inv.insert{name = "automation-science-pack", count = 50}
      storage.q_stations[i] = st
    end
  end
  -- 0.72: a station's waiting slots take the samples of the science packs it holds, four in all: red packs
  -- only, red samples only; red and green, two of each. Measured on stations of their own, in the real layout.
  do
    local green = shared.sample_of("logistic-science-pack")
    local function station_with(packs, x)
      local st = game.surfaces.nauvis.create_entity{name = "es-analysis-station", position = {x, 320}, force = "player",
        raise_built = true}
      local inv = st.get_inventory(defines.inventory.chest)
      for _, p in ipairs(packs) do inv.insert{name = p, count = 10} end
      es("station_refilter", st.unit_number)
      local red_in, green_in = 0, 0
      for _ = 1, 6 do
        red_in = red_in + inv.insert{name = RED_SAMPLE, count = 1, tags = {target = "gear", additive = "", dose = 0, y = 100, v = 3}}
      end
      for _ = 1, 6 do green_in = green_in + inv.insert{name = green, count = 1} end
      return {red = red_in, green = green_in, size = #inv}
    end
    storage.tier_check = {red_only = station_with({"automation-science-pack"}, -300),
      both = station_with({"automation-science-pack", "logistic-science-pack"}, -290)}
  end
  local s = game.surfaces.nauvis
  storage.moduled = {}
  for i, n in ipairs({0, 2}) do
    local b = s.create_entity{name = "es-test-bench", position = {-300 + 6 * i, 300}, force = "player"}
    b.set_recipe("es-trial-gear-control")
    if n > 0 then b.get_module_inventory().insert{name = "speed-module", count = n} end
    storage.moduled[i] = b
  end
end)

on_nth_tick(END_TICK + 120, function(event)
  if event.tick == 0 then return end
  -- 0.72: a station shows the working animation while it analyses, none while it waits (no packs).
  do
    local function anims(e)
      local n = 0
      for _, o in pairs(rendering.get_all_objects("empirical-science")) do
        if o.valid and o.type == "animation" and o.target and o.target.entity == e then n = n + 1 end
      end
      return n
    end
    local busy, idle = storage.anim_busy or -1, anims(storage.alert_starved)
    check("a working station shows its animation, an idle one none", busy == 1 and idle == 0,
      string.format("working %d, idle %d", busy, idle))
  end
  do  -- 0.72: the Progress tab's record, a snapshot every shared.progress_ticks
    local P = es("progress", "player")
    local tiers = 0
    for _ in pairs(P and P.tiers or {}) do tiers = tiers + 1 end
    check("progress is recorded: snapshots over the run, samples by science pack, packs made rising, dosed products counted",
      P and #P.t >= 2 and tiers >= 1 and P.data[#P.t] >= P.data[1] and (P.dosed[#P.t] or 0) > 0,
      P and string.format("%d snapshots, %d packs of samples, packs made %s, dosed %s, extra %s", #P.t, tiers,
        serpent.line(P.data), serpent.line(P.dosed), serpent.line(P.extra)) or "none")
  end
  if storage.q_counts then
    local normal, legend = storage.q_counts[1], storage.q_counts[2]
    local m = prototypes.quality.legendary.lab_research_speed_multiplier
    check("a legendary station analyses faster, by the quality's lab research speed",
      normal > 0 and legend < 10 and math.abs(legend / normal - m) < 0.4,
      string.format("normal %d, legendary %d (x%.1f expected)", normal, legend, m))
  end
  do
    local t = storage.tier_check or {}
    check("a station's four waiting slots take the samples of the packs it holds: red only, or two red and two green",
      t.red_only and t.red_only.red == 4 and t.red_only.green == 0 and t.both.red == 2 and t.both.green == 2
        and t.red_only.size <= 24,
      serpent.line(t))
  end
  do
    local plain, fast = storage.moduled and storage.moduled[1], storage.moduled and storage.moduled[2]
    check("speed modules speed a test bench up", plain and fast and fast.crafting_speed > plain.crafting_speed * 1.2,
      plain and fast and string.format("%.3f with modules, %.3f without", fast.crafting_speed, plain.crafting_speed))
  end
  -- 0.72: the screen lists what the force can make or has evidence on; nothing with evidence is left off.
  do
    local unlisted = es("unlisted_evidence", "player")
    check("every additive with evidence is listed on the screen", #unlisted == 0, table.concat(unlisted, ", "))
  end
  do
    local function totals(effect)
      local n = 0
      for _, sm in pairs(es("station", storage.station.unit_number, "gear", effect).summaries) do n = n + (sm.n or 0) end
      return n
    end
    local b, sd = storage.staged_before, storage.staged_doses
    local y, s = totals("yield"), totals("speed")
    check("before Precision instruments 1, samples record yield only", y > b.yield and s == b.speed,
      string.format("yield n %d -> %d, speed n %d -> %d", b.yield, y, b.speed, s))
    check("before their stage: circuit mode waits, one dose row counts",
      sd.circuit and sd.one, string.format("circuit %s, one row %s", tostring(sd.circuit), tostring(sd.one)))
    es("set_legacy_stages", "player", true)
  end
  do
    local seen, r = storage.spent_seen, storage.spent_rig
    local now = es("trash_full", r.entity.unit_number)
    check("a machine with no room for residues waits, shows a warning and says why",
      seen.trash.full == "es-spent-stone" and seen.trash.icon and seen.status and seen.status[1] == "es.dose-spent-full",
      serpent.line(seen))
    check("the warning clears once the machine has room", not now.full and not now.icon, serpent.line(now))
    local function n(h, item) return h.get_inventory(defines.inventory.chest).get_item_count(item) end
    local m = storage.mix_rig
    local in_hoppers = n(m.coal, "es-spent-coal") + n(m.coal, "es-spent-stone") + n(m.stone, "es-spent-coal")
      + n(m.stone, "es-spent-stone")
    check("a mixture's residues leave with the products; the hoppers get none",
      (m.residues["es-spent-coal"] or 0) > 0 and (m.residues["es-spent-stone"] or 0) > 0 and in_hoppers == 0,
      string.format("out: coal residue %d, stone residue %d; in hoppers %d", m.residues["es-spent-coal"] or 0,
        m.residues["es-spent-stone"] or 0, in_hoppers))
    -- Picker and targets for a force with only the method: no sulfur (no recipe), no coal until it has
    -- produced some; no engine target until engines are researched.
    local novice = game.forces.novice or game.create_force("novice")
    novice.technologies["es-empirical-method"].researched = true
    local before, targets = es("pickable", "novice"), es("targets_for", "novice")
    novice.get_item_production_statistics(game.surfaces.nauvis).on_flow("coal", 1)
    local after = es("pickable", "novice")
    local ash_before = before["es-spent-coal"]
    novice.get_item_production_statistics(game.surfaces.nauvis).on_flow("es-spent-coal", 1)
    check("a residue is offered once some has been made; dosing records residue as produced",
      not ash_before and es("pickable", "novice")["es-spent-coal"]
        and game.forces.player.get_item_production_statistics(game.surfaces.nauvis).get_input_count("es-spent-stone") > 0,
      string.format("ash before %s, after %s; gravel produced %d", tostring(ash_before),
        tostring(es("pickable", "novice")["es-spent-coal"]),
        game.forces.player.get_item_production_statistics(game.surfaces.nauvis).get_input_count("es-spent-stone")))
    check("the dose picker offers only what the force can make",
      not before.coal and after.coal and not before.sulfur and not after.sulfur,
      string.format("coal %s -> %s, sulfur %s", tostring(before.coal), tostring(after.coal), tostring(before.sulfur)))
    if storage.agent then
      local a = storage.agent
      local pool = es("quality_pool", "player", "gear")
      local q = pool[a.name .. ":" .. a.dose] or {k = 0, b = 0}
      local p = q.b > 0 and q.k / q.b or 0
      local se = math.sqrt(a.chance * (1 - a.chance) / math.max(q.b, 1))
      check("a quality agent's samples count upgrades at its hidden chance",
        q.b >= 200 and math.abs(p - a.chance) < 3 * se,
        string.format("%s x%d: %d of %d upgraded (%.1f%%), true %.1f%%", a.name, a.dose, q.k, q.b, 100 * p, 100 * a.chance))
      local stray = {}
      for key in pairs(pool) do
        local agent_in = false
        for part in key:gmatch("[^+]+") do if shared.is_agent(part:match("^([^:]+)")) then agent_in = true end end
        if not agent_in then table.insert(stray, key) end
      end
      check("only compositions with a quality agent record quality", #stray == 0, table.concat(stray, ", "))
      -- Research data for an agent: its quality question (Wilson half-width against the quality band).
      local akey = a.name .. ":" .. a.dose
      local _, lo, hi = es("wilson", q.k, q.b)
      local o = hi and math.min(1, ((hi - lo) / 2 / shared.data.quality_band) ^ 2) or 1
      local floor = es("floor_parts", "gear").floor  -- (0.72: each target's own floor)
      local want = floor + (1 - floor) * o
      local got = es("data_rate", "player", "gear", akey)
      -- (The force remembers the lowest openness reached, so the rate is at most the current question's: a
      -- Wilson interval can widen again as the rate moves toward one half. 0.71: assumed equal, it failed on a
      -- stream where it had, 0.369 paid against 0.398 now.)
      check("an agent's sample is paid on its quality question, at its lowest openness reached",
        got <= want + 0.02 and got >= floor - 1e-9,
        string.format("rate %.3f, quality rule now %.3f, floor %.3f", got, want, floor))
      -- The port's Q: the best upgrade rate among agents on its target (per mille).
      es("set_view_target", storage.station.unit_number, "gear")
      local port = es("station", storage.station.unit_number, "gear").port
      local qsig
      for _, f in pairs(port.get_control_behavior().get_section(1).filters) do
        if f.value.name == "es-quality" then qsig = f.min end
      end
      local best_q = 0
      for _, qq in pairs(pool) do
        if qq.b >= shared.quality_min_units then best_q = math.max(best_q, math.floor(qq.k / qq.b * 1000 + 0.5)) end
      end
      check("the station port sends the best upgrade rate (es-quality)", qsig ~= nil and qsig == best_q,
        string.format("es-quality %s, expected %d", tostring(qsig), best_q))
    end
    check("the screen lists only targets whose trial is unlocked", targets.gear and not targets.engine,
      string.format("gear %s, engine %s (engine trial enabled %s)", tostring(targets.gear), tostring(targets.engine),
        tostring(novice.recipes["es-trial-engine-control"].enabled)))
  end
  stats_selftest()
  regression_selftest()
  shapes_selftest()

  local truth = es("truth")
  for name, x in pairs(truth.targets.gear) do
    info(string.format("truth gear/%-12s %-9s %-9s peak=%.3f opt=%.2f", name, x.kind, x.shape, x.peak, x.opt))
  end
  local st = es("station", storage.station.unit_number, "gear")
  for _, key in ipairs({"control", "coal:3", "stone:5", "wood:5", "copper-cable:4"}) do
    local s = st.summaries[key]
    local add, dose = key:match("^(.+):(%d+)$")
    info(string.format("gear %-15s n=%3d mean=%+6.1f%% true=%+.1f%%", key, s and s.n or 0, (s and s.mean or 0) / 10,
      es("gain", "gear", add, tonumber(dose or 0)) * 100))
    if s and s.n >= 2 then
      local true_permille = es("gain", "gear", add, tonumber(dose or 0)) * 1000
      check("gear " .. key .. " estimate near truth", math.abs(s.mean - true_permille) < 4 * math.sqrt(s.var / s.n),
        string.format("%.0f vs %.0f (sd %.0f, n %d)", s.mean, true_permille, math.sqrt(s.var), s.n))
    else
      check("gear " .. key .. " has data", false, s and s.n)
    end
  end

  for _, name in ipairs({"control", "honest"}) do
    local r = storage.rigs[name]
    info(string.format("rig %s: control samples %d, mean y %.1f%%", name, r.keys.control or 0,
      (r.ysum and r.ysum.control or 0) / math.max(r.keys.control or 1, 1)))
  end
  local ns = es("normal_stats", 100000)
  info(string.format("trial-noise generator: 100000 normal draws, mean %+.4f, sd %.4f", ns.mean, ns.sd))
  -- Samples.
  check("no missed tags", es("missed_tags") == 0, es("missed_tags"))
  local untagged = 0
  for _, r in pairs(storage.rigs) do untagged = untagged + r.untagged end
  check("all delivered samples tagged", untagged == 0, untagged)
  check("untagged sample discarded", st.unreadable == 1, st.unreadable)

  -- Trials take their dose from the hopper; destructive: survivors come out, spent comes back.
  local function by(r, name) return r.items[name] or 0 end
  local stone = storage.rigs.stone
  -- At most the last trial's survivors are still on their way (bench output, inserter hand, chest).
  local got, each = by(stone, "iron-gear-wheel"), gear_survivors()
  check("gear trials return their survivors each", each > 0 and got <= each * stone.trials
    and got >= each * (stone.trials - 1),
    string.format("%d gears for %d trials, %d each", got, stone.trials, each))
  check("dosed trials: 5 stone taken and 5 gravel out per trial",
    stone.trials > 30 and stone.spent >= 5 * (stone.trials - 1) and stone.spent <= 5 * (stone.trials + 2)
    and (stone.put.stone - stone.hopper.get_inventory(defines.inventory.chest).get_item_count("stone")) - stone.spent <= 10,
    string.format("%d trials, %d spent back, %d stone taken", stone.trials, stone.spent,
      stone.put.stone - stone.hopper.get_inventory(defines.inventory.chest).get_item_count("stone")))
  check("control trials return no spent additive", storage.rigs.control.spent == 0)
  local honest = storage.rigs.honest
  check("a bench whose hopper is empty makes control samples, labelled so", honest.trials > 20
    and (honest.keys.dosed or 0) == 0 and es("dose_state", honest.entity.unit_number).status[1] == "es.dose-missing",
    serpent.line(honest.keys) .. " " .. serpent.line(es("dose_state", honest.entity.unit_number).status))

  -- Pack tiers: engine samples cost green, and wait for it.
  local station_inv = storage.station.get_inventory(defines.inventory.chest)
  check("gear samples cost red", es("target_pack", "gear") == "automation-science-pack", es("target_pack", "gear"))
  check("engine samples cost green", es("target_pack", "engine") == "logistic-science-pack", es("target_pack", "engine"))
  check("engine samples waited for green", storage.engine_waiting_before_green > 0, storage.engine_waiting_before_green)
  local eng = es("station", storage.station.unit_number, "engine")
  local green_used = storage.green_fed - station_inv.get_item_count("logistic-science-pack")
  local en = eng.summaries["coal:2"] and eng.summaries["coal:2"].n or 0
  check("engine samples analysed once green arrived", en > 0, en)
  -- Plastic samples cost green too (its tier): packs are shared by every green-tier sample.
  local pn = 0
  for _, sm in pairs(es("station", storage.station.unit_number, "plastic").summaries) do pn = pn + (sm.n or 0) end
  check("one green pack per four green-tier samples (engines and plastic)", green_used == math.ceil((en + pn) / 4),
    string.format("%d green used, %d engine + %d plastic samples", green_used, en, pn))

  -- Circuit mode: the bench doses what the wire says (stone 4), not its panel rows (coal 9).
  local cs = es("station", storage.station.unit_number, "circuit")
  check("circuit mode doses from the wire, not the rows", (cs.summaries["stone:4"] and cs.summaries["stone:4"].n or 0) > 10
    and not cs.summaries["coal:9"], serpent.line(cs.summaries["stone:4"]))

  -- Station accounting (all targets).
  local waiting = 0
  for _, it in pairs(station_inv.get_contents()) do if shared.is_sample(it.name) then waiting = waiting + it.count end end
  local runs_failed = es("station", storage.station.unit_number).failed  -- (not `failed`: that is the test's count)
  check("analysed + waiting + unreadable + failed = fed",
    st.analysed + waiting + st.unreadable + runs_failed == storage.samples_fed + 1,
    string.format("%d + %d + %d + %d vs %d+1", st.analysed, waiting, st.unreadable, runs_failed, storage.samples_fed))
  local outputs = {}
  for _, f in pairs(st.port.get_control_behavior().get_section(1).filters) do outputs[f.value.name] = f.min end
  -- (0.72) es-n on page 0: the samples on the port's target, from the force's pool.
  local pool_n = 0
  for _, sm in pairs(es("station", storage.station.unit_number, st.view_target).summaries) do pool_n = pool_n + (sm.n or 0) end
  check("port page 0 sends the target's samples (es-n), from the force's pool", outputs["es-n"] == pool_n and pool_n > 0,
    tostring(outputs["es-n"]) .. " vs " .. pool_n)
  -- A port switched to its own station reads that station's history only.
  local s2 = es("station", storage.station2.unit_number)
  es("set_port_source", storage.station2.unit_number, "station")
  local own = {}
  for _, f in pairs(s2.port.get_control_behavior().get_section(1).filters) do own[f.value.name] = f.min end
  local served2 = (es("station_served", storage.station2.unit_number) or {}).target or "gear"
  local own_n = 0
  for _, sm in pairs(es("station_history", storage.station2.unit_number, served2)) do own_n = own_n + (sm.n or 0) end
  local pool2_n = 0
  for _, sm in pairs(es("station", storage.station2.unit_number, served2).summaries) do pool2_n = pool2_n + (sm.n or 0) end
  check("a port set to its own station outputs that station's evidence only",
    own_n > 0 and own_n < pool2_n and own["es-n"] == own_n,
    string.format("es-n %s, station %d, force %d", tostring(own["es-n"]), own_n, pool2_n))
  -- Quality packs.
  local qinv = storage.qstation.get_inventory(defines.inventory.chest)
  check("a station accepts and spends a pack of higher quality",
    storage.quality_pack_inserted == 1 and es("station", storage.qstation.unit_number).analysed == 1
      and qinv.get_item_count({name = "automation-science-pack", quality = "uncommon"}) == 0,
    string.format("inserted %d, analysed %d", storage.quality_pack_inserted, es("station", storage.qstation.unit_number).analysed))
  -- Station wires in blueprints: the tags a station carries rebuild its port's wire, through a ghost.
  local wst = place("es-analysis-station", 60, 40)
  local wport = es("station", wst.unit_number).port
  local comb = place("constant-combinator", 64, 40)
  wport.get_wire_connector(defines.wire_connector_id.circuit_red, true)
    .connect_to(comb.get_wire_connector(defines.wire_connector_id.circuit_red, true), false)
  local tags = es("port_wire_tags", wst.unit_number)
  local g1 = game.surfaces[1].create_entity{name = "entity-ghost", inner_name = "constant-combinator", position = {64, 30},
    force = "player"}
  local g2 = game.surfaces[1].create_entity{name = "entity-ghost", inner_name = "es-analysis-station", position = {60, 30},
    force = "player", tags = {es_port_wires = tags}}
  local _, built = g2.revive{raise_revive = true}
  local _, comb2 = g1.revive{raise_revive = true}
  local port2 = built and es("station", built.unit_number).port
  local red = port2 and port2.get_wire_connector(defines.wire_connector_id.circuit_red, false)
  check("a station built from blueprint tags rewires its port (to a ghost, kept when revived)",
    tags ~= nil and red ~= nil and comb2 ~= nil
      and red.is_connected_to(comb2.get_wire_connector(defines.wire_connector_id.circuit_red, true)),
    serpent.line(tags))

  -- Regression on the sweep's real data.
  local a = storage.activator
  for _, model in ipairs({"quadratic", "saturating", "linear", "threshold"}) do
    local f = es("fit", storage.station.unit_number, "gear", a, model)
    check("fit " .. model .. " on sweep data", f.error == nil and f.best_dose >= 0 and f.best_dose <= 9,
      f.error or string.format("best dose %.1f gain %+.1f%% R2 %.2f LOF p %s", f.best_dose, f.best_gain / 10,
        f.r2 or -1, f.lof_p and string.format("%.3f", f.lof_p) or "-"))
  end

  -- Fluids and mixtures on benches: estimates near the truth; two fluids from two hoppers.
  for _, key in ipairs({"lubricant:40", "sulfur:3"}) do
    local s = st.summaries[key]
    local name, dose = key:match("^(.+):(%d+)$")
    local true_permille = es("gain", "gear", name, tonumber(dose)) * 1000
    check("station estimate for " .. key .. " near truth", s and s.n > 10
      and math.abs(s.mean - true_permille) < 4 * math.sqrt(s.var / s.n),
      s and string.format("n=%d %.0f vs %.0f", s.n, s.mean, true_permille) or "no data")
  end
  local s2 = st.summaries["lubricant:30+water:20"]
  check("two fluids, one per hopper, dose one bench", s2 and s2.n > 10, s2 and s2.n)


  -- Production: a dosed machine's output follows the true gain, from independent parts.
  local P = storage.P
  local g = es("gain", "gear", a, storage.best_dose)
  local function follows(r, per_craft, gain, tol)
    local exp = r.crafts * per_craft * (1 + gain)
    return math.abs(r.made - exp) <= 2 + (tol or 0.02) * exp, string.format("%d crafts, %d vs %.0f", r.crafts, r.made, exp)
  end
  info(string.format("production %s x%d on gears: true gain %+.1f%%", a, storage.best_dose, g * 100))
  local ok, detail = follows(P.ind, 1, g)
  check("dosed production follows the true gain", P.ind.crafts > 100 and ok, detail)
  local taken = P.ind.put[a] - P.ind.hopper.get_inventory(defines.inventory.chest).get_item_count(a)
  check("a dose consumed per batch of products, as on the bench",
    math.abs(taken - storage.best_dose * P.ind.crafts / GEAR_BATCH) <= storage.best_dose + 1,
    string.format("%d taken for %d crafts (dose %d per %d)", taken, P.ind.crafts, storage.best_dose, GEAR_BATCH))
  check("one residue leaves the machine per unit taken", taken - P.ind.spent >= 0 and taken - P.ind.spent <= 2 * storage.best_dose,
    string.format("%d spent, %d taken", P.ind.spent, taken))
  local qr = P.quality
  if P.agent then
    local made, up = 0, 0
    local by = {}
    for _, inv in ipairs({P.agent.chest.get_inventory(defines.inventory.chest),
                          P.agent.entity.get_inventory(defines.inventory.crafter_output)}) do
      for _, item in pairs(inv.get_contents()) do
        if item.name == "iron-gear-wheel" then
          made = made + item.count
          by[item.quality] = (by[item.quality] or 0) + item.count
          if item.quality ~= "normal" then up = up + item.count end
        end
      end
    end
    P.agent.by_quality = by
    local c = storage.agent.chance
    -- Against the products that were dosed (a machine short of its dose rolls nothing; 7% here, early on).
    local cs = es("crafter_state", P.agent.entity.unit_number)
    local dosed = math.max(cs.quality_rolled or 0, 1)
    local se = math.sqrt(c * (1 - c) / dosed)
    -- (0.71) Every upgrade earned is paid, or owed to the next crafts: none lost past the owed cap.
    check("a quality agent's upgrades are all paid or still owed (none lost)",
      cs.quality_earned == cs.upgraded_total + (cs.quality_owed or 0) and (cs.quality_lost or 0) == 0,
      string.format("earned %s, paid %s, owed %s, lost %s", tostring(cs.quality_earned), tostring(cs.upgraded_total),
        tostring(cs.quality_owed), tostring(cs.quality_lost)))
    -- Four standard errors (0.71): the rolls come from a seeded generator, so a seed whose draw sits past three
    -- fails every run (the default seed drew 7 of 698 at 2.95%, 3.0 below); four fail once in about 16,000.
    check("a quality agent upgrades production at its hidden chance", made >= 600 and math.abs(up / dosed - c) < 4 * se,
      string.format("%d of %d dosed gears upgraded (%.1f%%; %d made), true %.1f%%: %s; crafter %s; dose %s", up, dosed,
        100 * up / dosed, made, 100 * c,
        serpent.line(P.agent.by_quality), serpent.line(es("crafter_state", P.agent.entity.unit_number)),
        serpent.line(es("dose_state", P.agent.entity.unit_number))) .. string.format("; gain_on %.4f, speed %.4f",
        es("gain_on", "gear", {[storage.agent.name] = storage.agent.dose}),
        es("effect_on", "gear", {[storage.agent.name] = storage.agent.dose}, "speed")))
    -- (P.real: below.)
    local plain_up = 0
    for q, c2 in pairs(P.ind.by_quality) do if q ~= "normal" then plain_up = plain_up + c2 end end
    check("an ordinary dose never changes quality", plain_up == 0 and P.ind.made > 0, serpent.line(P.ind.by_quality))
    -- An inserter-fed machine whose yield is negative pays it in inputs, once (owing it again each poll
    -- had taken 268 plates where 64 were due, starving the machine).
    local ga = es("gain_on", "gear", {[storage.agent.name] = storage.agent.dose})
    local cs = es("crafter_state", P.agent.entity.unit_number)
    -- Paid from the output first, then the inputs, depending on what the poll finds (the share depends
    -- on poll timing, 0.49: a shifted bucket paid it all in products): in plates, a gear owed is two
    -- plates at the dosed yield.
    local due = ga < 0 and 2 * cs.last * -ga / (1 + ga) or 0
    local paid = cs.inputs_taken + cs.outputs_taken * 2 / (1 + ga)
    check("a fed machine with a negative yield pays it once (in products or inputs)",
      ga >= 0 or math.abs(paid - due) <= math.max(4, 0.2 * due),
      string.format("%.0f plates' worth paid (%d plates, %d gears), %.0f due (yield %+.1f%%, %d crafts)", paid,
        cs.inputs_taken, cs.outputs_taken, due, 100 * ga, cs.last))
    -- (P.slow is topped up by the loop like the others unless no_feed; its stock was given once.)
    local se2 = P.slow.entity
    local left = se2.get_inventory(defines.inventory.crafter_input).get_item_count("iron-plate")
    local crafts = se2.products_finished + (se2.is_crafting() and 1 or 0)
    local taken = es("crafter_state", se2.unit_number).inputs_taken
    local used = P.slow.stock - left
    check("a slowed machine loses no ingredients (every plate is in a gear or taken by the yield path)",
      used == 2 * crafts + taken and es("effect_on", "gear", {[storage.agent.name] = storage.agent.dose}, "speed") < -0.05,
      string.format("%d plates used: %d crafts x 2 + %d taken by yield", used, crafts, taken))
  end
  if P.real then
    local made = P.real.chest.get_inventory(defines.inventory.chest).get_item_count("iron-gear-wheel")
      + P.real.entity.get_inventory(defines.inventory.crafter_output).get_item_count("iron-gear-wheel")
    local crafts = P.real.entity.products_finished
    local exp = crafts * (1 + g)
    check("through inserters, a dosed machine's output follows the true gain", math.abs(made - exp) <= 2 + 0.02 * exp,
      string.format("%d crafts, %d gears vs %.0f expected (gain %+.1f%%)", crafts, made, exp, 100 * g))
  end
  check("extra products take the craft's quality", (qr.by_quality.normal or 0) == 0 and (qr.by_quality.uncommon or 0) > qr.crafts,
    string.format("%d crafts: %s", qr.crafts, serpent.line(qr.by_quality)))
  ok, detail = follows(P.module, 1, g, 0.03)
  check("quality modules: extra products still follow the true gain", P.module.crafts > 50 and ok, detail)
  ok, detail = follows(P.pair_a, 1, g)
  local ok_b, detail_b = follows(P.pair_b, 1, g)
  check("one hopper doses both machines it touches", ok and ok_b and P.pair_a.crafts > 50, detail .. "; " .. detail_b)
  check("no hopper: no effect, and the panel says so", P.none.made == P.none.crafts
    and es("dose_state", P.none.entity.unit_number).status[1] == "es.dose-no-hopper",
    string.format("%d made, %d crafts", P.none.made, P.none.crafts))
  check("empty hopper: no effect, and the panel says so", P.empty.made == P.empty.crafts
    and es("dose_state", P.empty.entity.unit_number).status[1] == "es.dose-missing",
    string.format("%d made, %d crafts", P.empty.made, P.empty.crafts))
  -- Output checks hold for gains only: a loss is taken from the inputs once inserters have taken the
  -- products (as for routes and furnaces above).
  local mg = es("gain_mix", "circuit", {sulfur = 3, lubricant = 40})
  ok, detail = follows(P.mixture, 1, mg)
  if mg >= 0 then
    check("a mixture with a fluid doses a circuit line", P.mixture.crafts > 20 and ok, detail)
  else
    check("a mixture with a fluid doses a circuit line (a loss on this map: dosed, taken from inputs)",
      P.mixture.crafts > 20 and es("dose_state", P.mixture.entity.unit_number).mix ~= nil,
      string.format("true gain %+.1f%%; %s", mg * 100, detail))
  end
  local steel_g = es("gain", "steel", "coal", 3)
  ok, detail = follows(P.steel, 1, steel_g)
  -- (A loss may come out of the inputs when output is collected before the mod's poll: compared on gains.)
  check("a furnace is dosed too (steel)", P.steel.crafts > 10 and (steel_g < 0 or ok), detail)
  for _, name in ipairs({"pair_mix", "pair_a", "pair_b", "premix", "auto0", "auto3"}) do
    local r = storage.rigs[name]
    local status
    for sname, v in pairs(defines.entity_status) do if v == r.entity.status then status = sname end end
    info(string.format("rig %s: %d trials, status %s, dose %s, hopper %s", name, r.trials, tostring(status),
      serpent.line(es("dose_state", r.entity.unit_number).status), serpent.line(r.hopper.get_inventory(defines.inventory.chest).get_contents())))
  end
  local residue_in_shared = 0
  for _, it in pairs(storage.shared_hopper.get_inventory(defines.inventory.chest).get_contents()) do
    if it.name:find("^es%-spent%-") then residue_in_shared = residue_in_shared + it.count end
  end
  check("a machine on the shared hopper sends its residues out; none lands in the hopper",
    P.pair_a.spent > 0 and residue_in_shared == 0,
    string.format("pair a sent %d; %d in the shared hopper", P.pair_a.spent, residue_in_shared))
  local fh = P.full.hopper.get_inventory(defines.inventory.chest)
  local expected_spent = storage.best_dose * P.full.crafts / GEAR_BATCH
  check("a hopper filled to the top by an inserter: its machine keeps dosing, residues out", fh.get_bar() == #fh + 1
    and P.full.spent >= expected_spent - storage.best_dose - 1,
    string.format("bar %d of %d, %d residues out, %.0f expected", fh.get_bar(), #fh, P.full.spent, expected_spent))
  -- The production graph shows the effect: script-added gears are recorded as produced.
  local made, bonus = 0, 0
  for _, m in pairs(game.surfaces.nauvis.find_entities_filtered{type = "assembling-machine"}) do
    local r = m.get_recipe()
    if r and r.products[1].name == "iron-gear-wheel" and m.name ~= "es-test-bench" then
      made = made + m.products_finished * r.products[1].amount
      local cst = es("crafter_state", m.unit_number)
      if cst and (cst.bonus_total or 0) > 0 then bonus = bonus + cst.bonus_total end
    end
  end
  local statsf, graphed = game.forces.player.get_item_production_statistics("nauvis"), 0
  for q in pairs(prototypes.quality) do graphed = graphed + statsf.get_input_count{name = "iron-gear-wheel", quality = q} end
  check("production graph includes the script-added products", bonus > 0 and graphed >= made + bonus - 60,
    string.format("graph %d, crafted by machines %d, added by script %d", graphed, made, bonus))

  check("a hopper draws a chute into each machine it serves, and redraws when one goes",
    storage.chutes_before == 2 and es("chutes", storage.shared_hopper.unit_number) == 1
      and storage.bridges_before == 2 and es("bridges", storage.shared_hopper.unit_number) == 1,
    string.format("chutes %s before, %s after; flanges %s before, %s after", tostring(storage.chutes_before),
      tostring(es("chutes", storage.shared_hopper.unit_number)), tostring(storage.bridges_before),
      tostring(es("bridges", storage.shared_hopper.unit_number))))
  -- Speed and pollution (7d).
  for _, effect in ipairs({"speed", "pollution", "efficiency"}) do
    local ss = es("station", storage.station.unit_number, "gear", effect).summaries["stone:5"]
    local tv = es("effect_on", "gear", {stone = 5}, effect) * 1000
    check("station " .. effect .. " estimate for stone:5 near truth", ss and ss.n and ss.n > 10
      and math.abs(ss.mean - tv) < 4 * math.sqrt(ss.var / ss.n),
      ss and ss.n and string.format("n=%d %.0f vs %.0f", ss.n, ss.mean, tv) or "no data")
  end
  -- Additive power (0.44): the dosed speed machine's hidden consumer draws (or feeds back) its efficiency
  -- effect times the machine's draw while it works.
  do
    local cs = es("crafter_state", P.speed.entity.unit_number)
    local eff = es("effect_on", "gear", {[storage.speed_additive] = 9}, "efficiency")
    local want_use = cs.working and eff < 0 and cs.base_draw * -eff or 0
    local want_give = cs.working and eff > 0 and cs.base_draw * math.min(eff, 0.5) or 0
    check("a dosed machine's additive power follows its efficiency",
      math.abs(cs.power_usage - want_use) < 1 and math.abs(cs.power_production - want_give) < 1 and eff ~= 0,
      string.format("efficiency %+.1f%%, working %s: draws %.0f (want %.0f), feeds %.0f (want %.0f) J/tick",
        eff * 100, tostring(cs.working), cs.power_usage, want_use, cs.power_production, want_give))
  end
  do
    -- Quirks (0.48): FNV-1a as Python computes it, spread as set, none on a world without a seed.
    local q = es("quirk_stats")
    check("additive quirks: exact hash, intended spread, none on older worlds",
      q.ref == 1979185975 and math.abs(q.mean) < 0.05 and math.abs(q.sd - q.sd_want) < 0.05 and q.none == 0,
      string.format("hash %d (want 1979185975), mean %.3f, sd %.3f (want %.2f)", q.ref, q.mean, q.sd, q.sd_want))
  end
  do
    local b = storage.burner
    local cs = es("crafter_state", b.entity.unit_number)
    check("a burner machine gets no electric power entity, whatever its additive's efficiency",
      b.efficiency ~= 0 and cs and cs.last > 0 and not cs.has_power,
      string.format("%s on steel: efficiency %+.1f%%, %d crafts, power entity %s", b.additive, 100 * b.efficiency,
        cs and cs.last or 0, tostring(cs and cs.has_power)))
    if shared.quality_on then
      local u = storage.uncommon
      local left = u.hopper.get_inventory(defines.inventory.chest).get_item_count({name = "stone", quality = "uncommon"})
      local st = es("dose_state", u.entity.unit_number)
      check("an additive of another quality doses like a normal one",
        left < 50 and st.status and st.status[1] == "es.dose-ok",
        string.format("uncommon stone left %d of 50, status %s", left, serpent.line(st.status)))
    end
  end
  if storage.cascade then
    local c = storage.cascade
    local function by_quality(chest, item)
      local out = {}
      for _, it in pairs(chest.get_inventory(defines.inventory.chest).get_contents()) do
        if it.name == item then out[it.quality] = (out[it.quality] or 0) + it.count end
      end
      return out
    end
    local plates, gears = by_quality(c.fchest, "iron-plate"), by_quality(c.gchest, "iron-gear-wheel")
    check("quality cascade: a dosed furnace makes uncommon plates; an uncommon gear machine dosed again makes rare",
      (plates.uncommon or 0) > 0 and (plates.normal or 0) > 0 and (gears.rare or 0) > 0 and (gears.uncommon or 0) > 0,
      serpent.line({plates = plates, plate_chance = c.fchance, gears = gears, gear_chance = c.gchance}))
  end
  if storage.fresh then
    local fr = storage.fresh
    local function avg(r) return r.n or 0, (r.n or 0) > 0 and r.sum / r.n or 0 end
    local nc, sc = avg(fr.control)
    local nd, sd = avg(fr.dosed)
    local ratio = sc > 0 and sd / sc or 0
    local cs = es("crafter_state", fr.dosed.entity.unit_number)
    -- (0.72) The tolerance: three standard errors of the ratio, from the spread between stacks, and never under
    -- 0.02 (a fixed 0.02 failed seed 1 at 0.022 off, while seeds 12345, 777 and 4242 sat 0.003 to 0.011 the
    -- other way: noise, not a bias).
    local function rel_se(r)
      local k = r.k or 0
      if k < 2 then return math.huge end
      local m = r.ks / k
      local var = math.max(0, (r.kss - k * m * m) / (k - 1))
      return m > 0 and math.sqrt(var / k) / m or math.huge
    end
    local tol = math.max(0.02, 3 * ratio * math.sqrt(rel_se(fr.control) ^ 2 + rel_se(fr.dosed) ^ 2))
    check("freshness: dosed bioflux comes out fresher than undosed, by the hidden fraction",
      fr.additive and nc > 20 and nd > 20 and math.abs(ratio - (1 - fr.f)) < tol and tol < 0.08
        and (cs.fresh_restored or 0) > 0
        and (cs.fresh_missed or 0) <= 0.02 * nd,  -- every new unit found (a late look let a fifth go unrestored)
      string.format("%s: f %.2f; control %d at %.3f, dosed %d at %.3f, ratio %.3f (want %.3f, within %.3f); crafts restored %s",
        tostring(fr.additive), fr.f, nc, sc, nd, sd, ratio, 1 - fr.f, tol, tostring(cs.fresh_restored))
        .. string.format("; units not found %d; the dose's speed effect %+.3f; extra products %d of %d finished",
          cs.fresh_missed or 0, fr.speed or 0, cs.bonus_total or 0, fr.dosed.entity.products_finished)
)
  end
  if storage.fresh_benches and storage.fresh.additive then
    -- Samples: freshness restored (per cent) against the hidden fraction; the control near zero.
    local function restored(b)
      local xs = {}
      local inv = b.chest.get_inventory(defines.inventory.chest)
      for i = 1, #inv do
        local st = inv[i]
        if st.valid_for_read and shared.is_sample(st.name) then
          local fr = st.item and st.item.get_tag("fr")
          if fr then table.insert(xs, fr - 100) end
        end
      end
      local n, sum, sq = #xs, 0, 0
      for _, x in ipairs(xs) do sum, sq = sum + x, sq + x * x end
      local mean = n > 0 and sum / n or 0
      local sd = n > 1 and math.sqrt(math.max(0, (sq - n * mean * mean) / (n - 1))) or 0
      return n, mean, sd / math.sqrt(math.max(n, 1))
    end
    local nc, mc, sec = restored(storage.fresh_benches[1])
    local nd, md, sed = restored(storage.fresh_benches[2])
    local want = 100 * storage.fresh.f
    check("freshness in samples: a dosed bioflux trial records the restoration, the control none",
      nc >= 8 and nd >= 8 and math.abs(md - want) < 4 * sed + 0.5 and math.abs(mc) < 4 * sec + 0.5,
      string.format("dosed %d samples %.1f%% +/- %.1f (want %.1f); control %d samples %.1f%% +/- %.1f", nd, md, sed, want,
        nc, mc, sec))
  end
  do
    -- World strength (0.57): one seed's world at each strength has the same
    -- scores (the same draws); harsh has fewer activators and a median best tier 1 peak per target at
    -- least standard's (gentle is out of the setting until redesigned).
    -- Summed over ten maps: "fewer activators" is a property of many worlds; one map can tie (0.59).
    local function over(a, b)
      local sum = {same_scores = true, act = {[a] = 0, [b] = 0}, cells = 0, best = {[a] = {}, [b] = {}}, scores = {}}
      for seed = 4242, 4251 do
        local r = es("strength_compare", seed, a, b)
        sum.same_scores = sum.same_scores and r.same_scores
        sum.cells = sum.cells + r.cells
        for _, name in ipairs({a, b}) do
          sum.act[name] = sum.act[name] + r.act[name]
          for _, v in ipairs(r.best[name]) do table.insert(sum.best[name], v) end
        end
        for _, v in ipairs(r.scores) do table.insert(sum.scores, v) end
      end
      return sum
    end
    local h = over("standard", "harsh")

    local function median(v)
      table.sort(v)
      return #v > 0 and (v[math.floor((#v + 1) / 2)] + v[math.ceil((#v + 1) / 2)]) / 2 or 0
    end
    local ms, mh = median(h.best.standard), median(h.best.harsh)
    table.sort(h.scores)
    local q = function(f) return h.scores[math.max(1, math.floor(f * #h.scores))] end
    check("world strength: same draws; fewer activators at harsh, best peaks at least standard's",
      h.same_scores and h.act.standard > h.act.harsh and ms <= mh,
      string.format("activators of %d cells: %d, %d; median best peak %.3f, %.3f; scores 50/75/90%%: %.2f %.2f %.2f",
        h.cells, h.act.standard, h.act.harsh, ms, mh, q(0.5), q(0.75), q(0.9)))
  end
  if prototypes.recipe["es-trial-space-science-control"] then
    -- Space platforms (0.63): the space-only targets' trials keep their gravity condition; a dosed bench and a
    -- station work on a platform, its evidence pooled as "space-platform".
    local function zero_g(name)
      for _, c in ipairs(prototypes.recipe[name].surface_conditions or {}) do
        if c.property == "gravity" and c.max == 0 then return true end
      end
      return false
    end
    check("space targets: their trials can only run in space", zero_g("es-trial-space-science-control")
      and zero_g("es-trial-promethium-science-control"))
    local pr = es("platform_report")
    check("space platforms: a dosed bench and a station work on a platform, pooled as space-platform",
      storage.platform_set and not storage.platform_set.error and pr.skey == "space-platform" and pr.analysed > 0
        and pr.dosed > 0, serpent.line(storage.platform_set) .. " " .. serpent.line(pr))
  end
  if shared.additive("yumako-mash") then
    -- Adding the living additives moves no other additive's draws on a new world (0.62: inserted mid-list,
    -- and then a two-pass freshness generator, they did).
    local lc = es("late_check", 4242)
    check("adding additives moves no other additive's hidden world", lc.moved == nil and lc.compared > 100 and lc.late > 0,
      string.format("%d compared, %d added; first moved: %s", lc.compared, lc.late, tostring(lc.moved)))
  end
  if shared.additive("yumako-mash") then
    -- Ripeness (0.62): a living additive peaks at its best ripeness; a hopper's half-spoiled mash is dosed at
    -- its spoil fraction and its evidence lands in that band; an egg left to spoil in a hopper hatches.
    local r = es("ripe_check")
    check("ripeness: a living additive works best at its best ripeness; half-spoiled mash dosed and banded as such",
      r.at_best >= r.fresh and r.ok and r.ripe and math.abs(r.ripe - 0.5) < 0.01 and r.key == "yumako-mash~2:4",
      serpent.line(r))
    local e = storage.egg_result or {}  -- (looked at a second after the hatch: premature wrigglers die soon)
    check("ripeness: a pentapod egg left to spoil in a hopper hatches (vanilla)", e.eggs == 0 and (e.creatures or 0) > 0,
      serpent.line(e) .. " early " .. serpent.line(storage.egg_early or {}))
  end
  if prototypes.entity["es-pressure-heater"] then
    -- The temperature axis (0.61): a pressure heater to 500 (anywhere since 0.70, on charges); chilled twins down to
    -- -150, dosed as their fluid; bands beyond Nauvis's reach (90 still Nauvis's top band); a far best
    -- temperature is broader, so the reachable curve still slopes toward it; new maps carry the law.
    local ph = prototypes.entity["es-pressure-heater"]
    local cond = ph.surface_conditions and ph.surface_conditions[1]
    local twin = prototypes.fluid["es-chilled-lubricant"]
    check("temperature axis: a pressure heater to 500 on any surface; a chilled lubricant to -150",
      ph.target_temperature == 500 and cond == nil
        and twin and twin.default_temperature == -150 and twin.max_temperature == prototypes.fluid["lubricant"].default_temperature
        and prototypes.recipe["es-chill-lubricant"].category == "cryogenics",
      string.format("heater %s, condition %s, twin %s to %s", tostring(ph.target_temperature), serpent.line(cond),
        twin and twin.default_temperature, twin and twin.max_temperature))
    local ax = es("temp_axis_check")
    check("temperature axis: bands beyond reach, 90 still in Nauvis's top band; a far optimum broad, still sloping at the edge",
      ax.band90 == 4 and ax.band91 == 5 and ax.band_cold < 0 and ax.split == -3 and ax.width_far > 2 * ax.width_near
        and ax.edge > ax.inside and ax.law, serpent.line(ax))
    -- Liquid premixes: since 0.71 none has a chilled twin, its minimum being the chilled cold (a fluid chiller
    -- cools it in place); on this new map some premix optima lie beyond Nauvis's reach, all within the axis.
    local twins, out, inside_axis, n = 0, 0, true, 0
    for _, a in ipairs(shared.premixes) do
      if a.fluid then
        n = n + 1
        local f = prototypes.fluid[a.name]
        if not prototypes.fluid["es-chilled-" .. a.name] and f and f.default_temperature == shared.chilled.temperature then
          twins = twins + 1
        end
        local best = es("premix_best_temp", a.name)
        if best and (best < shared.premix.cold or best > shared.premix.hot) then out = out + 1 end
        if best and (best < shared.temp_axis.min or best > shared.temp_axis.max) then inside_axis = false end
      end
    end
    check("temperature axis: liquid premixes chill in place (no twin, the cold their minimum); some optima lie beyond reach, within the axis",
      twins == n and n > 0 and out > 0 and inside_axis, string.format("%d of %d chill in place; %d beyond reach", twins, n, out))
    local ct = es("chilled_take")
    check("temperature axis: a hopper's chilled lubricant is dosed as lubricant, at its temperature",
      ct.inserted == 100 and ct.ok and ct.temp and math.abs(ct.temp + 100) < 1 and ct.left == 80, serpent.line(ct))
  end
  if prototypes.item["es-scrap-sample"] then
    -- Fulgora scrap samples (0.60): a result of scrap recycling (the recycler's thirteenth slot); a station
    -- analyses them with the best pack it holds, drawing cells weighted, capped (duds beyond), making no
    -- research data; Scrap forensics widen the targets; a better pack draws fewer duds; they spoil to nothing.
    local r = prototypes.recipe["scrap-recycling"]
    local result
    for _, p in pairs(r.products) do if p.name == "es-scrap-sample" then result = p end end
    check("scrap samples: a result of scrap recycling, the recycler holding every result",
      result and result.probability == shared.scrap.rate and prototypes.entity["recycler"].get_inventory_size(defines.inventory.furnace_result) >= #r.products,
      result and string.format("probability %s, %d results, %d slots", result.probability, #r.products,
        prototypes.entity["recycler"].get_inventory_size(defines.inventory.furnace_result)))
    local base = es("scrap_targets")
    local has = function(list, key) for _, x in ipairs(list) do if x.key == key then return true end end end
    local force = game.forces.player
    force.technologies["es-scrap-forensics-1"].researched = true
    local wide = es("scrap_targets")
    force.technologies["es-scrap-forensics-2"].researched = true
    local all = es("scrap_targets")
    force.technologies["es-scrap-forensics-2"].researched = false
    force.technologies["es-scrap-forensics-1"].researched = false
    check("scrap samples: gears from scrap; red science only with Scrap forensics 1; every target with 2",
      has(base, "gear") and not has(base, "red") and has(wide, "red") and #all == #shared.targets,
      string.format("%d, %d, %d of %d targets", #base, #wide, #all, #shared.targets))
    local red, top = es("scrap_draws", 3000, 0, 7), es("scrap_draws", 3000, 6, 7)
    check("scrap samples: a cell takes at most 3, a control 6; duds beyond; the top pack draws fewer duds",
      red.max_cell <= 3 and red.max_control <= 6 and red.duds > 0 and top.duds < red.duds,
      string.format("max cell %d, control %d; duds %d with red, %d with the top pack", red.max_cell, red.max_control,
        red.duds, top.duds))
    local st = es("scrap_station", 12)
    check("scrap samples: a station analyses them with its best pack, making no research data",
      st.analysed + st.duds == 12 and st.left == 0 and st.data == 0
        and (st.em_given == 0 or (st.em_left == 0 and st.red_left == 18)),  -- EM (4 samples), then two red
      serpent.line(st))
    -- Quality packs (0.60): one pack analyses more samples by vanilla's durability multiplier.
    if prototypes.quality["legendary"] then
      local n, l = es("scrap_station", 30, "normal"), es("scrap_station", 30, "legendary")
      check("a legendary pack analyses more samples than a normal one, by vanilla's multiplier",
        n.analysed + n.duds == n.per_pack and l.analysed + l.duds == l.per_pack and l.per_pack > n.per_pack,
        string.format("normal %d (of %d), legendary %d (of %d)", n.analysed + n.duds, n.per_pack, l.analysed + l.duds,
          l.per_pack))
    end
    local cinv = storage.scrap_chest and storage.scrap_chest.valid and storage.scrap_chest.get_inventory(defines.inventory.chest)
    check("scrap samples spoil to nothing", cinv and cinv.get_item_count("es-scrap-sample") == 0,
      cinv and cinv.get_item_count("es-scrap-sample"))
  end
  do
    -- The Theory tab's shapes (0.59): observations of coal on gears that follow a cliff (rise, collapse
    -- from dose 5; 10 samples a dose, SD 20 per mille) read as Cliff for carbon on metalwork.
    local acc = function(mean)
      local n, sd = 10, 20
      return {n = n, sum = n * mean, sumsq = n * mean * mean + (n - 1) * sd * sd}
    end
    local obs = {gear = {control = acc(0)}}
    for d = 1, 9 do
      obs.gear["coal:" .. d] = acc(150 * (1 - math.exp(-d)) - 300 / (1 + math.exp(-4 * (d - 4.8))))
    end
    local sh = es("family_shapes_of", obs)
    local got = sh.carbon and sh.carbon.metalwork
    check("Theory shapes: a family's cliff study reads as Cliff on its class", got and got.model == "cliff",
      got and (got.model .. " (" .. got.n .. ")") or "nothing")
  end
  do
    -- Family-set shapes (0.58): a new map has the law; followers of one family on targets sharing a main
    -- class share a shape; a world without the law keeps every drawn shape (old maps unchanged).
    local s = es("shape_law_check")
    check("family-set shapes: law on a new map, followers agree within a class, old worlds unchanged",
      s.law and s.pairs > 0 and s.agree == s.pairs and s.old_same,
      string.format("%d of %d pairs agree; %d following activators, %d cliffs; old worlds unchanged: %s",
        s.agree, s.pairs, s.acts, s.cliffs, tostring(s.old_same)))
  end
  do
    -- The Theory tab on speed (0.70): the lab's speed evidence fits to finite estimates.
    local r = es("theory_check", "player", "speed")
    check("the Theory model fits the speed evidence to finite estimates", r.n > 0 and r.finite,
      serpent.line(r))
    -- Equal readings give a zero standard error: the fit stays finite.
    local z = es("theory_check", "player", "speed", {{additive = "coal", target = "gear", gain = 20, se = 0},
      {additive = "coal", target = "circuit", gain = 10, se = 0}, {additive = "stone", target = "gear", gain = -5, se = 0}})
    check("the Theory model stays finite on results with no spread", z.finite, serpent.line(z))
  end
  do
    -- The early set (0.70): a new map has the early law; with and without the promotion every draw is
    -- the same except the promoted cells (made activators, score kept); wood waits for Tree seeding.
    local s = es("early_law_check", 4242)
    check("early set: law on a new map, only promoted cells differ, wood waits for Tree seeding",
      s.law and s.others_same and s.cells_ok and (not s.space_age or (s.wood_before == false and s.wood_after == true)),
      string.format("%d of %d targets promoted; first moved: %s; promoted cells ok: %s; wood shown before %s, after %s",
        s.promoted, s.n, s.first_moved or "none", tostring(s.cells_ok), tostring(s.wood_before), tostring(s.wood_after)))
  end
  do
    -- Side effects by class (0.70): a new map has the law; it moves some targets' speed leader; the two
    -- pure metalwork targets share one; a world without the law keeps the old rule exactly.
    local s = es("side_law_check")
    check("side effects by class: law on a new map, leaders move, gear and steel share one, old worlds unchanged",
      s.law and s.moved > 0 and s.leaders.gear == s.leaders.steel and s.old_same,
      string.format("%d of %d speed leaders moved; gear %s, steel %s, circuit %s; old worlds unchanged: %s",
        s.moved, s.n, s.leaders.gear or "?", s.leaders.steel or "?", s.leaders.circuit or "?", tostring(s.old_same)))
  end
  do
    -- Other mods' targets (0.55): this test mod registers "es-test-pipe". Its trial exists, the live world
    -- has it, and its draws come from streams of its own: leaving it out, or registering one more target
    -- before it, moves no other target's draws, and the extra target does not move its draws.
    local trial = prototypes.recipe["es-trial-es-test-pipe-control"]
    local pipes = 0
    for _, ing in ipairs(trial and trial.ingredients or {}) do if ing.name == "iron-plate" then pipes = ing.amount end end
    check("registered target: its trial is built (30 pipes' iron)", trial ~= nil and pipes == 30, "iron " .. pipes)
    local r = es("registered_check", 4242)
    local p = r.registered["es-test-pipe"]
    check("registered target: in the live world, every additive drawn, a tier 1 activator",
      r.live and p and p.n == #shared.additives and p.activator, p and string.format("%d of %d", p.n, #shared.additives) or "absent")
    check("registered target: no other target's draws move when it is left out or another is added",
      r.others_same, string.format("%d targets compared; first moved: %s", r.n_others, r.first_moved or "none"))
    check("registered target: its draws do not move when another registered target is added",
      p and p.same_with_extra, "")
  end
  do
    -- The temperature fit (0.53) finds a known best temperature: band means from a bell (peak 52 degrees,
    -- width 20, over a baseline), with a little noise; the truth inside its 95% interval.
    local rng = game.create_random_generator(5252)
    local pts = {}
    for b = 0, 4 do
      local t = 15 + (b + 0.5) * 15
      local z = math.sqrt(-2 * math.log(1 - rng())) * math.cos(2 * math.pi * rng())
      table.insert(pts, {temp = t, mean = 10 + 150 * math.exp(-((t - 52) / 20) ^ 2) + 4 * z, se = 4})
    end
    local f = es("fit_temperature", pts, 15, 90)
    check("temperature fit: a known best temperature found within its interval",
      f and math.abs(f.temp - 52) < 3 and f.lo <= 52 and 52 <= f.hi,
      f and string.format("best %.1f (%.1f to %.1f), width %d", f.temp, f.lo, f.hi, f.width) or "no fit")
  end
  do
    -- Residues share the trash slots (review 0.68): one slot free and two kinds of residue due, the dose
    -- waits; with both slots free it is taken.
    local s = game.surfaces.nauvis
    local b = s.create_entity{name = "es-test-bench", position = {-150.5, -150.5}, force = "player", raise_built = true}
    b.set_recipe("es-trial-gear-control")
    local hc = s.create_entity{name = "es-hopper", position = {-150.5, -152.5}, force = "player", raise_built = true}
    local hs = s.create_entity{name = "es-hopper", position = {-152.5, -150.5}, force = "player", raise_built = true}
    hc.insert{name = "coal", count = 20}; hs.insert{name = "stone", count = 20}
    local trash = b.get_inventory(defines.inventory.crafter_trash)
    for i = 1, #trash - 1 do trash[i].set_stack{name = "wood", count = 100} end  -- one slot free
    local blocked = es("take_now", b.unit_number, {coal = 3, stone = 3})
    trash.clear()
    local free = es("take_now", b.unit_number, {coal = 3, stone = 3})
    check("a dose waits when its residues together do not fit the trash slots",
      blocked.ok == false and tostring(blocked.why):find("^spent:") ~= nil and free.ok == true,
      serpent.line({blocked = blocked, free = free}))
  end
  do
    -- The pressure heater (0.70): builds on Nauvis, and burns pressure charges only, not ordinary fuel.
    if prototypes.entity["es-pressure-heater"] then
      local s = game.surfaces.nauvis
      local pos = s.find_non_colliding_position("es-pressure-heater", {-180, -150}, 20, 1)
      local hh = pos and s.create_entity{name = "es-pressure-heater", position = pos, force = "player"}
      local fuel = hh and hh.get_fuel_inventory()
      local coal = fuel and fuel.can_insert{name = "coal", count = 1}
      local charge = fuel and fuel.can_insert{name = "es-pressure-charge", count = 1}
      check("the pressure heater builds on Nauvis and burns pressure charges, not coal",
        hh ~= nil and charge == true and coal == false,
        string.format("built %s, charge %s, coal %s", tostring(hh ~= nil), tostring(charge), tostring(coal)))
      if hh then hh.destroy() end
    end
  end
  do
    -- The frontier's ceiling (0.70): an old world keeps temperature's full lift; a new one stops at the ceiling.
    local f = es("frontier_check")
    check("temperature lifts an effect at most the frontier ceiling on new worlds, fully on old ones",
      f.old > f.max and math.abs(f.new - f.max) < 1e-9, serpent.line(f))
  end
  do
    -- Slot filters (0.70): a hopper's slots can be filtered, so a second additive keeps its room: with all
    -- but two slots filtered to coal, a flood of stone fills only the two.
    local h = game.surfaces.nauvis.create_entity{name = "es-hopper", position = {-170.5, -150.5}, force = "player",
      raise_built = true}
    local inv = h.get_inventory(defines.inventory.chest)
    local ok_f = inv.supports_filters()
    if ok_f then for i = 1, #inv - 2 do inv.set_filter(i, {name = "coal"}) end end
    local put = inv.insert{name = "stone", count = 50 * #inv}
    local coal = inv.insert{name = "coal", count = 50}
    check("a hopper's slots take filters, keeping room for another additive",
      ok_f and put == 2 * prototypes.item.stone.stack_size and coal == 50,
      string.format("filters %s, stone in %d (2 stacks of %d), coal in %d", tostring(ok_f), put,
        prototypes.item.stone.stack_size, coal))
    -- And a blueprint keeps them, as a cargo wagon's.
    local binv = game.create_inventory(1)
    binv.insert{name = "blueprint"}
    local bp = binv[1]
    bp.create_blueprint{surface = game.surfaces.nauvis, force = "player", area = {{-171, -151}, {-170, -150}}}
    local nf, seen = 0, {}
    for _, e in ipairs(bp.get_blueprint_entities() or {}) do
      local keys = {}
      for k in pairs(e) do table.insert(keys, k) end
      table.insert(seen, e.name .. "{" .. table.concat(keys, ",") .. "}")
      -- (A container's slot filters sit in the blueprint entity's `filters`.)
      if e.name == "es-hopper" and e.filters then nf = #e.filters end
    end
    binv.destroy()
    check("a blueprint keeps a hopper's slot filters", nf == #inv - 2, string.format("%d filters kept of %d; %s", nf, #inv - 2, table.concat(seen, " ")))
    h.destroy()
  end
  do
    -- What each kind leaves (0.68, Residues by family): one residue per solid member; biological, spoilage;
    -- fluids, liquid premixes, agents, residues and spoilage nothing. And three families at once fit.
    local s = game.surfaces.nauvis
    local b = s.create_entity{name = "es-test-bench", position = {-160.5, -150.5}, force = "player", raise_built = true}
    b.set_recipe("es-trial-gear-control")
    local h = s.create_entity{name = "es-hopper", position = {-160.5, -152.5}, force = "player", raise_built = true}
    local trash = b.get_inventory(defines.inventory.crafter_trash)
    local blend, liquid
    for _, a in ipairs(shared.additives) do
      if a.premix_of and not a.fluid and not blend then
        local m1, m2 = shared.additive(a.premix_of[1]), shared.additive(a.premix_of[2])
        if not m1.fluid and not m2.fluid and not m1.refined_from and not m2.refined_from then blend = a end
      end
      if a.premix_of and a.fluid and not liquid then liquid = a end
    end
    local function left(needs)
      trash.clear()
      local hinv = h.get_inventory(defines.inventory.chest)
      hinv.clear()
      for name, n in pairs(needs) do
        if prototypes.item[name] then hinv.insert{name = name, count = n * 3} end
      end
      local r = es("take_now", b.unit_number, needs)
      local out = {}
      for _, it in pairs(trash.get_contents()) do out[it.name] = it.count end
      return r.ok, out
    end
    local res = {}
    local ok1, cat = left({["es-refined-coal"] = 2})
    res.catalyst = cat
    local ok2, bl = left({[blend.name] = 2})
    res.blend = bl
    local m1, m2 = shared.residue_of(blend.premix_of[1]), shared.residue_of(blend.premix_of[2])
    local ok3, three = left({coal = 1, stone = 1, ["copper-cable"] = 1})
    res.three = three
    local ok4, agent = left({["uranium-235"] = 1})
    local good = ok1 and cat["es-spent-coal"] == 2 and table_size(cat) == 1
      and ok2 and bl[m1] == 2 and bl[m2] == 2 and table_size(bl) == 2
      and ok3 and three["es-spent-coal"] == 1 and three["es-spent-stone"] == 1 and three["es-spent-copper-cable"] == 1
      and (not prototypes.item["uranium-235"] or (ok4 and next(agent) == nil))
    if prototypes.item["yumako-mash"] then
      local ok5, mash = left({["yumako-mash"] = 2})
      local ok6, spoil = left({spoilage = 2})
      res.mash, res.spoil = mash, spoil
      good = good and ok5 and mash.spoilage == 2 and table_size(mash) == 1 and ok6 and next(spoil) == nil
    end
    check("each kind of additive leaves its residues, and three families fit the trash at once", good,
      serpent.line({blend = blend.name, res = res}))
    -- A slurry (0.70) leaves its solid's residue at the share one unit carries (read here from its recipe:
    -- solid in, units out); whole residues only, the rest carried to the next dose: five doses of 7 units
    -- leave floor(7 x share x k) after the k-th.
    local rec = prototypes.recipe["es-premix-water-es-refined-coal"]
    local solid, out = 0, 0
    for _, i in ipairs(rec.ingredients) do if i.name == "es-refined-coal" then solid = i.amount end end
    for _, p in ipairs(rec.products) do if p.name == rec.name then out = p.amount end end
    local sl = es("slurry_take", "es-premix-water-es-refined-coal", 7, 5)
    local want, ok_sl = {}, solid > 0 and out > 0
    for k = 1, 5 do want[k] = math.floor(7 * solid / out * k + 1e-9); ok_sl = ok_sl and sl.after[k] == want[k] end
    check("a slurry dose leaves its solid's residue at its share, carried between doses", ok_sl,
      serpent.line({got = sl.after, want = want, shares = sl.shares}))
  end
  do
    -- The answer key (0.68): every effect ranks gears (freshness none: gears do not spoil), the best gear
    -- pair is a pair, and some major finding is on offer.
    local pr = es("answer_key_probe")
    local any_major = 0
    for _, n in pairs(pr.majors) do any_major = any_major + n end
    check("the answer key ranks by every effect and lists major findings",
      pr.ranked.yield > 20 and pr.ranked.speed == pr.ranked.yield and pr.ranked.cleanliness == pr.ranked.yield
        and pr.ranked.freshness == 0 and pr.ranked.quality > 0 and pr.pair and pr.pair.size == 2 and any_major > 0,
      serpent.line(pr))
  end
  do
    -- The circuit tips' scenes: each runs (dose by signal and the sweep: a bench takes its coal dose from
    -- the wire; best composition: the port doses the machine with a tested composition).
    local res, ok = {}, storage.scenes ~= nil
    for key, sc in pairs(storage.scenes or {}) do
      local s = game.surfaces[sc.surface]
      local m = s.find_entities_filtered{name = key == "adopt_best" and "assembling-machine-2" or "es-test-bench"}[1]
      local d = m and es("dose_state", m.unit_number)
      local works = m and d and d.mix and next(d.mix) and d.status and d.status[1] == "es.dose-ok" and m.products_finished > 0
      -- The best composition is one the history tested, coal x5 or stone x3 alone (the Best composition page sends only what was
      -- tested; which wins is the map's).
      if key == "adopt_best" then
        local n = 0
        for _ in pairs(d.mix) do n = n + 1 end
        works = works and n == 1 and (d.mix.coal == 5 or d.mix.stone == 3)
      end
      ok = ok and works and sc.camera ~= nil
      table.insert(res, string.format("%s: %s, made %d, status %s", key, serpent.line(d and d.mix), m and m.products_finished or -1,
        serpent.line(d and d.status)))
    end
    check("the circuit tips' scenes build and run", ok, table.concat(res, "; "))
  end
  do
    -- The example blueprints (0.67): each imports on this version, builds, and carries its doses and wires.
    local s = game.surfaces.nauvis
    s.request_to_generate_chunks({430, 430}, 3); s.force_generate_chunk_requests()
    for _, e in pairs(s.find_entities_filtered{area = {{380, 400}, {540, 460}}}) do if e.type ~= "character" then e.destroy() end end
    local tiles = {}
    for x = 380, 539 do for y = 400, 459 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
    s.set_tiles(tiles)
    local inv = game.create_inventory(1)
    local results, ok = {}, true
    local i = 0
    for key, text in pairs(es("example_blueprints")) do
      i = i + 1
      inv.clear(); inv.insert{name = "blueprint"}
      local code = inv[1].import_stack(text)
      local ghosts = code == 0 and inv[1].build_blueprint{surface = s, force = "player", position = {390 + 35 * i, 430},
        build_mode = defines.build_mode.forced} or {}
      local ghost_names = {}
      for _, g in ipairs(ghosts) do table.insert(ghost_names, g.ghost_name .. "@" .. g.position.x .. "," .. g.position.y) end
      -- Machines first, stations last (a station reconnects its port wires to what is already built).
      table.sort(ghosts, function(a, b) return (a.ghost_name == "es-analysis-station" and 1 or 0) < (b.ghost_name == "es-analysis-station" and 1 or 0) end)
      for _, g in ipairs(ghosts) do if g.valid then g.revive{raise_revive = true} end end
      local area = {{390 + 35 * i - 15, 415}, {390 + 35 * i + 15, 445}}
      local circuit = 0
      for _, m in pairs(s.find_entities_filtered{area = area, name = {"es-test-bench", "assembling-machine-2"}}) do
        local d = es("dose_state", m.unit_number)
        if d.settings and d.settings.circuit then circuit = circuit + 1 end
      end
      local port_wired = nil
      local port = s.find_entities_filtered{area = area, name = "es-station-port"}[1]
      if port then
        port_wired = #port.get_wire_connector(defines.wire_connector_id.circuit_green, true).connections > 0
      end
      local want = code == 0 and #(inv[1].get_blueprint_entities() or {}) or -1  -- (-1: did not import)
      if #ghosts ~= want then
        local got, all = ghost_names, {}
        for _, e in ipairs(code == 0 and inv[1].get_blueprint_entities() or {}) do table.insert(all, e.name .. "@" .. e.position.x .. "," .. e.position.y) end
        table.insert(results, "built " .. table.concat(got, ",") .. " of " .. table.concat(all, " "))
      end
      table.insert(results, string.format("%s: import %d, %d of %d built, %d in circuit mode%s", key, code, #ghosts, want,
        circuit, port and (", port wired " .. tostring(port_wired)) or ""))
      ok = ok and code == 0 and #ghosts == want and circuit >= 1 and (port == nil or port_wired)
    end
    inv.destroy()
    check("the example blueprints import, build, and keep their circuit doses and port wires", ok and i == 3,
      table.concat(results, "; "))
  end
  do
    -- Alt mode (0.67): a supplied machine draws its dose, a starved one the same greyed (signature "!").
    local fed = es("badges", storage.P.ind.entity.unit_number)
    local starved = es("badges", storage.P.empty.entity.unit_number)
    local want = storage.activator .. ":" .. storage.best_dose
    check("alt mode shows a machine's dose, greyed while starved",
      fed and fed.sig == want and fed.alive == 2 and fed.alt == 2 and starved and starved.sig == want .. "!",
      serpent.line({fed = fed, starved = starved, want = want}))
  end
  do
    -- Dossiers (0.66). Real production counts toward its composition.
    local made = es("dossier_made", "player", "gear", storage.activator .. ":" .. storage.best_dose)
    check("dosed production is counted toward its composition's dossier", made > 0, made)
    -- On a fresh force, from seeded evidence: proven needs production to be done; finished needs every
    -- reached planet's quota and the exceptional set.
    local f = game.create_force("es-dossiers")
    local vol = es("dossier_volume", "gear")
    es("dossier_seed", f.name, "nauvis", "gear", "coal:3", "yield", 200, 20)
    local before = es("dossier_state", f.name).planets.nauvis.targets.gear
    es("dossier_add_made", f.name, "gear", "coal:3", vol)
    local after = es("dossier_state", f.name).planets.nauvis.targets.gear
    check("a proven effect becomes a dossier once its production reaches the volume",
      before.state == "proven" and after.state == "done" and after.readout == "yield",
      string.format("before %s, after %s (%s, volume %d)", before.state, after.state, tostring(after.readout), vol))
    -- The exceptional set first (yield past its bar on gear, speed, efficiency, freshness): still not finished
    -- while a reached planet lacks its quota.
    -- Seeded readings clear each bar by 12 points (per mille, the bars re-derive with the model: 0.70's
    -- side effects raised the speed bar past a typed 200).
    local bars = es("dossier_bars").exceptional
    local above = function(readout) return math.floor(1000 * bars[readout]) + 120 end
    es("dossier_seed", f.name, "nauvis", "gear", "stone:5", "yield", above("yield"), 20)  -- (its own cell: coal:3 holds 200s)
    es("dossier_add_made", f.name, "gear", "stone:5", vol)
    for _, r in ipairs({"speed", "efficiency", "freshness"}) do
      es("dossier_seed", f.name, "nauvis", "gear", "coal:3", r, above(r), 20)
    end
    -- Bars per planet (0.70): a Nauvis target is judged by Nauvis's yield bar, a Gleba one by Gleba's.
    do
      local all = es("dossier_bars")
      local fp = game.create_force("es-dossiers-planets")
      es("dossier_seed", fp.name, "nauvis", "gear", "coal:3", "yield", 400, 20)
      local gk = all.planets.gleba and all.planets.gleba[1]
      if gk then es("dossier_seed", fp.name, "nauvis", gk, "coal:3", "yield", 400, 20) end
      local stp = es("dossier_state", fp.name)
      local g_n = stp.planets.nauvis.targets.gear.threshold
      local g_g = gk and stp.planets.gleba.targets[gk].threshold
      check("each planet's targets are judged by its own finding bar",
        g_n == all.standard.nauvis.yield and (not gk or (g_g == all.standard.gleba.yield and g_g ~= g_n)),
        string.format("gear %s (Nauvis bar %s); %s %s (Gleba bar %s)", tostring(g_n), tostring(all.standard.nauvis.yield),
          tostring(gk), tostring(g_g), tostring(all.standard.gleba and all.standard.gleba.yield)))
    end
    -- Cleanliness reads "good is positive": a cleaner dose (positive pollution reading) is a cleanliness gain.
    local fc = game.create_force("es-dossiers-clean")
    es("dossier_seed", fc.name, "nauvis", "gear", "coal:3", "pollution", above("cleanliness"), 20)
    es("dossier_add_made", fc.name, "gear", "coal:3", vol)
    local cl = es("dossier_state", fc.name).exceptional.cleanliness
    check("a cleaner dose counts as a cleanliness finding", cl.state == "done" and cl.lb > bars.cleanliness,
      string.format("%s, lower bound %s", cl.state, tostring(cl.lb)))
    local st = es("dossier_state", f.name)
    local mid = string.format("midway: finished %s, exceptional %d of %d", tostring(st.finished), st.exc_done, st.exc_needed)
    local unfinished = st.finished or st.exc_done < st.exc_needed
    for name, p in pairs(st.planets) do
      if p.reached then
        local n = 0
        for key in pairs(p.targets) do
          if n < p.quota then
            es("dossier_seed", f.name, "nauvis", key, "coal:3", "yield", 400, 20)
            es("dossier_add_made", f.name, key, "coal:3", es("dossier_volume", key))
            n = n + 1
          end
        end
      end
    end
    st = es("dossier_state", f.name)
    local reached = {}
    for name, p in pairs(st.planets) do if p.reached then table.insert(reached, name .. " " .. p.done .. "/" .. p.quota) end end
    local ann = es("dossier_announce", f.name)
    check("each completed finding is announced once", #ann > 0 and #es("dossier_announce", f.name) == #ann, #ann)
    -- To settle (0.67): the estimate lands where the rule settles, not one sample later or earlier.
    local okc, detail = true, {}
    for _, c in ipairs({{60, 25, 8, 8}, {5, 30, 6, 10}, {-40, 20, 12, 6}, {150, 40, 4, 4}}) do
      local r = es("settle_check", c[1], c[2], c[3], c[4])
      local good = r.k == 0 and r.at or (r.at and r.before == false)
      okc = okc and good
      table.insert(detail, string.format("net %d se %d: %s", c[1], c[2], tostring(r.k)))
    end
    check("the samples-to-settle estimate is where the settle rule flips", okc, table.concat(detail, "; "))
    -- The report (0.69): a dropped cell whose true effect clears its bar with room is worth another look;
    -- proven findings come back with their true effect; counts never name what is left.
    local fr = game.create_force("es-report")
    local bar = es("dossier_report", f.name) and 0  -- (warm the world caches)
    local tk, cell
    for _, k in ipairs({"red", "green", "gear", "steel"}) do
      for _, a in ipairs({"coal", "wood", "stone", "stone-brick", "copper-cable"}) do
        for d = 1, 9 do
          if not cell and es("gain", k, a, d) >= 0.25 then tk, cell = k, a .. ":" .. d end
        end
      end
    end
    local look_ok = true
    if cell then
      es("dossier_seed", fr.name, "nauvis", tk, cell, "yield", 0, 10)
      local rr = es("dossier_report", fr.name)
      look_ok = false
      for _, l in ipairs(rr.look) do if l.target == tk and l.key == cell then look_ok = true end end
    end
    local rf = es("dossier_report", f.name)
    check("the report lists dropped cells worth another look, and proven findings with their true effect",
      look_ok and #rf.truth > 0 and type(rf.truth[1].v) == "number" and rf.majors.needed == st.exc_needed,
      serpent.line({cell = cell, target = tk, truth_rows = #rf.truth, majors = rf.majors}))
    check("dossiers finish with every reached planet's quota and the exceptional set",
      not unfinished and st.finished,
      string.format("%s; reached %s; exceptional %d of %d", mid, table.concat(reached, ", "), st.exc_done, st.exc_needed))
    -- 0.72: achievements, recorded per force (a headless test has no player to unlock them). This force has
    -- findings, but no station analysed for it: Lab rat stays the player force's.
    es("judge_now", f.name)
    local got, mine = es("achieved", f.name), es("achieved", "player")
    check("achievements: a finding earns Statistically significant; a station's sample earns Lab rat; no Reviewer 2 on standard",
      got["es-statistically-significant"] and mine["es-lab-rat"] and not got["es-reviewer-2"] and not mine["es-reviewer-2"],
      serpent.line({findings_force = got, player = mine}))
  end
  do
    -- The Theory model (0.53) recovers known family affinities: cells built from a known model (two
    -- families, every base target, noise of 5 per mille), fitted; each true affinity in its 95% interval.
    local truth_a = {carbon = {120, -60, 30}, mineral = {-40, 90, -80}}
    local members = {carbon = {"coal", "solid-fuel"}, mineral = {"stone", "stone-brick"}}
    local rng = game.create_random_generator(424242)
    local cells = {}
    for fam, names in pairs(members) do
      for _, name in ipairs(names) do
        for _, t in ipairs(shared.targets) do
          local w, norm = {}, 0
          for i, c in ipairs(shared.process_classes) do w[i] = t.process[c] or 0; norm = norm + w[i] ^ 2 end
          local y = 0
          for i = 1, 3 do y = y + w[i] / math.sqrt(norm) * truth_a[fam][i] end
          local z = math.sqrt(-2 * math.log(1 - rng())) * math.cos(2 * math.pi * rng())
          table.insert(cells, {additive = name, target = t.key, gain = y + 5 * z, se = 5})
        end
      end
    end
    local fit = es("theory_fit_cells", cells)
    local ok, detail = fit ~= nil, {}
    for fam, a in pairs(truth_a) do
      local f = fit and fit.families[fam]
      for i = 1, 3 do
        -- Within 3.3 standard errors (99.9% each): six 95% intervals all cover only 74% of the time, so
        -- the old test failed when added targets moved the draw (0.64). Coverage itself: balance.py's Theory rule.
        local se = f and (f.hi[i] - f.lo[i]) / 3.92
        local inside = f and math.abs(f.est[i] - a[i]) <= 3.3 * se and math.abs(f.est[i] - a[i]) < 15
        ok = ok and inside
        table.insert(detail, string.format("%s.%d %.0f [%.0f, %.0f] vs %d", fam, i, f and f.est[i] or 0,
          f and f.lo[i] or 0, f and f.hi[i] or 0, a[i]))
      end
    end
    check("theory: the model recovers known family affinities within its intervals", ok, table.concat(detail, "; "))
    -- And on this map's real evidence: it fits and predicts untested pairs.
    local tp = es("theory_pool", "player", "nauvis")
    check("theory: fitted to the force's evidence, predicting untested pairs", tp.fitted and tp.untested > 0,
      serpent.line(tp))
  end
  do
    -- Prices by planet (0.50): pollution unpriced without a pollutant; late (solar) power by sunlight,
    -- capped at the early (fuel) price; early prices unchanged but for pollution.
    local early, late = shared.copy(shared.prices.early), shared.copy(shared.prices.late)
    early.preset, late.preset = "early", "late"
    local function sun(k) local loc = prototypes.space_location[k]; return loc and loc.surface_properties["solar-power"] or 100 end
    local function near(a, b) return math.abs(a - b) < 1e-9 end
    local out = {}
    local ok = true
    for _, k in ipairs({"nauvis", "vulcanus", "gleba", "aquilo"}) do
      if prototypes.space_location[k] then
        local pl, pe = es("price_on", late, k), es("price_on", early, k)
        local want_mj = math.min(late.mj * sun("nauvis") / sun(k), early.mj)
        local polluted = prototypes.space_location[k].pollutant_type ~= nil
        ok = ok and near(pl.mj, want_mj) and near(pe.mj, early.mj)
          and near(pe.pollution, polluted and early.pollution or 0)
        out[k] = string.format("late mj %.4f (want %.4f), early pollution %.2f", pl.mj, want_mj, pe.pollution)
      end
    end
    check("prices by planet: no pollution price without a pollutant, solar power by sunlight, capped at fuel",
      ok and out.vulcanus ~= nil, serpent.line(out))
  end
  do
    -- No residue recipe a furnace would pick from its fuel (0.51: coal to ash was smelting, so once carbon's
    -- activation was found every furnace fed from a coal-and-ore belt smelted its fuel and stopped).
    local furnace_cats = {}
    for _, e in pairs(prototypes.get_entity_filtered{{filter = "type", type = "furnace"}}) do
      for cat in pairs(e.crafting_categories or {}) do furnace_cats[cat] = true end
    end
    local bad = {}
    for _, a in ipairs(shared.all_additives) do
      local r = a.residue_of and prototypes.recipe[a.name]
      if r then
        for _, ing in ipairs(r.ingredients) do
          local it = prototypes.item[ing.name]
          if it and it.fuel_value > 0 and furnace_cats[r.category] then table.insert(bad, r.name .. " (" .. r.category .. ")") end
        end
      end
    end
    check("no furnace turns its fuel into a residue", #bad == 0, table.concat(bad, ", "))
  end
  do
    -- Hopper reports (0.49): the fed machine's hopper counts it dosed; the empty hopper's machine is
    -- short, and the hopper asks for exactly one batch's dose of the additive (it holds none).
    local e = storage.report_expect
    local function filters(h)
      local out = {}
      for _, f in ipairs(es("hopper_report_filters", h.unit_number)) do out[f.type .. "/" .. f.name] = f.value end
      return out
    end
    local fed, empty = filters(storage.P.ind.hopper), filters(storage.P.empty.hopper)
    local ty = shared.signal_type(e.additive)
    check("hopper report: dosed machines counted, a short machine and the units it lacks",
      fed["virtual/es-fed"] == 1 and fed["virtual/es-starved"] == nil and empty["virtual/es-starved"] == 1
        and empty["virtual/es-fed"] == nil and empty[ty .. "/" .. e.additive] == e.dose,
      serpent.line({fed = fed, empty = empty, want = e}))
  end
  do
    -- Neither hidden power entity draws an icon (0.48.1: the feeding-back one flashed no-power).
    local flags = {}
    for _, name in ipairs({"es-power-draw", "es-power-give"}) do
      local src = prototypes.entity[name].electric_energy_source_prototype
      table.insert(flags, src.render_no_power_icon == false and src.render_no_network_icon == false)
    end
    check("hidden power entities draw no power icons", flags[1] and flags[2], serpent.line(flags))
  end
  do
    local fp = storage.forced_power
    -- Its buffer fills only if the network feeds it (its status read the same either way).
    check("the hidden consumer draws from the network", fp and fp.power_energy > 0,
      fp and string.format("energy %.0f J", fp.power_energy) or "not recorded")
  end
  local s_true = es("effect_on", "gear", {[storage.speed_additive] = 9}, "speed")
  local ratio = P.speed.crafts / math.max(P.speed_ctrl.crafts, 1)
  info(string.format("speed: %s x9 on gears, true %+.1f%%: %d crafts vs %d undosed (%.3f x)", storage.speed_additive,
    s_true * 100, P.speed.crafts, P.speed_ctrl.crafts, ratio))
  check("a dosed machine crafts at its composition's hidden speed", P.speed_ctrl.crafts > 300
    and math.abs(ratio - (1 + s_true)) < 0.02, string.format("%.3f vs %.3f", ratio, 1 + s_true))
  local pst = es("crafter_state", P.ind.entity.unit_number)
  local p_true = es("effect_on", "gear", {[a] = storage.best_dose}, "pollution")
  local e = P.ind.entity
  local per_craft = e.electric_emissions_per_joule.pollution * e.prototype.get_max_energy_usage() * 60
    * e.get_recipe().energy / e.crafting_speed
  local p_exp = -p_true * per_craft * P.ind.crafts
  check("a dosed machine's pollution changes by its composition's hidden effect", math.abs(pst.polluted - p_exp)
    <= 0.02 * math.abs(p_exp) + per_craft, string.format("%.1f vs %.1f (effect %+.1f%%)", pst.polluted, p_exp, p_true * 100))
  -- (0.72) The dose panel's count: what a machine made with its dose and how many the dose added. The steady
  -- machine counts every product since its first dosed craft; the redosed one only since its new dose.
  do
    local s1 = es("crafter_state", P.ind.entity.unit_number)
    local pf1 = P.ind.entity.products_finished
    local s2 = es("crafter_state", P.redose.entity.unit_number)
    local pf2 = P.redose.entity.products_finished
    check("a machine counts what it made with its dose, and what the dose added",
      s1.dose_made and s1.dose_made >= 0.9 * pf1 and s1.dose_made <= pf1 and s1.dose_extra == s1.bonus_total,
      string.format("made %s of %d finished, extra %s, bonus %s", tostring(s1.dose_made), pf1, tostring(s1.dose_extra),
        tostring(s1.bonus_total)))
    check("a new dose starts the count again",
      storage.redose_at and s2.dose_made and s2.dose_made > 0 and s2.dose_made <= pf2 - storage.redose_at,
      string.format("made %s since the change, %d finished, %s at the change", tostring(s2.dose_made), pf2,
        tostring(storage.redose_at)))
  end
  -- Premixes: unlocked by the station's evidence of synergy, never otherwise.
  local pp = storage.premix_pair
  local x, y = pp.a < pp.b and pp.a or pp.b, pp.a < pp.b and pp.b or pp.a
  local inter_s = es("interaction", storage.station2.unit_number, "gear", x .. ":5+" .. y .. ":5", x .. ":5", y .. ":5")
  local order = {coal = 1, wood = 2, stone = 3, ["copper-cable"] = 5}  -- their places in the additive list
  local f1, f2 = pp.a, pp.b
  if order[f1] > order[f2] then f1, f2 = f2, f1 end
  local stable_r = game.forces.player.recipes["es-premix-" .. f1 .. "-" .. f2]
  local vol_r = game.forces.player.recipes["es-premix-" .. f1 .. "-" .. f2 .. "-v"]
  local unlocked = stable_r.enabled or (vol_r and vol_r.enabled) or false
  local shown = inter_s and inter_s.p and inter_s.p < 0.05 and inter_s.estimate > 0
  info(string.format("premix pair %s + %s (true interaction %+.1f%%): station %s, unlocked %s", x, y, pp.inter * 100,
    inter_s and string.format("%+.1f%% p=%.4f", inter_s.estimate / 10, inter_s.p or -1) or "no estimate", tostring(unlocked)))
  check("a premix unlocks when the station shows its families' synergy (final p < 0.05 means unlocked)",
    (not shown or unlocked) and (not unlocked or es("discovered", "player")[(vol_r and vol_r.enabled) and vol_r.name or stable_r.name]),
    tostring(unlocked))
  -- (0.72) Order does not matter: a set completed by its controls unlocks too (before, only a mixture's own
  -- sample ran the check). A fresh force's history: the mixture, each alone, then the controls last.
  do
    local f = game.forces["es-premix-order"] or game.create_force("es-premix-order")
    local key = x .. ":5+" .. y .. ":5"
    es("simulate_history", f.name, "nauvis", {{target = "gear", mix = {[x] = 5, [y] = 5}, n = 150},
      {target = "gear", mix = {[x] = 5}, n = 150}, {target = "gear", mix = {[y] = 5}, n = 150},
      {target = "gear", n = 150}}, 4242)
    local st = es("premix_state", f.name, "nauvis", "gear", key)
    local shown = st and st.ready and st.p and st.p < 0.05 and st.estimate > 0
    check("a premix unlocks when its controls complete the set, not only on a mixture's sample",
      shown and st.enabled, st and string.format("%s: counts %s, p %s, estimate %s, unlocked %s", st.recipe,
        serpent.line(st.counts), tostring(st.p), tostring(st.estimate), tostring(st.enabled)) or "no premix for the pair")
  end
  -- (0.72) A heated mixture unlocks its premix through its own band: the mixture with its fluid at 60 degrees,
  -- the fluid alone at 60, the solid alone, the control (before, a banded member never matched an additive).
  do
    local best, F, S = -1, nil, nil
    for _, f in ipairs({"water", "crude-oil", "heavy-oil", "light-oil", "petroleum-gas", "lubricant"}) do
      for _, sol in ipairs({"coal", "wood", "stone", "copper-cable"}) do
        local A, B = shared.additive(f), shared.additive(sol)
        if A and B and A.family ~= B.family then
          local inter = es("gain_mix", "gear", {[f] = 40, [sol] = 5}) - es("gain", "gear", f, 40) - es("gain", "gear", sol, 5)
          if inter > best then best, F, S = inter, f, sol end
        end
      end
    end
    local f = game.forces["es-premix-hot"] or game.create_force("es-premix-hot")
    local hot = F .. "@" .. shared.temp_band(60)
    local parts = {hot .. ":40", S .. ":5"}
    table.sort(parts)
    local key = table.concat(parts, "+")
    es("simulate_history", f.name, "nauvis", {{target = "gear", mix = {[F] = 40, [S] = 5}, temps = {[F] = 60}, n = 150},
      {target = "gear", mix = {[F] = 40}, temps = {[F] = 60}, n = 150}, {target = "gear", mix = {[S] = 5}, n = 150},
      {target = "gear", n = 150}}, 4243)
    local st = es("premix_state", f.name, "nauvis", "gear", key)
    local shown = st and st.ready and st.p and st.p < 0.05 and st.estimate > 0
    check("a heated mixture's synergy unlocks its premix, judged against the fluid alone at the same temperature",
      best > 0.02 and shown and st.enabled, st and string.format("%s (true synergy %+.1f%%): counts %s, p %s, unlocked %s",
        key, best * 100, serpent.line(st.counts), tostring(st.p), tostring(st.enabled)) or (key .. ": no premix state"))
  end
  -- (0.72) A premix with results is listed on the screen even with its recipe locked (the playtest kit pipes one
  -- in; as every additive, it shows once there is evidence on it).
  do
    local f = game.forces["es-premix-seen"] or game.create_force("es-premix-seen")
    local pm
    for _, p in ipairs(shared.premixes) do
      if prototypes.fluid[p.name] and not (f.recipes[p.name] and f.recipes[p.name].enabled) then pm = p.name; break end
    end
    local before = pm and es("visible_additives", f.name)[pm]
    if pm then es("simulate_history", f.name, "nauvis", {{target = "gear", mix = {[pm] = 40}, n = 3}}, 77) end
    local after = pm and es("visible_additives", f.name)[pm]
    check("a locked premix with results is listed on the screen, and not before",
      pm ~= nil and not before and after == true, string.format("%s: before %s, after %s", tostring(pm), tostring(before), tostring(after)))
  end
  -- (0.72, the variety rules) A target's floor: its trial's lost ore against the cheapest trial's, capped, times the
  -- map's science richness for its process mix (the generated spread); and a settled question pays exactly it.
  do
    local D = shared.data
    local R = RICHNESS[es("floor_parts", "gear").strength or "standard"] or RICHNESS.standard
    local lref = math.huge
    for _, t in ipairs(shared.targets) do
      if not t.registered and prototypes.recipe[shared.control_trial(t.key)] then lref = math.min(lref, es("floor_parts", t.key).lost) end
    end
    local bad, settled_bad = {}, {}
    for _, key in ipairs({"gear", "circuit", "steel", "blue", "plastic"}) do
      local fp = es("floor_parts", key)
      local sum = 0
      for c, share in pairs(shared.target(key).process) do sum = sum + share * (fp.richness[c] or 0) end
      local want = math.min(D.floor_cap_x * D.floor, D.floor * fp.lost / lref) * math.exp(R.sd * sum)
      if math.abs(fp.floor - want) > 1e-9 then table.insert(bad, string.format("%s %.4f vs %.4f", key, fp.floor, want)) end
      -- A settled question: a thousand samples of a cell exactly at break-even and as many controls.
      local obs = {control = {n = 1000, sum = 0, sumsq = 1000 * 100}}
      local tau = es("tau", key, {coal = 3})
      obs["coal:3"] = {n = 1000, sum = 1000 * (tau - 400), sumsq = 1000 * ((tau - 400) ^ 2 + 100)}
      local rate = es("rate_on", obs, key, "coal:3")
      if math.abs(rate - fp.floor) > 1e-6 then table.insert(settled_bad, string.format("%s %.4f vs %.4f", key, rate, fp.floor)) end
    end
    -- The cheapest of the mod's own trials keeps the base floor (a registered target never moves the anchor).
    local gp = es("floor_parts", "gear")
    local gsum = 0
    for c, share in pairs(shared.target("gear").process) do gsum = gsum + share * (gp.richness[c] or 0) end
    local anchored = math.abs(gp.floor / math.exp(R.sd * gsum) - D.floor) < 1e-9
    check("a target's floor follows its lost ore, the cap and the map's richness; a settled question pays it",
      #bad == 0 and #settled_bad == 0 and R.sd > 0 and anchored, string.format("sd %.2f; gears at the base floor %s; floors %s; settled %s",
        R.sd, tostring(anchored),
        #bad == 0 and "ok" or table.concat(bad, ", "), #settled_bad == 0 and "ok" or table.concat(settled_bad, ", ")))
  end
  -- (0.72) Alternative recipes retired: a save's route evidence is pruned on load, and a route sample left in transit
  -- is discarded as unreadable.
  do
    local u = storage.station2.unit_number
    es("seed_history", u, "gear", "route:cast", {10, 20})
    es("seed_history", u, "gear@cast", "coal:3", {10, 20})
    local before = es("station_history", u, "gear")["route:cast"] ~= nil and next(es("station_history", u, "gear@cast")) ~= nil
    es("prune_routes")
    local after = es("station_history", u, "gear")["route:cast"] == nil and next(es("station_history", u, "gear@cast")) == nil
    check("route evidence from before 0.72 is pruned", before and after, string.format("seeded %s, pruned %s", tostring(before),
      tostring(after)))
  end
  check("only one variant of a premix is unlocked, the one the map chose",
    not (stable_r.enabled and vol_r and vol_r.enabled)
    and (not unlocked or (vol_r and vol_r.enabled) == (es("truth").premix_volatile["es-premix-" .. f1 .. "-" .. f2] == true)))
  local ps = es("station", storage.station2.unit_number, "gear").summaries["es-premix-coal-stone:2"]
  local pt = es("gain", "gear", "es-premix-coal-stone", 2) * 1000
  check("station estimate for a dosed premix near truth", ps and ps.n and ps.n > 10
    and math.abs(ps.mean - pt) < 4 * math.sqrt(ps.var / ps.n), ps and ps.n and string.format("n=%d %.0f vs %.0f", ps.n, ps.mean, pt) or "no data")
  check("a volatile premix has its stable twin's chemistry",
    es("gain", "gear", "es-premix-coal-stone-v", 2) == es("gain", "gear", "es-premix-coal-stone", 2)
    and es("effect_on", "gear", {["es-premix-coal-stone-v"] = 2}, "speed") == es("effect_on", "gear", {["es-premix-coal-stone"] = 2}, "speed"))
  -- No two crafting machines overlap (create_entity does not check; two pairs did, unseen, until 0.71).
  do
    local over, ms = {}, game.surfaces.nauvis.find_entities_filtered{type = {"assembling-machine", "furnace"}}
    for i, a in ipairs(ms) do
      local A = a.bounding_box
      for j = i + 1, #ms do
        local B = ms[j].bounding_box
        if A.left_top.x < B.right_bottom.x - 0.05 and B.left_top.x < A.right_bottom.x - 0.05
            and A.left_top.y < B.right_bottom.y - 0.05 and B.left_top.y < A.right_bottom.y - 0.05 then
          table.insert(over, string.format("%s at %.1f,%.1f and %s at %.1f,%.1f", a.name, a.position.x, a.position.y,
            ms[j].name, ms[j].position.x, ms[j].position.y))
        end
      end
    end
    check("no two machines overlap", #over == 0, table.concat(over, "; "))
  end
  -- (0.71) Nothing overlaps a fluid hopper (create_entity does not check: in the playtest kit a pipe built into
  -- one left it unconnected).
  do
    local over = {}
    for _, surf in pairs(game.surfaces) do
      for _, fh in pairs(surf.find_entities_filtered{name = "es-fluid-hopper"}) do
        local b = fh.bounding_box
        for _, o in pairs(surf.find_entities_filtered{area = {{b.left_top.x + 0.05, b.left_top.y + 0.05},
            {b.right_bottom.x - 0.05, b.right_bottom.y - 0.05}}}) do
          if o.unit_number ~= fh.unit_number and o.type ~= "character" and next(o.prototype.collision_mask.layers or {}) then
            table.insert(over, string.format("%s at %.1f,%.1f (%s)", o.name, fh.position.x, fh.position.y, surf.name))
          end
        end
      end
    end
    check("nothing overlaps a fluid hopper", #over == 0, table.concat(over, "; "))
  end
  -- Hoppers (0.71): fluids go into fluid hoppers; no hopper builds a hidden fluid port.
  check("no hopper carries a hidden fluid port", storage.hidden_ports == 0, tostring(storage.hidden_ports))
  -- Presets.
  check("a preset is saved once", storage.preset_first == true and storage.preset_again == false
    and #es("presets", "player") == 1)
  -- A mixture whose single additives were never tested alone: no contrast, no crash.
  local okp, inter0 = pcall(es, "interaction", storage.station.unit_number, "gear", "lubricant:30+stone:2", "lubricant:30", "stone:2")
  check("interaction with an untested single is empty, not an error", okp and inter0 == nil, tostring(inter0))

  -- Mixtures: model properties.
  local names = {"coal", "wood", "stone", "stone-brick", "copper-cable", "sulfur", "lubricant", "water"}
  local cap_ok, sym_ok, single_ok, overlap_ok = true, true, true, true
  local resp_of = es("truth").responsiveness or {}
  local worst_cap = 0
  for i = 1, #names do
    for j = i + 1, #names do
      for _, da in ipairs({1, 3, 5, 8}) do
        local a, b = names[i], names[j]
        local sa = (a == "lubricant" or a == "water") and da * 11 or da
        local sb = (b == "lubricant" or b == "water") and 50 or 4
        for _, tk in ipairs({"gear", "circuit", "engine"}) do
          local ga, gb = es("gain", tk, a, sa), es("gain", tk, b, sb)
          local gm = es("gain_mix", tk, {[a] = sa, [b] = sb})
          if math.abs(gm - es("gain_mix", tk, {[b] = sb, [a] = sa})) > 1e-12 then sym_ok = false end
          local best = math.max(ga, gb, 0)
          -- The cap scales with the target's responsiveness, like every effect.
          local resp = resp_of[tk] or 1
          if gm > best + 0.3 * resp + 1e-9 then cap_ok = false; worst_cap = math.max(worst_cap, gm - best) end
        end
      end
    end
  end
  for _, tk in ipairs({"gear", "circuit"}) do
    for d = 1, 9 do
      if math.abs(es("gain_mix", tk, {stone = d}) - es("gain", tk, "stone", d)) > 1e-12 then single_ok = false end
      -- Same family (stone, stone brick): no synergy, overlap only.
      local gs, gb = es("gain", tk, "stone", d), es("gain", tk, "stone-brick", d)
      local gm = es("gain_mix", tk, {stone = d, ["stone-brick"] = d})
      if gm > math.max(gs, 0) + math.max(gb, 0) + math.min(gs, 0) + math.min(gb, 0) + 1e-9 then overlap_ok = false end
    end
  end
  check("mixture of one additive equals the additive", single_ok)
  check("mixture gain does not depend on order", sym_ok)
  check("stacking adds at most 30% (x responsiveness) over the best single effect", cap_ok, worst_cap)
  check("same family: no synergy, only overlap", overlap_ok)
  check("synergy is lawful by family (stone and stone brick pair alike with coal)",
    es("pair_strength", "coal", "stone") == es("pair_strength", "coal", "stone-brick") and es("pair_strength", "stone", "stone-brick") == 0)

  -- Response surface: recovers a known quadratic surface exactly.
  local pts = {}
  for _, ab in ipairs({{0, 0}, {3, 0}, {6, 0}, {0, 3}, {0, 6}, {3, 3}, {6, 6}, {3, 6}, {6, 3}}) do
    local a, b = ab[1], ab[2]
    table.insert(pts, {a = a, b = b, n = 8, mean = 100 + 20 * a + 10 * b - 2 * a * a - b * b + 3 * a * b, ss = 7 * 400})
  end
  local sf = es("fit_surface_points", pts)
  check("surface fit recovers coefficients", sf.error == nil and math.abs(sf.coef[2] - 20) < 1e-6
    and math.abs(sf.coef[6] - 3) < 1e-6 and math.abs(sf.coef[5] + 1) < 1e-6, sf.error or serpent.line(sf.coef))
  check("surface optimum stays within the tested range", sf.best and sf.best.a <= 6 and sf.best.b <= 6,
    sf.best and string.format("a %.1f b %.1f", sf.best.a, sf.best.b))

  -- The 2x2 experiment: interaction estimate near the true interaction.
  local unit = storage.station.unit_number
  local inter = es("interaction", unit, "gear", "lubricant:40+sulfur:3", "lubricant:40", "sulfur:3")
  local true_inter = (es("gain_mix", "gear", {lubricant = 40, sulfur = 3}) - es("gain", "gear", "lubricant", 40)
    - es("gain", "gear", "sulfur", 3)) * 1000
  check("interaction estimated near the truth", inter and math.abs(inter.estimate - true_inter)
    < 2 * (inter.hi - inter.lo), inter and string.format("%.0f [%.0f, %.0f] vs true %.0f", inter.estimate, inter.lo, inter.hi, true_inter))


  -- Discovery chains.
  local tr = truth.traits
  local lawful = true
  for _, cat in ipairs(shared.additives) do
    if not cat.refined_from then goto next_catalyst end
    local sp, rf = tr[cat.refined_from].affinity, tr[cat.name]
    local dot, ns, nr = 0, 0, 0
    for class, v in pairs(sp) do dot = dot + v * rf.affinity[class]; ns = ns + v * v; nr = nr + rf.affinity[class] ^ 2 end
    if dot / math.sqrt(ns * nr) < 0.999 or rf.potency < 0.7 then lawful = false end
    ::next_catalyst::
  end
  check("refined catalysts follow their residue's direction, potent", lawful)
  -- Refining unlocks by evidence: exactly when the station shows the residue's effect at p < 0.05.
  local rs5, rctl = st.summaries["es-spent-stone:5"], st.summaries.control
  local p_res = es("welch", rs5, rctl)
  local unlocked = game.forces.player.recipes["es-refine-stone"].enabled
  check("refining locked before any evidence", storage.discovery_before == false)
  -- The station re-tests after every sample, so an unlock can come from an early swing that later
  -- data does not confirm (a false lead, which the design accepts). What must hold: significant at the
  -- end means unlocked, and an unlock is recorded as a discovery.
  -- (A gain, not any effect: residues mostly harm, and a clear harm is no lead.)
  local gain_shown = p_res and p_res < 0.05 and rs5 and rctl and rs5.mean > rctl.mean
  check("refining unlocks by evidence (a gain at p < 0.05 at the station)",
    (not gain_shown or unlocked) and (not unlocked or es("discovered", "player")["es-refined-stone"] == true),
    string.format("final p = %s, unlocked %s", tostring(p_res), tostring(unlocked)))
  check("a residue's own recipe unlocks with its activation", game.forces.player.recipes["es-spent-stone"].enabled == unlocked,
    string.format("gravel recipe %s, activation %s", tostring(game.forces.player.recipes["es-spent-stone"].enabled), tostring(unlocked)))
  -- And directly, whatever this map discovered: a fresh force's ash unlock opens both recipes.
  local fresh = game.forces.residue_probe or game.create_force("residue_probe")
  local before = fresh.recipes["es-spent-coal"].enabled or fresh.recipes["es-refine-coal"].enabled
  es("unlock_activation", "residue_probe", "es-spent-coal")
  check("a discovery opens the residue's recipe and its activation, closed before",
    not before and fresh.recipes["es-spent-coal"].enabled and fresh.recipes["es-refine-coal"].enabled)
  check("a catalyst or residue mixes as its family",
    es("mix_family", "es-refined-coal") == "carbon" and es("mix_family", "es-spent-coal") == "carbon"
      and es("mix_family", "es-spent-stone") == "mineral" and es("mix_family", "es-refined-plastic-bar") == "polymer"
      and es("mix_family", "coal") == "carbon",
    string.format("%s %s %s %s", es("mix_family", "es-refined-coal"), es("mix_family", "es-spent-coal"),
      es("mix_family", "es-spent-stone"), es("mix_family", "es-refined-plastic-bar")))
  -- And the hidden world uses it: activated carbon with coal is one family, so the mix is exactly the
  -- same-family rule (harms add, the strongest gain counts fully and the other by `overlap`, stacking
  -- capped), with no pair term.
  local gc, gr = es("gain", "gear", "coal", 3), es("gain", "gear", "es-refined-coal", 2)
  local gm = es("gain_mix", "gear", {coal = 3, ["es-refined-coal"] = 2})
  local mc = es("mix_constants")
  local hi, lo = math.max(gc, gr), math.min(gc, gr)
  local tot = (lo < 0 and lo or 0) + (hi < 0 and hi or 0)
  if hi > 0 then tot = tot + hi + (lo > 0 and mc.overlap * lo or 0) end
  local best = math.max(hi, 0)
  local cap = (es("truth").responsiveness or {}).gear and es("truth").responsiveness.gear * mc.stack_cap or mc.stack_cap
  local want = tot > best and best + cap * (1 - math.exp(-(tot - best) / cap)) or tot
  check("activated carbon and coal mix as one family (no pair term)", math.abs(gm - want) < 1e-9,
    string.format("mix %+.4f, same-family rule %+.4f (coal %+.3f, activated %+.3f)", gm, want, gc, gr))
  local cat_premix
  for name in pairs(prototypes.recipe) do
    if name:find("^es%-premix%-") and name:find("es%-refined%-") then cat_premix = name end
  end
  check("activated catalysts can be premixed (the top rung)", cat_premix ~= nil, cat_premix)
  -- Residues by family (0.39): a solid tier 2 additive leaves its family's residue; a fluid leaves none.
  check("a solid additive leaves its family's residue; a fluid leaves none",
    storage.rigs.sulfur.spent > 0 and storage.rigs.lub.spent == 0 and storage.rigs.lub.trials > 0,
    string.format("sulfur bench: %d residue; lubricant bench: %d", storage.rigs.sulfur.spent, storage.rigs.lub.spent))
  for _, key in ipairs({"es-spent-stone:5", "es-refined-stone:2"}) do
    local s = st.summaries[key]
    local name, dose = key:match("^(.+):(%d+)$")
    local true_permille = es("gain", "gear", name, tonumber(dose)) * 1000
    check("station estimate for " .. key .. " near truth", s and s.n > 10
      and math.abs(s.mean - true_permille) < 4 * math.sqrt(s.var / s.n),
      s and string.format("n=%d %.0f vs %.0f", s.n, s.mean, true_permille) or "no data")
  end

  -- A losing effect with instant pickup: output per input comes to (1 + g) of the recipe's.
  local nr = storage.neg_rig
  local ng = nr.gain
  local recipe = nr.entity.get_recipe()
  local first = recipe.ingredients[1]
  local consumed = nr.fed[first.name] - nr.entity.get_inventory(defines.inventory.crafter_input).get_item_count(first.name)
  local gears = nr.gears + nr.entity.get_inventory(defines.inventory.crafter_output).get_item_count("iron-gear-wheel")
  local nominal_per_input = recipe.products[1].amount / first.amount
  local effective = gears / consumed / nominal_per_input
  info(string.format("losing dose (%s on gears, true %+.1f%%): %d gears from %d %s, output per input %.3f of recipe",
    nr.worst and (nr.worst.name .. " x" .. nr.worst.dose) or "none", ng * 100, gears, consumed, first.name, effective))
  local ncs = es("crafter_state", nr.entity.unit_number)
  info(string.format("  crafts %d, script loss %d products, inputs taken %d, debt %d",
    nr.entity.products_finished, -ncs.bonus_total, ncs.inputs_taken, ncs.debt))
  if ng < -0.02 then
    check("a loss applies even when inserters empty the output at once", math.abs(effective - (1 + ng)) < 0.04,
      string.format("%.3f vs %.3f", effective, 1 + ng))
  else
    info("no early dose loses on gears on this map: loss check skipped")
  end

  -- Chart renders on the hidden surface (no player needed).
  local n = es("draw_chart", 1, {points = {{dose = 0, mean = 0, lo = -50, hi = 50, control = true},
    {dose = 3, mean = 120, lo = 60, hi = 180}}, optimum = {dose = 3}})
  check("chart draws", n > 10, n .. " render objects")

  -- The productivity cap.
  local rc = storage.red_cap
  local near, at = P.cap_near.entity, P.cap_at.entity
  local near_s, at_s = es("crafter_state", near.unit_number), es("crafter_state", at.unit_number)
  local allowed = math.min(rc.gain, 4 / (1 + rc.research) - 1)
  check("the mod's yield stops at the productivity cap (near it: only the gap)",
    rc.gain > allowed and near.products_finished > 100
      and math.abs(near_s.bonus_total - allowed * near.products_finished) <= 2,
    string.format("%s gain %+.1f%%, allowed %+.2f%%: %d extra for %d products (%.1f expected)", rc.additive,
      rc.gain * 100, allowed * 100, near_s.bonus_total, near.products_finished, allowed * near.products_finished))
  local at_p = at.productivity_bonus + rc.research
  check("the mod's yield stops at the productivity cap (at it: nothing)",
    at_p >= 3 and at.products_finished > 100 and at_s.bonus_total == 0,
    string.format("P %.2f: %d extra for %d products", at_p, at_s.bonus_total, at.products_finished))
  local at_status = es("dose_state", at.unit_number).status
  check("the dose panel says a machine is at the productivity cap", at_status and at_status[1] == "es.dose-capped",
    serpent.line(at_status))

  -- A backed-up machine: nothing on the ground, and its extra products are in the output or waiting.
  local bl = storage.P.blocked.entity
  local ground = bl.surface.count_entities_filtered{name = "item-on-ground", position = bl.position, radius = 4}
  local bout = bl.get_inventory(defines.inventory.crafter_output).get_item_count("iron-gear-wheel")
  local bstate = es("crafter_state", bl.unit_number)
  check("a backed-up machine keeps its extra products (none spilled)", ground == 0 and bstate.bonus_total > 5,
    string.format("%d on the ground, %d in the output, %d extra so far, %d crafts", ground, bout, bstate.bonus_total,
      bl.products_finished))

  -- Hopper links are cached per machine: they must follow hoppers built and removed around it.
  local am = place("assembling-machine-2", 80, 50)
  local count = function() return es("dose_state", am.unit_number).hoppers end
  local seen = {count()}
  local h1 = place("es-hopper", 82, 50)
  table.insert(seen, count())
  h1.destroy{raise_destroy = true}
  table.insert(seen, count())
  place("es-hopper", 80, 52); place("es-hopper", 78, 50)
  table.insert(seen, count())
  check("a machine's hoppers follow builds and removals (cached links)",
    table.concat(seen, ",") == "0,1,0,2", table.concat(seen, ","))

  -- Spoilage: stale inputs fail the trial; fresh ones are analysed.
  if storage.rigs.stale then
    local cf = es("station", storage.station.unit_number, "carbon-fiber")
    local cfn = cf.summaries.control and cf.summaries.control.n or 0
    check("a trial on stale inputs fails (counted, not analysed); a fresh one is analysed",
      cf.failed > 0 and storage.rigs.stale.trials > 0 and cfn > 0,
      string.format("stale trials %d, failed runs %d; fresh analysed %d", storage.rigs.stale.trials, cf.failed, cfn))
  end

  -- Liquid premixes and temperature.
  do
    local LP = storage.lp
    local temps_seen = {}
    for _, temp in ipairs({15, 90}) do
      local r = storage.rigs["lp" .. temp]
      temps_seen[temp] = r.last_temp
    end
    check("a liquid premix's temperature is written on its samples",
      temps_seen[15] and math.abs(temps_seen[15] - 15) < 1 and temps_seen[90] and math.abs(temps_seen[90] - 90) < 1,
      serpent.line(temps_seen))
    -- Evidence per temperature band: 15 degrees is the premix's usual band (unsuffixed: made at 15), 90
    -- is band 4 (75-90); one research question.
    local gs = es("station", storage.station.unit_number, "gear").summaries
    local b0, b4 = gs[LP .. ":40"], gs[LP .. "@4:40"]
    local q = es("question_state", "player", "gear", LP)
    check("a liquid premix's evidence is kept per temperature band, one research question",
      b0 and b0.n > 0 and b4 and b4.n > 0 and gs[LP .. "@0:40"] == nil and q.best ~= nil,
      string.format("band 0: %s, band 4: %s, best cell %s", tostring(b0 and b0.n), tostring(b4 and b4.n), tostring(q.best)))
    -- Every fluid additive: at its usual temperature nothing changes; heated, its effect moves.
    local lub_usual = es("gain_at_temps", "gear", {lubricant = 40}, {lubricant = 25})
    local lub_hot = es("gain_at_temps", "gear", {lubricant = 40}, {lubricant = 90})
    check("a vanilla fluid is unchanged at its usual temperature and changes when heated (lubricant)",
      math.abs(lub_usual - es("gain_mix", "gear", {lubricant = 40})) < 1e-12 and math.abs(lub_hot - lub_usual) > 1e-6,
      string.format("%+.2f%% at 25, %+.2f%% at 90", lub_usual * 100, lub_hot * 100))
    -- The burner fluid heater: water in at 15, out at 60.
    local hot = storage.heater_out and storage.heater_out.fluidbox[1]
    check("a fluid heater passes the same fluid on at its temperature (lubricant 25 -> 60)",
      hot and hot.name == "lubricant" and math.abs(hot.temperature - 60) < 0.5,
      hot and string.format("%s at %.1f", hot.name, hot.temperature) or "nothing out")
    if storage.chill then
      local fed, dry = storage.chill[1], storage.chill[2]
      local o = fed.out.fluidbox[1]
      local left = fed.entity.get_fuel_inventory().get_item_count("es-cold-charge")
      local d = dry.out.fluidbox[1]
      check("a fluid chiller passes a liquid premix on at the chilled cold, burning cold charges; with none, nothing",
        o and o.name == LP and math.abs(o.temperature - shared.chilled.temperature) < 0.5 and left < fed.fuel
          and left >= fed.fuel - 1 and not (d and d.amount > 0),
        string.format("registered %d; out %s, charges left %d of %d, unfuelled out %s", es("chillers"), o and string.format("%s at %.1f", o.name, o.temperature)
          or "nothing", left, fed.fuel, d and string.format("%.0f", d.amount) or "nothing"))
    end
    local g15 = es("gain_at_temps", "gear", {[LP] = 40}, {[LP] = 15})
    local g90 = es("gain_at_temps", "gear", {[LP] = 40}, {[LP] = 90})
    local best = es("premix_best_temp", LP)
    check("temperature changes what a liquid premix does (hidden best temperature)", best and math.abs(g15 - g90) > 1e-6,
      string.format("best %.0f degrees: %+.2f%% at 15, %+.2f%% at 90", best or -1, g15 * 100, g90 * 100))
    for _, temp in ipairs({15, 90}) do
      local m = storage.P["lp" .. temp]
      local g = temp == 15 and g15 or g90
      local exp = m.crafts * (1 + g)
      if g >= 0 then
        check("a line dosed at " .. temp .. " degrees follows the gain at " .. temp,
          m.crafts > 50 and math.abs(m.made - exp) <= 2 + 0.02 * exp, string.format("%d crafts, %d vs %.0f", m.crafts, m.made, exp))
      else
        info(string.format("the premix loses at %d degrees on this map (%+.1f%%)", temp, g * 100))
      end
    end
  end

  -- Planet conditions.
  if storage.rigs.vulcanus then
    local vpool = es("pool_summaries", "player", "vulcanus", "gear")
    local vkey = storage.activator .. ":" .. storage.best_dose
    local vn = vpool[vkey] and vpool[vkey].n or 0
    check("samples from Vulcanus count for Vulcanus, wherever analysed", vn > 0 and storage.rigs.vulcanus.trials > 0,
      string.format("%d Vulcanus trials, %d in Vulcanus's evidence", storage.rigs.vulcanus.trials, vn))
    local gv = es("gain_on_surface", "gear", storage.vulcanus_dose, "vulcanus")
    local gn = es("gain_on_surface", "gear", storage.vulcanus_dose, "nauvis")
    check("conditions change what an additive does, never on Nauvis", math.abs(gv - gn) > 1e-6 and
      math.abs(gn - es("gain_mix", "gear", storage.vulcanus_dose)) < 1e-12,
      string.format("Nauvis %+.2f%%, Vulcanus %+.2f%%", gn * 100, gv * 100))
    local pv = storage.P.vulcanus
    local exp = pv.crafts * (1 + gv)
    if gv >= 0 then
      check("a dosed machine on Vulcanus follows Vulcanus's gain", pv.crafts > 50 and math.abs(pv.made - exp) <= 2 + 0.02 * exp,
        string.format("%d crafts, %d vs %.0f (Nauvis would be %.0f)", pv.crafts, pv.made, exp, pv.crafts * (1 + gn)))
    else
      info(string.format("the activator loses on Vulcanus (%+.1f%%)?", gv * 100))
    end
  end

  -- The migration to planets: an old single pool becomes the Nauvis pool; old memory ids become Nauvis's.
  local mig = es("migrate_to_planets", {[1] = {obs = {gear = {control = {n = 3, sum = 30, sumsq = 400}}}, side = {},
    analysed = 3, unreadable = 0}}, {[1] = {["gear|coal"] = 0.2, ["nauvis|gear|wood"] = 0.4}})
  check("old pools and research memory become Nauvis's (idempotent)",
    mig.pools[1].nauvis and mig.pools[1].nauvis.obs.gear.control.n == 3 and mig.pools[1].obs == nil
      and mig.memory[1]["nauvis|gear|coal"] == 0.2 and mig.memory[1]["gear|coal"] == nil
      and mig.memory[1]["nauvis|gear|wood"] == 0.4, serpent.line(mig.memory))

  -- A fluid-fed target runs on the bench (its fluid input) and its samples are analysed.
  local pr = storage.rigs.plastic
  local pst = es("station", storage.station.unit_number, "plastic")
  check("a fluid-fed trial runs on the bench and is analysed (plastic, petroleum gas)",
    pr.trials > 3 and pst.summaries.control and pst.summaries.control.n > 0,
    string.format("%d trials, %s analysed", pr.trials, tostring(pst.summaries.control and pst.summaries.control.n)))

  -- Research data (slice 2).
  local st1 = es("station", storage.station.unit_number, "gear")
  local made_here = storage.station.get_inventory(defines.inventory.chest).get_item_count("es-research-data")
  check("stations make research data, at most one per sample",
    es("data_made", "player") > 0 and es("data_made", "player") <= st1.pool_analysed and made_here > 0,
    string.format("%.1f data for %d samples; %d items in the first station", es("data_made", "player"), st1.pool_analysed, made_here))
  -- The full cost (0.44): with machine time, power and pollution free, it is the net ore rule exactly,
  -- (gain - break-even) / (1 + gain); priced, a faster dose saves more.
  do
    local P0 = {machine = "assembling-machine-2", speed_factor = 1, machine_second = 0, mj = 0, pollution = 0}
    local g, tau0 = 0.08, es("tau", "red", {coal = 3}) / 1000
    local f0 = es("full_saving", "red", {coal = 3}, g, 0, 0, 0, P0)
    local early = shared.prices.early
    local slow = es("full_saving", "red", {coal = 3}, g, 0, 0, 0, early)
    local fast = es("full_saving", "red", {coal = 3}, g, 0.2, 0, 0, early)
    check("full cost: with only ore priced it is the net ore rule; priced, speed saves more",
      math.abs(f0 - (g - tau0) / (1 + g)) < 1e-9 and fast > slow,
      string.format("%.5f vs %.5f; slow %.4f, fast %.4f", f0, (g - tau0) / (1 + g), slow, fast))
  end
  local tau = es("tau", "gear", {coal = 3})
  check("break-even gain: coal x3 on a 60-ore gear batch is 50 per mille (the whole dose is spent)",
    math.abs(tau - 50) < 1e-6, tau)
  -- An additive with no gear sample at all (the question is the additive, whatever the dose).
  local untested
  for _, a in ipairs(shared.additives) do
    local seen = false
    for key in pairs(st1.summaries) do if key:find(a.name .. ":", 1, true) == 1 then seen = true end end
    if not seen and not a.fluid then untested = a.name; break end
  end
  local ur = untested and es("data_rate", "player", "gear", untested .. ":3")
  check("an untested question pays in full", ur and math.abs(ur - 1) < 1e-9, tostring(untested) .. ": " .. tostring(ur))
  -- The most settled question on gears (a clear harm settles fast), for the memory check below.
  local qs_before, akey = {openness = 2}, nil
  for _, a in ipairs(shared.additives) do
    local q = es("question_state", "player", "gear", a.name)
    if q.best and q.openness < qs_before.openness then qs_before, akey = q, q.best end
  end
  local rate_before = akey and es("data_rate", "player", "gear", akey) or 1
  -- Technologies: precision, throughput, instrumentation (set, checked, then unset).
  local techs = game.forces.player.technologies
  techs["es-precision-instruments-1"].researched = true
  techs["es-station-throughput-1"].researched = true
  techs["es-circuit-instrumentation-1"].researched = true
  es("set_view_target", storage.station.unit_number, "gear")
  local sig = {}
  for _, f in pairs(st1.port.get_control_behavior().get_section(1).filters) do sig[f.value.name] = f.min end
  check("precision instruments cut trial noise; throughput adds a sample per pack",
    math.abs(es("noise_factor", "player") - 0.85) < 1e-9 and es("samples_per_pack", "player") == 5,
    string.format("noise x%.2f, %d per pack", es("noise_factor", "player"), es("samples_per_pack", "player")))
  techs["es-precision-instruments-1"].researched = false
  techs["es-station-throughput-1"].researched = false
  techs["es-circuit-instrumentation-1"].researched = false
  local lab = game.surfaces[1].create_entity{name = "lab", position = {70, 60}, force = "player"}
  check("labs take research data", lab.get_inventory(defines.inventory.lab_input).insert{name = "es-research-data", count = 1} == 1)
  -- Space Age: productivity research of a recipe the mod studies costs research data (slice 4).
  local sp = game.forces.player.technologies["steel-plate-productivity"]
  if sp then
    local wants = false
    for _, i in pairs(sp.research_unit_ingredients) do if i.name == "es-research-data" then wants = true end end
    local biolab = prototypes.entity["biolab"]
    local bio_takes = false
    for _, name in pairs(biolab and biolab.lab_inputs or {}) do if name == "es-research-data" then bio_takes = true end end
    check("steel productivity needs research data, and the biolab takes it", wants and bio_takes)
  else
    info("no Space Age: steel productivity not checked")
  end

  check("a station waiting for packs raises an alert; a supplied one does not",
    es("station_alert", storage.alert_starved.unit_number) == "packs" and es("station_alert", storage.alert_fed.unit_number) == nil,
    tostring(es("station_alert", storage.alert_starved.unit_number)) .. " / " .. tostring(es("station_alert", storage.alert_fed.unit_number)))

  -- The closed loop swept doses by its own samples: several coal doses, each only as the count advanced.
  local hist = es("station_history", storage.auto_station.unit_number, "gear")
  local doses, auto_n = {}, 0
  for key, sm in pairs(hist) do
    local d = key:match("^coal:(%d+)$")
    if d and sm.n > 0 then doses[#doses + 1] = tonumber(d) end
    auto_n = auto_n + (sm.n or 0)
  end
  table.sort(doses)
  check("the automation wing sweeps doses from its own port (closed loop through combinators)",
    #doses >= 6 and hist.control and hist.control.n > 0,
    string.format("%d samples; coal doses tested: %s; control n %s", auto_n, table.concat(doses, ","),
      tostring(hist.control and hist.control.n)))

  -- The pool: removing a station keeps the force's evidence; clearing one target leaves the others.
  local before = es("station", storage.station.unit_number, "gear")
  local circuit_before = es("station", storage.station.unit_number, "circuit").summaries["stone:4"]
  storage.qstation.destroy{raise_destroy = true}
  local after = es("station", storage.station.unit_number, "gear")
  check("removing a station keeps the force's evidence", after.pool_analysed == before.pool_analysed
    and after.summaries.control and after.summaries.control.n == before.summaries.control.n,
    string.format("%d -> %d analysed", before.pool_analysed, after.pool_analysed))
  es("clear_target", "player", "gear")
  local rate_after = akey and es("data_rate", "player", "gear", akey) or 1
  check("clearing a target does not re-pay what was settled (the force remembers)",
    qs_before.openness < 0.9 and rate_after < 0.95,
    string.format("%s: openness before %.2f; rate %.2f before the clear, %.2f after", tostring(akey), qs_before.openness,
      rate_before, rate_after))
  local gear_after = es("station", storage.station.unit_number, "gear").summaries
  local circuit_after = es("station", storage.station.unit_number, "circuit").summaries["stone:4"]
  local gear_keys = 0
  for _, sm in pairs(gear_after) do if sm.n and sm.n > 0 then gear_keys = gear_keys + 1 end end
  check("clearing a target clears only that target", gear_keys == 0 and circuit_before and circuit_before.n > 0
    and circuit_after and circuit_after.n == circuit_before.n,
    string.format("gear cells left %d; circuit stone:4 %s -> %s", gear_keys, tostring(circuit_before and circuit_before.n),
      tostring(circuit_after and circuit_after.n)))

  -- Names from an older version (premixes were per family pair before 0.19): a dose row naming one
  -- is emptied in place, a preset naming one is dropped on load. Last, so no other check sees it.
  local u = storage.rigs.two.entity.unit_number
  es("set_dose", u, {rows = {{name = "es-premix-mineral-carbon", dose = 2}, {name = "coal", dose = 1}}})
  local rows = es("dose_state", u).settings.rows
  check("an unknown additive in dose settings becomes an empty row",
    rows[1].name == nil and rows[2].name == "coal" and rows[2].dose == 1)
  es("add_preset", "player", "iron-gear-wheel", {["es-premix-mineral-carbon"] = 2})
  local before = #es("presets", "player")
  es("prune")
  check("a preset naming an unknown additive is dropped on load", #es("presets", "player") == before - 1,
    before .. " -> " .. #es("presets", "player"))

  -- Liquid premixes became fluids: one unlocked as its (now gone) volatile item stays unlocked.
  do
    local LP = storage.lp
    local rec = game.forces.player.recipes
    rec[LP].enabled = false
    es("mark_discovered", "player", LP .. "-v")
    es("rerun_init")
    check("a liquid premix unlocked as a volatile item stays unlocked", rec[LP].enabled, LP)
  end

  -- 0.72: Mastery is gone; research data feeds vanilla's endless technologies instead, and a
  -- question's openness falls with all its samples; a set pays the floor until its members
  -- are tested alone.
  do
    local left = {}
    for name in pairs(prototypes.technology) do if name:find("^es%-mastery") then table.insert(left, name) end end
    check("no Mastery technology is left", #left == 0, table.concat(left, ", "))
    local missing, priced = {}, 0
    for name, tech in pairs(prototypes.technology) do
      if tech.max_level == 4294967295 and not name:find("^es%-") then
        local has = false
        for _, ing in pairs(tech.research_unit_ingredients) do if ing.name == "es-research-data" then has = true end end
        if has then priced = priced + 1 else table.insert(missing, name) end
      end
    end
    check("every endless vanilla technology takes research data", #missing == 0 and priced > 0,
      priced .. " priced; missing: " .. table.concat(missing, ", "))
    local function acc(mean, sd, n_) return {n = n_, sum = mean * n_, sumsq = n_ * (mean * mean + sd * sd)} end
    local sweep = {control = acc(0, 40, 10)}
    for d = 1, 8 do sweep["coal:" .. d] = acc(0, 40, 1) end
    local next_dose = es("rate_on", sweep, "gear", "coal:9")
    check("a dose sweep that never repeats does not keep its question fully open", next_dose < 0.9,
      string.format("a ninth dose would earn %.2f", next_dose))
    local pair = {control = acc(0, 40, 10), ["coal:3+stone:2"] = acc(0, 40, 1)}
    local before = es("rate_on", pair, "gear", "coal:3+stone:2")
    pair["coal:3"] = acc(0, 40, 2); pair["stone:2"] = acc(0, 40, 2)
    local after = es("rate_on", pair, "gear", "coal:3+stone:2")
    local gear_floor = es("floor_parts", "gear").floor  -- (0.72: each target's own floor)
    check("a pair pays the floor until each member has two samples alone; then more",
      math.abs(before - gear_floor) < 1e-9 and after > gear_floor + 0.05,
      string.format("before %.2f, after %.2f", before, after))
  end

  do
    -- The science seed (0.70): a new map with the setting at 0 takes the map's seed; a science seed builds
    -- its own world. Last of the checks: the hook re-runs init_storage, which re-applies every machine's
    -- dose (a starved one's mark is cleared until its next craft). Run on two map seeds, the seeded fingerprint must be the same (scripts compare it).
    local r = es("science_seed_check", 271828)
    check("the science seed: 0 takes the map's, another builds its own world",
      r.live_seed == r.map_seed and r.seeded_seed == 271828 and r.seeded ~= r.live,
      string.format("live seed %s (map %s); seeded world %s from 271828, live world %s", tostring(r.live_seed),
        tostring(r.map_seed), tostring(r.seeded), tostring(r.live)))
  end

  -- Curve parameters and gains, for checking docs/plot_curves.py against the real formulas.
  for tkey, target in pairs(truth.targets) do
    for name, r in pairs(target) do
      local gains = {}
      for d = 0, 9 do gains[d + 1] = es("gain", tkey, name, d) end
      local re = {}
      for k, v in pairs(r) do re[k] = v end
      re.shape = es("shape_of", tkey, name)  -- (family law on new worlds: the shape the curve really has)
      table.insert(lines, "CURVE " .. helpers.table_to_json({r = re, gains = gains, max_dose = shared.additive(name).max_dose,
        k = es("gain_scale", tkey, name)}))
    end
  end

  table.insert(lines, failed == 0 and "DONE ALL PASSED"
    or ("DONE " .. failed .. " FAILED: " .. table.concat(failed_names, "; ")))
  helpers.write_file(OUT, table.concat(lines, "\n") .. "\n")
end)
