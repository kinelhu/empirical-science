local shared = require("__empirical-science__.shared")
-- Builds a ready-to-judge world for a short playtest: every feature already running,
-- labelled in-world, with supply chests near spawn. scripts/make_playtest.sh saves it to the dev profile.
local es = function(fn, ...) return remote.call("empirical-science", fn, ...) end
local s
-- Which save this build is (scripts/make_playtest.sh writes kit_choice.lua, gitignored): one theme per save,
-- so each save's evidence is its own experiment. Without the file: every area.
local ok_choice, choice = pcall(require, "kit_choice")
local KIT = ok_choice and choice or nil
local function want(name) return KIT == nil or KIT == name end

local function place(name, x, y, dir)
  local e = s.create_entity{name = name, position = {x, y}, force = "player", raise_built = true, direction = dir}
  if not e then error("could not place " .. name .. " at " .. x .. "," .. y) end
  return e
end
local function supply(x, y, items)
  local c = place("infinity-chest", x, y)
  local filters = {}
  for i, it in ipairs(items) do filters[i] = {name = it[1], count = it[2] or 100, mode = "at-least", index = i} end
  c.infinity_container_filters = filters
  return c
end
local function sink(x, y) local c = place("infinity-chest", x, y); c.remove_unfiltered_items = true; return c end
local function pipe_in(x, y, fluid, temp)
  local p = place("infinity-pipe", x, y)
  p.set_infinity_pipe_filter{name = fluid, percentage = 1, temperature = temp or 25}
end
-- A fluid hopper (0.71: 1x2, as the pump): its near tile at (x, y), touching the machine, the other one step
-- (dx, dy) away; returns where a pipe meets its far end.
local function fluid_hopper(x, y, dx, dy)
  local tx, ty = math.floor(x) + 0.5, math.floor(y) + 0.5
  place("es-fluid-hopper", tx + dx * 0.5, ty + dy * 0.5, dx ~= 0 and defines.direction.east or defines.direction.north)
  return tx + dx * 2, ty + dy * 2
end
local function label(x, y, text)
  local d = place("display-panel", x, y)
  d.display_panel_text = text
  d.display_panel_always_show = true
end
-- (0.72) The sample a trial makes, and a station set to take that kind (its window's choice).
local function sample_of(trial) return prototypes.recipe[trial].main_product.name end
local function take(st, trial)  -- (0.72: a station takes the samples of the packs it holds; nothing to set)
  return st
end
local function filtered(x, y, dir, item, ...)
  local i = place("fast-inserter", x, y, dir)
  i.use_filters = true
  for k, name in ipairs({item, ...}) do i.set_filter(k, {name = name, quality = "normal"}) end
  return i
end
local N, S, E, W = defines.direction.north, defines.direction.south, defines.direction.east, defines.direction.west
-- A hopper at (x, y) fed from a chest two tiles north through an inserter. (0.65: residues leave the
-- machine with its products, so every dosed line's output reaches a sink.)
local function hopper_at(x, y, item)
  local h = place("es-hopper", x, y)
  if item then supply(x, y - 2, {{item}}); place("fast-inserter", x, y - 1, N) end
  return h
end
local function dose(entity, doses, circuit)
  local rows = {}
  for name, d in pairs(doses or {}) do table.insert(rows, {name = name, dose = d}) end
  es("set_dose", entity.unit_number, {rows = rows, circuit = circuit})
end

-- A planet's surface, cleared around the origin, floored, powered, without enemies.
local function planet_surface(name)
  local p = game.planets[name]
  if not p then return nil end
  local surf = p.surface or p.create_surface()
  surf.request_to_generate_chunks({0, 0}, 3); surf.force_generate_chunk_requests()
  surf.peaceful_mode = true
  for _, e in pairs(surf.find_entities_filtered{area = {{-40, -40}, {40, 40}}}) do
    if e.type ~= "character" then e.destroy() end
  end
  for _, e in pairs(surf.find_entities_filtered{force = "enemy"}) do e.destroy() end
  local tiles = {}
  for x = -40, 39 do for y = -40, 39 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
  surf.set_tiles(tiles)
  return surf
end
local function power_here()
  local eei = place("electric-energy-interface", -35, -35); eei.power_production = 1e8; eei.electric_buffer_size = 1e8
  for x = -31, 40, 18 do for y = -33, 40, 18 do place("substation", x, y) end end
end
-- A station at (sx, sy) taking samples from a bench four tiles east (filtered inserter between), packs
-- from a chest above it; the bench's products and residues out to a sink below it.
local function station_bench(sx, sy, trial, inputs, pack, out_items)
  local st = place("es-analysis-station", sx, sy)
  supply(sx, sy - 3, {{pack, 100}}); place("fast-inserter", sx, sy - 2, N)
  local b = place("es-test-bench", sx + 4, sy)
  b.set_recipe(trial)
  take(st, trial)
  supply(sx + 4, sy - 3, inputs); place("fast-inserter", sx + 4, sy - 2, N)
  filtered(sx + 2, sy, E, sample_of(trial))
  filtered(sx + 4, sy + 2, N, table.unpack(out_items)); sink(sx + 4, sy + 3)
  return st, b
end
local function best_for(target, effect, names)
  local best, bv = nil, -1e9
  for _, n in ipairs(names) do
    local v = es("effect_on", target, {[n] = 5}, effect)
    if v > bv then best, bv = n, v end
  end
  return best, bv
end

local space_age_areas, findings_area
-- The complete save (es-complete, "every data point for every additive already populated"):
-- every recipe enabled, and a history run through the real trial and analysis code (simulate_history: the
-- hidden world plus noise, analysed as a station would) for every target on its own planet: every additive
-- at every dose, fluids in temperature bands, living additives in ripeness bands, the early pairs. Built only
-- when asked for by name (scripts/make_playtest.sh complete): it takes minutes.
local function complete_world()
  local force = game.forces.player
  for _, r in pairs(force.recipes) do r.enabled = true end
  local where = {}  -- pack -> surface name
  local planet_of = {["metallurgic-science-pack"] = "vulcanus", ["agricultural-science-pack"] = "gleba",
    ["electromagnetic-science-pack"] = "fulgora", ["cryogenic-science-pack"] = "aquilo"}
  local function surface_for(pack)
    if where[pack] then return where[pack] end
    local name = "nauvis"
    if planet_of[pack] and game.planets[planet_of[pack]] then
      name = (game.planets[planet_of[pack]].surface or game.planets[planet_of[pack]].create_surface()).name
    elseif pack == "space-science-pack" or pack == "promethium-science-pack" then
      local pf = force.create_space_platform{name = "Research platform", planet = "nauvis",
        starter_pack = "space-platform-starter-pack"}
      if pf then pf.apply_starter_pack(); name = pf.surface.name end
    end
    where[pack] = name
    return name
  end
  local names = {}
  for _, a in ipairs(shared.all_additives) do
    if prototypes.item[a.name] or prototypes.fluid[a.name] then table.insert(names, a) end
  end
  local early = {}
  for _, a in ipairs(shared.early) do table.insert(early, a.name) end
  local function doses(a, k)  -- k doses spread over the additive's range (9: every dose)
    local maxd = a.max_dose or shared.max_dose
    local out = {}
    for i = 1, k do
      local step = k == 9 and i or ({2, 5, 8})[i]
      table.insert(out, math.max(1, math.floor(step * maxd / shared.max_dose + 0.5)))
    end
    return out
  end
  local TEMPS = {0, 22, 37, 52, 67, 82, 120, 180, 300, 450, -60, -120}
  local RIPE = {0.1, 0.3, 0.5, 0.7, 0.9}
  local total, targets = 0, 0
  for ti, t in ipairs(shared.targets) do
    if prototypes.recipe[shared.trial_recipe(t.key)] then
      local surf = surface_for(es("target_pack", t.key))
      local plan = {{target = t.key, n = 24}}
      for _, a in ipairs(names) do
        for _, d in ipairs(doses(a, 9)) do table.insert(plan, {target = t.key, mix = {[a.name] = d}, n = 6}) end
        if a.fluid or a.premix_of and prototypes.fluid[a.name] then
          for _, temp in ipairs(TEMPS) do
            for _, d in ipairs(doses(a, 3)) do
              table.insert(plan, {target = t.key, mix = {[a.name] = d}, temps = {[a.name] = temp}, n = 4})
            end
          end
        elseif a.living then
          for _, r in ipairs(RIPE) do
            for _, d in ipairs(doses(a, 3)) do
              table.insert(plan, {target = t.key, mix = {[a.name] = d}, temps = {[a.name] = r}, n = 4})
            end
          end
        end
      end
      if surf == "nauvis" then
        for i, x in ipairs(early) do
          for j = i + 1, #early do
            for _, d1 in ipairs({2, 5, 8}) do
              for _, d2 in ipairs({2, 5, 8}) do
                table.insert(plan, {target = t.key, mix = {[x] = d1, [early[j]] = d2}, n = 3})
              end
            end
          end
        end
      end
      total = total + es("simulate_history", "player", surf, plan, 7919 * ti, true)  -- (readings only: seconds, not minutes)
      targets = targets + 1
    end
  end
  storage.kit_complete = {samples = total, targets = targets}
end

script.on_init(function()
  s = game.surfaces.nauvis
  -- Every vanilla item and fluid counted as made once: the dose picker offers what the force has made
  -- or can make, and the kit's supplies come from infinity chests, not production.
  -- Additives only (every item would include module 3s and unlock their achievements).
  for _, a in ipairs(shared.additives) do
    if not a.name:find("^es%-") then
      local st = a.fluid and game.forces.player.get_fluid_production_statistics(s) or game.forces.player.get_item_production_statistics(s)
      st.on_flow(a.name, 1)
    end
  end
  -- Everything researched (0.72: Mastery, which the kit left out, is gone).
  for _, t in pairs(game.forces.player.technologies) do t.researched = true end
  s.request_to_generate_chunks({0, 0}, 5); s.force_generate_chunk_requests()
  -- No enemies: the kit is played for an hour to test the mod (the showcase lost its power poles to
  -- small biters on one map in fifteen).
  s.peaceful_mode = true
  game.map_settings.enemy_expansion.enabled = false
  for _, e in pairs(s.find_entities_filtered{force = "enemy"}) do e.destroy() end
  -- (x to 100 since 0.72: the fluids area's third temperature rig reaches 95.)
  for _, e in pairs(s.find_entities_filtered{area = {{-90, -70}, {100, 70}}}) do
    if e.type ~= "character" then e.destroy() end
  end
  local tiles = {}
  for x = -90, 99 do for y = -70, 69 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
  s.set_tiles(tiles)
  local eei = place("electric-energy-interface", -85, -65); eei.power_production = 1e8; eei.electric_buffer_size = 1e8
  for x = -81, 99, 18 do for y = -63, 70, 18 do place("substation", x, y) end end

  -- Supplies near spawn: everything the checklist asks you to build or feed.
  local sup = {
    {{"es-test-bench", 50}, {"es-analysis-station", 10}, {"es-hopper", 50}, {"es-fluid-hopper", 20}, {"fast-inserter", 100}},
    {{"fast-inserter", 100}, {"transport-belt", 200}, {"medium-electric-pole", 50}, {"pipe", 100}},
    {{"constant-combinator", 20}, {"arithmetic-combinator", 20}, {"decider-combinator", 20}, {"selector-combinator", 20}},
    {{"automation-science-pack", 200}, {"logistic-science-pack", 200}, {"chemical-science-pack", 200}, {"iron-chest", 50}},
    {{"iron-plate", 200}, {"copper-plate", 200}, {"steel-plate", 200}, {"iron-gear-wheel", 200}},
    {{"coal", 100}, {"stone", 100}, {"wood", 100}, {"stone-brick", 100}, {"copper-cable", 200}},
    {{"sulfur", 100}, {"plastic-bar", 100}, {"solid-fuel", 100}, {"engine-unit", 50}, {"pipe", 100}},
  }
  for i, items in ipairs(sup) do supply(-9 + 3 * i, 6, items) end
  label(0, 3, "Supplies: take what you need from the chests below.")

  if want("lab") then
  -- A. Red science, the natural first target (simple products like gears barely respond): benches dosed
  -- from hoppers (right edge) -> belt -> station (science packs have no alternative recipes).
  -- (0.72, user: one or two doses each left Dose-response nothing to fit: stone and copper cable get three,
  -- across the range.)
  local A = {{"control"}, {"stone", 2}, {"stone", 5}, {"stone", 8}, {"copper-cable", 2}, {"copper-cable", 5},
    {"copper-cable", 8}, {"coal", 4}, {"wood", 4}, {"stone-brick", 4}}
  local y = -30
  for i, a in ipairs(A) do
    local x = -64 + (i - 1) * 5
    local b = place("es-test-bench", x, y)
    local recipe, inputs = "es-trial-red-control", {{"copper-plate"}, {"iron-gear-wheel"}}
    if a[1] ~= "control" then
      hopper_at(x + 2, y, a[1])
      dose(b, {[a[1]] = a[2]})
    end
    b.set_recipe(recipe)
    supply(x, y - 3, inputs); place("fast-inserter", x, y - 2, N)
    place("fast-inserter", x, y + 2, N)
  end
  for x = -66, -12 do place("transport-belt", x, y + 3, E) end
  local sa = take(place("es-analysis-station", -16, y + 6), "es-trial-red-control")
  filtered(-16, y + 4, N, sample_of("es-trial-red-control"))
  place("fast-inserter", -12, y + 4, N); sink(-12, y + 5)
  supply(-19, y + 6, {{"automation-science-pack", 50}}); place("fast-inserter", -18, y + 6, W)
  label(-40, y - 6, "A. Red science test benches, each dosed from the hopper on its right (open a bench: its dose panel) -> belt -> station. "
    .. "Residues ride the belt with the samples; the inserter at its end clears them.")

  end

  -- B. Two benches around one station: east doses lubricant from circuit signals (a sweep from
  -- ordinary combinators), west doses spent stone from its panel (a discovery-chain residue).
  local bx, by = 30.5, -29.5
  -- The residue hint with the clearest gain on this map, on a target a bench can run from plain inputs
  -- (most residues harm; one that helps is the discovery-chain hint worth showing), at its best dose.
  local SIMPLE = {gear = {{"iron-plate"}}, circuit = {{"iron-plate"}, {"copper-cable", 200}}, steel = {{"iron-plate"}}}
  local RESULT = {gear = "iron-gear-wheel", circuit = "electronic-circuit", steel = "steel-plate"}
  local residue, rtarget, best_dose, best_gain = "es-spent-stone", "gear", 5, -1
  -- Only targets whose trial fits the kit's run several times over (a steel trial is over two minutes
  -- on a bench since 0.20: the rig would show nothing), read from the prototypes, not by name.
  local bench_speed = prototypes.entity["es-test-bench"].get_crafting_speed()
  local function quick(tk) return prototypes.recipe["es-trial-" .. tk .. "-control"].energy / bench_speed < 60 end
  for tk in pairs(SIMPLE) do
    if quick(tk) then for _, parent in ipairs({"coal", "wood", "stone", "copper-cable", "sulfur", "plastic-bar"}) do
      for d = 1, 9 do
        local g = es("gain", tk, "es-spent-" .. parent, d)
        if g > best_gain then residue, rtarget, best_dose, best_gain = "es-spent-" .. parent, tk, d, g end
      end
    end end
  end
  storage.kit_residue = {name = residue, target = rtarget, dose = best_dose, gain = best_gain}
  if want("lab") then
  local east = place("es-test-bench", bx + 4, by)
  local west = place("es-test-bench", bx - 4, by)
  for _, b in ipairs({{east, "gear"}, {west, rtarget}}) do
    local e, tk = b[1], b[2]
    e.set_recipe("es-trial-" .. tk .. "-control")
    supply(e.position.x, by - 3, SIMPLE[tk]); place("fast-inserter", e.position.x, by - 2, N)
    filtered(e.position.x, by + 2, N, RESULT[tk]); sink(e.position.x, by + 3)  -- (a residue dose leaves no residue)
  end
  local sb = take(place("es-analysis-station", bx, by), "es-trial-gear-control")
  filtered(bx + 2, by, E, sample_of("es-trial-gear-control"))   -- picks from the east bench, drops into the station
  filtered(bx - 2, by, W, sample_of("es-trial-" .. rtarget .. "-control"))   -- picks from the west bench
  assert(sample_of("es-trial-" .. rtarget .. "-control") == sample_of("es-trial-gear-control"),
    "area C's two benches make different kinds of sample: give the west bench its own station")
  supply(bx, by - 3, {{"automation-science-pack", 50}}); place("fast-inserter", bx, by - 2, N)
  local px, py = fluid_hopper(bx + 6, by, 1, 0)
  pipe_in(px, py, "lubricant")
  dose(east, nil, true)
  hopper_at(bx - 6, by, residue)
  dose(west, {[residue] = best_dose})
  -- A dose sweep from ordinary combinators: a clock counts T to 5400 ticks and restarts; T / 600
  -- gives a step 0..8; x 10 gives the lubricant dose (0 = no signal = control trials).
  local WC = defines.wire_connector_id
  local function wire(a, a_id, b, b_id)
    local ok = a.get_wire_connector(a_id, true).connect_to(b.get_wire_connector(b_id, true))
    if not ok then error("wire failed: " .. a.name .. " -> " .. b.name) end
  end
  local one = place("constant-combinator", bx + 1, by - 6)
  one.get_or_create_control_behavior().get_section(1).filters =
    {{value = {type = "virtual", name = "signal-T", quality = "normal"}, min = 1}}
  local clock = place("decider-combinator", bx + 3, by - 6, E)
  clock.get_or_create_control_behavior().parameters = {
    conditions = {{first_signal = {type = "virtual", name = "signal-T"}, comparator = "<", constant = 5400}},
    outputs = {{signal = {type = "virtual", name = "signal-T"}, copy_count_from_input = true}}}
  local step = place("arithmetic-combinator", bx + 6, by - 6, E)
  step.get_or_create_control_behavior().parameters = {first_signal = {type = "virtual", name = "signal-T"},
    second_constant = 600, operation = "/", output_signal = {type = "virtual", name = "signal-D"}}
  local dose_c = place("arithmetic-combinator", bx + 9, by - 6, E)
  dose_c.get_or_create_control_behavior().parameters = {first_signal = {type = "virtual", name = "signal-D"},
    second_constant = 10, operation = "*", output_signal = {type = "fluid", name = "lubricant"}}
  wire(one, WC.circuit_red, clock, WC.combinator_input_red)
  wire(clock, WC.combinator_output_red, clock, WC.combinator_input_red)
  wire(clock, WC.combinator_output_red, step, WC.combinator_input_red)
  wire(step, WC.combinator_output_red, dose_c, WC.combinator_input_red)
  wire(dose_c, WC.combinator_output_red, east, WC.circuit_red)
  label(bx, by - 9, "B. East bench: lubricant dose from a circuit sweep (0 to 80). West bench: a residue, dosed from its panel.")
  end

  -- C. Production: a circuit line dosed lubricant 30 + stone 2 (a hopper on its right takes stone by inserter,
  -- a fluid hopper on its left lubricant by pipe), saved as a preset; two gear lines sharing one hopper.
  local fx, fy = 30.5, 20.5
  if want("lab") then
  local ca = place("assembling-machine-2", fx, fy)
  ca.set_recipe("electronic-circuit")
  supply(fx, fy - 3, {{"iron-plate"}, {"copper-cable", 200}}); place("fast-inserter", fx, fy - 2, N)
  place("fast-inserter", fx, fy + 2, N); sink(fx, fy + 3)
  hopper_at(fx + 2, fy, "stone")
  local lx, ly = fluid_hopper(fx - 2, fy, -1, 0)
  pipe_in(lx, ly, "lubricant")
  dose(ca, {lubricant = 30, stone = 2})
  es("add_preset", "player", "circuit", {lubricant = 30, stone = 2})
  for _, gx in ipairs({fx + 8, fx + 12}) do
    local ga = place("assembling-machine-2", gx, fy)
    ga.set_recipe("iron-gear-wheel")
    supply(gx, fy - 3, {{"iron-plate"}}); place("fast-inserter", gx, fy - 2, N)
    place("fast-inserter", gx, fy + 2, N); sink(gx, fy + 3)
    dose(ga, {coal = 3})
  end
  hopper_at(fx + 10, fy, "coal")
  label(fx + 6, fy - 7, "C. Production: circuits dosed lubricant 30 + stone 2 (stone hopper on the right, lubricant fluid hopper on the left); two gear lines share the hopper between them (coal 3).")
  end

  -- H. A quality agent (with the quality mod): gears dosed with the first agent at its best dose, into
  -- a chest, so the upgraded gears can be seen among the normal ones.
  if want("quality") and shared.agents[1] then
    local agent, best_d, best_c = shared.agents[1].name, 1, -1
    for d = 1, shared.max_dose do
      local c = es("quality_chance", "gear", {[agent] = d})
      if c > best_c then best_d, best_c = d, c end
    end
    local hx = fx + 18
    local qa = place("assembling-machine-2", hx, fy)
    qa.set_recipe("iron-gear-wheel")
    supply(hx, fy - 3, {{"iron-plate"}}); place("fast-inserter", hx, fy - 2, N)
    place("fast-inserter", hx, fy + 2, N)
    storage.kit_quality = {chest = place("steel-chest", hx, fy + 3), agent = agent, dose = best_d, chance = best_c}
    hopper_at(hx + 2, fy, agent)
    dose(qa, {[agent] = best_d})
    label(hx, fy - 7, "H. Quality agent: gears dosed with " .. agent .. " (x" .. best_d .. "). Some come out a tier up: open the chest below.")
  end

  -- E. Discovery rig: the same residue hint at scale, so the evidence can become clear during a session:
  -- four dosed benches and two controls on that target, a belt, their own station.
  local ex, ey = 20, 45
  if want("discovery") then
  for i = 0, 5 do
    local x = ex + i * 6
    local b = place("es-test-bench", x, ey)
    b.set_recipe("es-trial-" .. rtarget .. "-control")
    supply(x, ey - 3, SIMPLE[rtarget]); place("fast-inserter", x, ey - 2, N)
    place("fast-inserter", x, ey + 2, N)
    if i < 4 then
      hopper_at(x + 2, ey, residue)
      dose(b, {[residue] = best_dose})
    end
  end
  for x = ex - 2, ex + 38 do place("transport-belt", x, ey + 3, E) end
  local se = take(place("es-analysis-station", ex + 34, ey + 6), "es-trial-" .. rtarget .. "-control")
  filtered(ex + 34, ey + 4, N, sample_of("es-trial-" .. rtarget .. "-control"))
  place("fast-inserter", ex + 38, ey + 4, N); sink(ex + 38, ey + 5)
  supply(ex + 31, ey + 6, {{"automation-science-pack", 100}}); place("fast-inserter", ex + 32, ey + 6, W)
  label(ex + 15, ey - 6, "E. Discovery rig: a residue hint on " .. rtarget .. " (four dosed benches, two controls). "
    .. "Watch its station: when the effect is clear, activation unlocks.")
  end

  -- F. Premix rig: the tier 1 pair from different families with the strongest synergy on red science,
  -- as a 2x2 (mixture, each alone, control) into its own station: when the synergy is clear, the pair's
  -- premix unlocks.
  local T1F = {coal = "carbon", wood = "organic", stone = "mineral", ["copper-cable"] = "metal"}
  local best_i, pa, pb = -1e9, "coal", "stone"
  for x in pairs(T1F) do
    for y in pairs(T1F) do
      if x < y then
        local inter = es("gain_mix", "red", {[x] = 5, [y] = 5}) - es("gain", "red", x, 5) - es("gain", "red", y, 5)
        if inter > best_i then best_i, pa, pb = inter, x, y end
      end
    end
  end
  storage.kit_pair = {a = pa, b = pb, inter = best_i}
  local fx0, fy0 = -40, 45
  if want("discovery") then
  local cells = {{[pa] = 5, [pb] = 5}, {[pa] = 5}, {[pb] = 5}, {}}
  for i, doses in ipairs(cells) do
    local x = fx0 + (i - 1) * 6
    local b = place("es-test-bench", x, fy0)
    b.set_recipe("es-trial-red-control")
    supply(x, fy0 - 3, {{"copper-plate"}, {"iron-gear-wheel"}}); place("fast-inserter", x, fy0 - 2, N)
    place("fast-inserter", x, fy0 + 2, N)
    local names = {}
    for name in pairs(doses) do table.insert(names, name) end
    if #names > 0 then
      -- One inserter per additive (one feeding two fills the hopper with whichever it grabs first).
      place("es-hopper", x + 2, fy0)
      supply(x + 2, fy0 - 2, {{names[1]}}); place("fast-inserter", x + 2, fy0 - 1, N)
      if names[2] then supply(x + 4, fy0, {{names[2]}}); place("fast-inserter", x + 3, fy0, E) end
      dose(b, doses)
    end
  end
  for x = fx0 - 2, fx0 + 24 do place("transport-belt", x, fy0 + 3, E) end
  local sf = take(place("es-analysis-station", fx0 + 22, fy0 + 6), "es-trial-red-control")
  filtered(fx0 + 22, fy0 + 4, N, sample_of("es-trial-red-control"))
  place("fast-inserter", fx0 + 24, fy0 + 4, N); sink(fx0 + 24, fy0 + 5)
  supply(fx0 + 19, fy0 + 6, {{"automation-science-pack", 100}}); place("fast-inserter", fx0 + 20, fy0 + 6, W)
  label(fx0 + 10, fy0 - 6, "F. Premix rig: " .. pa .. " + " .. pb .. " on red science (mixture, each alone, control). "
    .. "When their synergy is clear at the station, their premix unlocks.")
  end

  -- G. Fluids (0.25-0.27): a plastic trial fed petroleum gas through the bench's top-left fluid input,
  -- into its own station; and two gear lines dosed with the same liquid premix at 15 and 90 degrees.
  do
    local gx, gy = 60, 5
    -- The liquid premix with the best gear gain on this map (at its best temperature): area G and Vulcanus.
    local LP, best = nil, -1e9
    for name, proto in pairs(prototypes.fluid) do
      if name:find("^es%-premix%-") then
        local g = es("gain", "gear", name, 40)
        if g > best then LP, best = name, g end
      end
    end
    storage.kit_liquid = {name = LP, gain = best}
    if want("fluids") then
    local pb = place("es-test-bench", gx, gy)
    pb.set_recipe("es-trial-plastic-control")
    pipe_in(gx, gy - 2, "petroleum-gas")
    supply(gx + 1, gy - 3, {{"coal"}}); place("fast-inserter", gx + 1, gy - 2, N)
    place("fast-inserter", gx, gy + 2, N)
    local gs = take(place("es-analysis-station", gx, gy + 4), "es-trial-plastic-control")
    supply(gx + 3, gy + 4, {{"logistic-science-pack", 100}}); place("fast-inserter", gx + 2, gy + 4, E)
    -- (0.72, user: the save had no results by temperature, and production statistics cannot tell two lines
    -- apart) Three trials of the same liquid premix at 15, 60 and 90 degrees, a station each: their results land
    -- in three temperature bands, side by side on Dose-response.
    storage.kit_temps = {premix = LP, stations = {}}
    for i, temp in ipairs({15, 60, 90}) do
      local st, b = station_bench(gx + 8 + 10 * (i - 1), gy, "es-trial-gear-control", {{"iron-plate"}},
        "automation-science-pack", {"iron-gear-wheel"})
      local px, py = fluid_hopper(b.position.x + 2, b.position.y, 1, 0)
      pipe_in(px, py, LP, temp)
      dose(b, {[LP] = 40})
      storage.kit_temps.stations[temp] = st
    end
    label(gx + 3, gy - 7, "G. Fluids. Left: a plastic trial, petroleum gas into the bench's fluid input. "
      .. "Right: three gear trials with the same liquid premix at 15, 60 and 90 degrees, a station each.")
    -- A third line, heated for real: the premix at 15 through a burner fluid heater (60) into its hopper.
    local h = place("es-fluid-heater", gx + 14, gy + 16, N)
    h.insert{name = "nuclear-fuel", count = 1}  -- lasts hours at a heater's draw
    local inp = h.fluidbox.get_pipe_connections(1)[1].target_position
    local out = h.fluidbox.get_pipe_connections(2)[1].target_position
    pipe_in(inp.x, inp.y, LP, 15)
    place("es-fluid-hopper", out.x, out.y - 0.5, N)   -- (1x2: the heater's output tile and the one above)
    local my = out.y - 3
    local m = place("assembling-machine-2", out.x, my)
    m.set_recipe("iron-gear-wheel")
    supply(out.x, my - 3, {{"iron-plate"}}); place("fast-inserter", out.x, my - 2, N)
    place("fast-inserter", out.x - 1, my + 2, N); sink(out.x - 1, my + 3)
    dose(m, {[LP] = 40})
    label(gx + 14, gy + 20, "G. A fluid heater (burner): the same premix, 15 in, 60 out, into the hopper above it.")
    end
  end

  -- I. Quality from the furnace (0.50): iron smelted with the first agent; the uncommon plates are sorted
  -- into a gear machine set to uncommon and dosed again, so some gears come out rare. No recycler.
  if want("quality") and shared.agents[1] then
    local agent = shared.agents[1].name
    local function best(key)
      local bd, bc = 1, -1
      for d = 1, shared.max_dose do
        local c = es("quality_chance", key, {[agent] = d})
        if c > bc then bd, bc = d, c end
      end
      return bd
    end
    local ix, iy = 70.5, -50.5
    local f = place("electric-furnace", ix, iy)
    supply(ix, iy - 3, {{"iron-ore"}}); place("fast-inserter", ix, iy - 2, N)
    hopper_at(ix + 2, iy, agent)
    local fd = best("iron-plate")
    dose(f, {[agent] = fd})
    place("fast-inserter", ix, iy + 2, N)
    local plates = place("steel-chest", ix, iy + 3)
    -- The sorter: uncommon plates down into the gear machine, normal plates east into a sink.
    local up = place("fast-inserter", ix, iy + 4, N)
    up.use_filters = true
    up.set_filter(1, {name = "iron-plate", quality = "uncommon"})
    filtered(ix + 1, iy + 3, W, "iron-plate"); sink(ix + 2, iy + 3)
    local g = place("assembling-machine-2", ix, iy + 6)
    g.set_recipe("iron-gear-wheel", "uncommon")
    -- A start of uncommon plates, so the second stage runs from the first minute (the furnace's share
    -- arrives slowly: its upgrade chance is a few percent).
    g.get_inventory(defines.inventory.crafter_input).insert{name = "iron-plate", count = 40, quality = "uncommon"}
    hopper_at(ix + 2, iy + 6, agent)
    dose(g, {[agent] = best("gear")})
    place("fast-inserter", ix, iy + 8, N)
    storage.kit_cascade = {plates = plates, gears = place("steel-chest", ix, iy + 9), furnace = f,
      chance = es("quality_chance", "iron-plate", {[agent] = fd})}
    label(ix, iy - 7, "I. Quality from the furnace: iron smelted with " .. agent .. "; uncommon plates sorted into a "
      .. "gear machine set to uncommon and dosed again. Some gears come out rare (chest at the bottom). No recycler.")
  end

  -- J-O (Space Age, 0.67): what came after 0.51, each on the surface it needs. Reach the planets by remote
  -- view (the planets are discovered); the stations and benches open from there.
  if script.active_mods["space-age"] then space_age_areas() end
  s = game.surfaces.nauvis

  -- D. Empty lot for your own design (the adaptive rig in the checklist).
  if want("lab") then label(-40, 25, "D. Your lot: build the adaptive dose sweep from the checklist here.") end
  if want("findings") then findings_area() end
  if KIT == "complete" then complete_world() end
end)

-- The findings save (es-findings): the late game, filled in. Six of Nauvis's quota done, gears proven with
-- coal x3 but short of its volume, and the major findings waiting on the same gear line: running it a few
-- minutes finishes everything (the summary and the achievement). Evidence is written, not grown: the label
-- says so.
findings_area = function()
  s = game.surfaces.nauvis
  local st = es("dossier_state", "player")
  local nauvis = st.planets.nauvis
  -- Seeded readings clear each live bar by 12 points (per mille; the bars re-derive with the model, and
  -- typed values fell under them in 0.70).
  local bars = es("dossier_bars").exceptional
  local above = function(readout) return math.floor(1000 * bars[readout]) + 120 end
  -- (Each its own dose and reading: one value repeated down the tab read as written, which it is, but needlessly.)
  local DOSES = {"stone:4", "coal:2", "stone-brick:5", "copper-cable:3", "coal:6", "stone:7"}
  local n = 0
  for key in pairs(nauvis.targets) do
    if key ~= "gear" and n < nauvis.quota - 1 then
      local dose = DOSES[n % #DOSES + 1]
      es("dossier_seed", "player", "nauvis", key, dose, "yield", above("yield") + 23 * ((n * 5) % 7), 20)
      es("dossier_add_made", "player", key, dose, es("dossier_volume", key))
      n = n + 1
    end
  end
  local vol = es("dossier_volume", "gear")
  -- (0.72, user: the line made no extra products) The gear line runs the dose that truly pays most on this map's
  -- gears, and its yield evidence is that true gain where it clears the bar: production and report agree.
  local best, best_g = {name = "coal", dose = 3}, -1
  for _, a in ipairs(shared.early) do
    for d = 1, shared.max_dose do
      local g = es("gain", "gear", a.name, d)
      if g > best_g then best, best_g = {name = a.name, dose = d}, g end
    end
  end
  local gkey = best.name .. ":" .. best.dose
  es("dossier_seed", "player", "nauvis", "gear", gkey, "yield", math.max(math.floor(best_g * 1000), above("yield")), 20)
  -- (The major yield finding is already one of the six done ones: their yield clears its bar.)
  for _, r in ipairs({{"speed", "speed"}, {"efficiency", "efficiency"}, {"pollution", "cleanliness"}}) do
    es("dossier_seed", "player", "nauvis", "gear", gkey, r[1], above(r[2]), 20)
  end
  -- Short of the volume by what a gear line makes in a few minutes, not in the two the build runs.
  es("dossier_add_made", "player", "gear", gkey, vol - 600)
  local x, y = 0.5, -20.5
  local m = place("assembling-machine-2", x, y)
  m.set_recipe("iron-gear-wheel")
  supply(x, y - 3, {{"iron-plate", 200}}); place("fast-inserter", x, y - 2, N)
  place("fast-inserter", x, y + 2, N); sink(x, y + 3)
  hopper_at(x + 2, y, best.name)
  dose(m, {[best.name] = best.dose})
  storage.kit_findings = {machine = m, key = gkey, gain = best_g}
  label(x, y - 7, "Findings: a late game, filled in (this evidence was written, not measured). Six planet findings "
    .. "are done. This gear line, dosed with the dose that truly pays most on this map's gears, finishes the last one and three major findings: let it run "
    .. "and watch the Findings tab.")
end

space_age_areas = function()
  storage.kit_sa = {}
  local K = storage.kit_sa
  local T1 = {"coal", "wood", "stone", "stone-brick", "copper-cable", "sulfur", "plastic-bar"}

  -- O. Quality packs (Nauvis): a station fed only legendary red packs; one pack analyses six times as much.
  s = game.surfaces.nauvis
  if want("quality") then
    local st = place("es-analysis-station", -60, -55)
    local c = place("steel-chest", -60, -58)
    c.insert{name = "automation-science-pack", count = 20, quality = "legendary"}
    place("fast-inserter", -60, -57, N)
    local b = place("es-test-bench", -56, -55)
    b.set_recipe("es-trial-gear-control")
    supply(-56, -58, {{"iron-plate"}}); place("fast-inserter", -56, -57, N)
    take(st, "es-trial-gear-control")
    filtered(-58, -55, E, sample_of("es-trial-gear-control"))
    filtered(-56, -53, N, "iron-gear-wheel"); sink(-56, -52)
    K.legendary = {station = st, chest = c, given = 20}
    label(-58, -61, "O. Quality packs: this station has only legendary red packs. One legendary pack analyses six times "
      .. "as many samples as a normal one.")
  end
  -- L2. A chilled twin (Nauvis): lubricant at -100 from a cryogenic plant's twin, dosed on a gear bench.
  if want("fluids") then
    local twin = shared.chilled_twin("lubricant")
    if twin then
      local st, b = station_bench(-30, -55, "es-trial-gear-control", {{"iron-plate"}}, "automation-science-pack",
        {"iron-gear-wheel"})
      -- (On the bench's right: below it are its output inserter and sink, which a hopper there overlapped.)
      local px, py = fluid_hopper(b.position.x + 2, b.position.y, 1, 0)
      pipe_in(px, py, twin, -100)
      dose(b, {lubricant = 40})
      K.chilled = {station = st}
      label(-28, -61, "L. Chilled lubricant (-100) from the cryogenic plant's twin, dosed as lubricant: its results "
        .. "land in a cold temperature band.")
    end
  end

  -- L3 (0.71). The fluid chiller (Space Age): the liquid premix in at 15, out at the chilled cold, burning cold
  -- charges, into a fluid hopper beside a dosed gear bench.
  if want("fluids") and prototypes.entity["es-fluid-chiller"] and storage.kit_liquid then
    local LP = storage.kit_liquid.name
    local st, b = station_bench(-16, -55, "es-trial-gear-control", {{"iron-plate"}}, "automation-science-pack",
      {"iron-gear-wheel"})
    -- The fluid hopper on the bench's right, the chiller below its far end, piped up to it.
    local px, py = fluid_hopper(b.position.x + 2, b.position.y, 1, 0)
    local ch = place("es-fluid-chiller", px, py + 3.5, N)
    ch.insert{name = "es-cold-charge", count = 20}
    local inp = ch.fluidbox.get_pipe_connections(1)[1].target_position
    local out = ch.fluidbox.get_pipe_connections(2)[1].target_position
    pipe_in(inp.x, inp.y, LP, 15)
    for y = out.y, py, -1 do place("pipe", out.x, y) end
    dose(b, {[LP] = 40})
    K.chiller = {station = st, premix = LP, entity = ch}
    label(-14, -61, "L. The fluid chiller, burning cold charges, takes " .. LP .. " from 15 to "
      .. shared.chilled.temperature .. ", into the fluid hopper under the bench. Cold bands beyond Nauvis's reach.")
  end

  -- L1. Vulcanus: the pressure heater takes a liquid premix to 500, into a dosed gear bench.
  local vs = want("vulcanus") and planet_surface("vulcanus")
  if vs then
    s = vs
    storage.kit_start = {surface = vs.name, position = {0, 0}}
    power_here()
    local LP = storage.kit_liquid and storage.kit_liquid.name
    local h = place("es-pressure-heater", 0, 10, N)
    h.insert{name = "es-pressure-charge", count = 20}  -- (0.70: its only fuel)
    local inp = h.fluidbox.get_pipe_connections(1)[1].target_position
    local out = h.fluidbox.get_pipe_connections(2)[1].target_position
    pipe_in(inp.x, inp.y, LP, 15)
    place("es-fluid-hopper", out.x, out.y - 0.5, N)   -- (1x2: the heater's output tile and the one above)
    local st, b = station_bench(out.x - 4, out.y - 3, "es-trial-gear-control", {{"iron-plate"}},
      "automation-science-pack", {"iron-gear-wheel"})
    dose(b, {[LP] = 40})
    for _, e in pairs(s.find_entities_filtered{area = {{-40, -40}, {40, 40}}}) do e.destructible = false end
    K.vulcanus = {station = st, premix = LP}
    label(out.x - 2, out.y - 9, "L. Vulcanus: the pressure heater, burning pressure charges, takes " .. LP .. " from 15 "
      .. "to 500, into the hopper under the bench. Hot bands beyond Nauvis's reach.")
  end

  -- J-K. Gleba: a gear bench dosed with yumako mash (it ripens in the hopper; results kept per ripeness
  -- band), and a bioflux bench dosed with the additive that restores most freshness on bioflux.
  local gs = want("gleba") and planet_surface("gleba")
  if gs then
    s = gs
    storage.kit_start = {surface = gs.name, position = {0, 4}}
    power_here()
    local st = take(place("es-analysis-station", 0, 0), "es-trial-gear-control")
    supply(0, -3, {{"automation-science-pack", 100}}); place("fast-inserter", 0, -2, N)
    local west = place("es-test-bench", -4, 0)
    west.set_recipe("es-trial-gear-control")
    supply(-4, -3, {{"iron-plate"}}); place("fast-inserter", -4, -2, N)
    filtered(-2, 0, W, sample_of("es-trial-gear-control"))
    filtered(-4, 2, N, "iron-gear-wheel"); sink(-4, 3)
    hopper_at(-6, 0, "yumako-mash")
    dose(west, {["yumako-mash"] = 5})
    local fresh, fv = best_for("bioflux", "freshness", T1)
    -- (0.72) Bioflux samples are agricultural: a station of their own, set to that kind.
    local bst = take(place("es-analysis-station", 6, 0), "es-trial-bioflux-control")
    supply(6, -3, {{"agricultural-science-pack", 100}}); place("fast-inserter", 6, -2, N)
    local east = place("es-test-bench", 10, 0)
    east.set_recipe("es-trial-bioflux-control")
    supply(10, -3, {{"yumako-mash"}, {"jelly"}}); place("fast-inserter", 10, -2, N)
    filtered(8, 0, E, sample_of("es-trial-bioflux-control"))
    local res = shared.residue_of(fresh)
    if res then filtered(10, 2, N, "bioflux", res) else filtered(10, 2, N, "bioflux") end
    sink(10, 3)
    hopper_at(12, 0, fresh)
    dose(east, {[fresh] = 5})
    K.gleba = {station = st, bstation = bst, fresh = fresh, fv = fv}
    label(0, -7, "J-K. Gleba. West: gears dosed with yumako mash, which ripens in its hopper: results by ripeness band. "
      .. "East: bioflux dosed with " .. fresh .. " (the best at keeping it fresh): the Freshness column.")
  end

  -- M. Fulgora: a recycler on scrap; scrap samples sorted into a station, the rest into a sink.
  local fs = want("fulgora") and planet_surface("fulgora")
  if fs then
    s = fs
    storage.kit_start = {surface = fs.name, position = {4, 2}}
    power_here()
    local r = place("recycler", 0, 0, N)
    supply(-0.5, 3.5, {{"scrap", 200}}); place("fast-inserter", -0.5, 2.5, S)
    local out = place("steel-chest", -0.5, -2.5)
    local st = place("es-analysis-station", -0.5, -5.5)
    -- A head start (scrap samples are rare: a few minutes of one recycler may yield none), as area I gets
    -- uncommon plates; the recycler's own samples follow.
    st.insert{name = shared.scrap.item, count = 5}
    filtered(-0.5, -3.5, S, shared.scrap.item)
    local rest = place("fast-inserter", -1.5, -2.5, E)
    rest.use_filters = true
    rest.inserter_filter_mode = "blacklist"
    rest.set_filter(1, {name = shared.scrap.item, quality = "normal"})
    sink(-2.5, -2.5)
    supply(2.5, -5.5, {{"electromagnetic-science-pack", 50}, {"automation-science-pack", 50}})
    place("fast-inserter", 1.5, -5.5, E)
    for _, e in pairs(s.find_entities_filtered{area = {{-40, -40}, {40, 40}}}) do e.destructible = false end
    K.fulgora = {station = st, recycler = r}
    label(0, -10, "M. Fulgora: scrap recycling now and then yields a scrap sample, analysed here with any pack. "
      .. "Better packs draw rarer results; past a cap, samples come back as duds.")
  end

  -- N. A space platform: a space science trial (it can only run in space) into its own station.
  local force = game.forces.player
  local pf = want("platform") and force.create_space_platform{name = "Playtest platform", planet = "nauvis", starter_pack = "space-platform-starter-pack"}
  if pf then
    pf.apply_starter_pack()
    storage.kit_start = {platform = pf.index}
    s = pf.surface
    local tiles = {}
    for x = -30, 10 do for y = -12, 12 do table.insert(tiles, {name = "space-platform-foundation", position = {x, y}}) end end
    s.set_tiles(tiles)
    local eei = place("electric-energy-interface", -28, -10); eei.power_production = 1e8; eei.electric_buffer_size = 1e8
    place("substation", -22, -4); place("substation", -10, -4)
    local st, b = station_bench(-22, 0, "es-trial-space-science-control", {{"iron-plate"}, {"carbon"}, {"ice"}},
      "space-science-pack", {"space-science-pack"})
    K.platform = {station = st, bench = b}
    label(-20, -8, "N. Space platform: a space science trial, which only runs in space, into its own station.")
  end
  s = game.surfaces.nauvis
end

-- (Validation of the findings save, not part of a build: after ten game-minutes the line has finished it.)
script.on_nth_tick(36001, function()
  if not storage.kit_findings then return end
  local st = es("dossier_state", "player")
  local g, m = st.planets.nauvis.targets.gear, storage.kit_findings.machine
  local d = es("dose_state", m.unit_number)
  local ex = {}
  for r, b in pairs(st.exceptional) do table.insert(ex, r .. " " .. b.state .. " " .. tostring(b.made) .. "/" .. tostring(b.volume)) end
  helpers.write_file("es-kit-findings-end.txt", string.format("finished %s; Nauvis %d of %d; major %d of %d; gear %s %s/%s; "
    .. "machine made %d, status %s; made coal:3 %s; %s\n",
    tostring(st.finished), st.planets.nauvis.done, st.planets.nauvis.quota, st.exc_done, st.exc_needed, g.state,
    tostring(g.made), tostring(g.volume), m.products_finished, serpent.line(d.status),
    tostring(es("dossier_made", "player", "gear", storage.kit_findings.key)), table.concat(ex, ", ")))
end)

-- Where a player joining the save starts: on the planet or platform the save is about.
script.on_event(defines.events.on_player_created, function(event)
  local player = game.get_player(event.player_index)
  local start = storage.kit_start
  if not (player and start) then return end
  if start.platform then
    for _, p in pairs(player.force.platforms) do if p.index == start.platform then player.enter_space_platform(p) end end
  elseif game.surfaces[start.surface] then
    player.teleport(start.position, start.surface)
  end
end)

-- Proof that every area works (scripts/make_playtest.sh runs two game-minutes and reads this).
script.on_nth_tick(7000, function(event)
  if event.tick == 0 then return end
  s = game.surfaces.nauvis  -- set in on_init only, which does not run on load
  local out = {}
  for _, st in pairs(s.find_entities_filtered{name = "es-analysis-station"}) do
    local d = es("station", st.unit_number, "gear")
    table.insert(out, string.format("station at %d,%d: %d samples analysed", st.position.x, st.position.y, d.analysed))
  end
  for _, st in pairs(s.find_entities_filtered{name = "es-analysis-station"}) do
    local inv = st.get_inventory(defines.inventory.chest)
    local f1, f30 = inv.get_filter(1), inv.get_filter(#inv)
    table.insert(out, string.format("  station %d: contents %s; filter 1 %s, filter %d %s; status %s", st.position.x,
      serpent.line(inv.get_contents()), f1 and f1.name or "-", #inv, f30 and f30.name or "-", serpent.line(st.custom_status)))
  end
  for _, a in pairs(s.find_entities_filtered{name = "assembling-machine-2"}) do
    table.insert(out, a.get_recipe().name .. ": " .. a.products_finished .. " crafts")
  end
  for _, a in pairs(s.find_entities_filtered{name = "assembling-machine-2"}) do
    local d = es("dose_state", a.unit_number)
    if d and d.mix then table.insert(out, string.format("  dosed %s at %.1f: %s", a.get_recipe().name, a.position.x,
      serpent.line(d.status))) end
  end
  local status_name = {}
  for k, v in pairs(defines.entity_status) do status_name[v] = k end
  for _, e in pairs(s.find_entities_filtered{type = {"inserter", "transport-belt", "assembling-machine", "container"},
      area = {{-70, -40}, {60, 30}}}) do
    if e.type ~= "container" or e.name ~= "iron-chest" then
      table.insert(out, string.format("  %-22s %6.1f %6.1f dir %-2d status %s%s", e.name, e.position.x, e.position.y,
        e.direction or -1, tostring(status_name[e.status] or e.status),
        e.type == "inserter" and (" drop " .. string.format("%.1f,%.1f", e.drop_position.x, e.drop_position.y)
          .. " pick " .. string.format("%.1f,%.1f", e.pickup_position.x, e.pickup_position.y)) or ""))
    end
  end

  -- Every area must have produced something through real logistics (inserters, belts, pipes).
  local failed = {}
  local function need(ok, what) if not ok then table.insert(failed, what) end end
  for _, st in pairs(s.find_entities_filtered{name = "es-analysis-station"}) do
    need(es("station", st.unit_number, "gear").analysed > 0, "station at " .. st.position.x)
  end
  for _, a in pairs(s.find_entities_filtered{name = "assembling-machine-2"}) do
    need(a.products_finished > 0, a.get_recipe().name)
    local d = es("dose_state", a.unit_number)
    if d and d.mix then need(d.status and d.status[1] == "es.dose-ok", "dosed " .. a.get_recipe().name .. " at " .. a.position.x) end
  end
  -- Nothing overlaps a fluid hopper (0.71: create_entity does not check, and a pipe built into one left it
  -- unconnected; seen in area L).
  for _, fh in pairs(s.find_entities_filtered{name = "es-fluid-hopper"}) do
    local b = fh.bounding_box
    for _, o in pairs(s.find_entities_filtered{area = {{b.left_top.x + 0.05, b.left_top.y + 0.05},
        {b.right_bottom.x - 0.05, b.right_bottom.y - 0.05}}}) do
      if o.unit_number ~= fh.unit_number and o.prototype.collision_mask and next(o.prototype.collision_mask.layers or {})
          and o.type ~= "character" then
        need(false, string.format("%s overlaps the fluid hopper at %.1f,%.1f", o.name, fh.position.x, fh.position.y))
      end
    end
  end
  for _, b in pairs(s.find_entities_filtered{name = "es-test-bench"}) do
    local d = es("dose_state", b.unit_number)
    if d and d.mix then
      need(d.status and d.status[1] == "es.dose-ok", "dosed bench at " .. b.position.x)
      table.insert(out, string.format("  bench %.1f,%.1f %s: products %d, dose %s, status %s", b.position.x, b.position.y,
        b.get_recipe() and b.get_recipe().name or "-", b.products_finished, serpent.line(d.mix), serpent.line(d.status)))
    end
  end
  -- The sweep must have produced several lubricant doses at station B.
  local doses = 0
  for _, st in pairs(s.find_entities_filtered{name = "es-analysis-station"}) do
    for key, sm in pairs(es("station", st.unit_number, "gear").summaries) do
      if key:find("^lubricant:") and sm.n > 0 then doses = doses + 1 end
    end
  end
  table.insert(out, "lubricant doses measured: " .. doses)
  local kp = storage.kit_pair
  table.insert(out, string.format("premix rig: %s + %s on red science, true interaction %+.1f%%", kp.a, kp.b, kp.inter * 100))
  local kl = storage.kit_liquid
  if kl then table.insert(out, string.format("liquid premix on area G: %s (best gear gain %+.1f%%)", kl.name, kl.gain * 100)) end
  local kr = storage.kit_residue
  table.insert(out, string.format("residue on the west bench: %s x%d on %s (true gain %+.1f%%); refining unlocked: %s",
    kr.name, kr.dose, kr.target, kr.gain * 100, tostring(game.forces.player.recipes["es-refine-" .. kr.name:sub(10)].enabled)))
  for _, c in pairs(s.find_entities_filtered{type = {"decider-combinator", "arithmetic-combinator"}}) do
    local o = c.get_signal({type = "virtual", name = "signal-T"}, defines.wire_connector_id.combinator_output_red)
    local d = c.get_signal({type = "virtual", name = "signal-D"}, defines.wire_connector_id.combinator_output_red)
    local l = c.get_signal({type = "fluid", name = "lubricant"}, defines.wire_connector_id.combinator_output_red)
    local i = c.get_signal({type = "virtual", name = "signal-T"}, defines.wire_connector_id.combinator_input_red)
    table.insert(out, string.format("  %s at %.1f: in T %d; out T %d D %d lubricant %d; status %s", c.name, c.position.x,
      i, o, d, l, tostring(c.status)))
  end
  if want("lab") then need(doses >= 3, "lubricant dose sweep") end
  local kc = storage.kit_cascade
  if kc then
    local up, rare, made = 0, 0, kc.furnace.products_finished
    for _, chest in ipairs({kc.plates, kc.gears}) do
      for _, it in pairs(chest.get_inventory(defines.inventory.chest).get_contents()) do
        if it.name == "iron-plate" and it.quality == "uncommon" then up = up + it.count end
        if it.name == "iron-gear-wheel" and it.quality == "rare" then rare = rare + it.count end
      end
    end
    local st = es("dose_state", kc.furnace.unit_number)
    table.insert(out, string.format("quality from the furnace (area I): %d plates smelted (hidden upgrade chance %.1f%%), "
      .. "%d uncommon plates waiting to be sorted, %d rare gears; furnace dose %s", made, 100 * kc.chance, up, rare, serpent.line(st.status)))
    -- Deterministic: the furnace smelts and is dosed (how many come out uncommon depends on the map).
    need(made > 0 and st.status and st.status[1] == "es.dose-ok", "furnace quality line")
  end
  local kq = storage.kit_quality
  if kq then
    local up = 0
    for _, item in pairs(kq.chest.get_inventory(defines.inventory.chest).get_contents()) do
      if item.quality ~= "normal" then up = up + item.count end
    end
    table.insert(out, string.format("quality agent on area H: %s x%d (true chance %.1f%%), %d upgraded gears so far",
      kq.agent, kq.dose, kq.chance * 100, up))
    need(up > 0, "quality agent line")
  end
  -- Additive power (dosed machines flashed a no-power icon): every hidden consumer
  -- that draws must be receiving power, or the kit is not saved.
  local starving = 0
  for _, c in pairs(s.find_entities_filtered{name = {"es-power-draw", "es-power-give"}}) do
    table.insert(out, string.format("power %s at %.1f,%.1f: use %.0f give %.0f J/tick, energy %.0f, buffer %.0f, status %s",
      c.name, c.position.x, c.position.y, c.power_usage, c.power_production, c.energy, c.electric_buffer_size,
      tostring(c.status)))
    if c.power_usage > 0 and c.energy <= 0 then starving = starving + 1 end
  end
  need(starving == 0, "hidden power consumers receive power (" .. starving .. " starving)")
  -- The findings save: one finding short of the end, its line running.
  local kf = storage.kit_findings
  if kf then
    local st = es("dossier_state", "player")
    local g = st.planets.nauvis.targets.gear
    local d = es("dose_state", kf.machine.unit_number)
    table.insert(out, string.format("findings: Nauvis %d of %d, major %d of %d, gears %s (%s of %s made), finished %s",
      st.planets.nauvis.done, st.planets.nauvis.quota, st.exc_done, st.exc_needed, g.state, tostring(g.made),
      tostring(g.volume), tostring(st.finished)))
    table.insert(out, string.format("  findings gear line: %s, true gain %+.1f%%, extra products so far %s", kf.key, 100 * kf.gain,
      tostring(es("progress_now_extra", "player"))))
    need(kf.gain > 0, "the findings gear line's dose truly pays")
    need(not st.finished and st.planets.nauvis.done == st.planets.nauvis.quota - 1 and g.state == "proven"
      and d.status and d.status[1] == "es.dose-ok", "findings one short of the end, its line running")
  end
  -- J-O (Space Age): each station analysed, and showing what its area is for.
  local K = storage.kit_sa
  if K then
    local function keys(st, target)
      local out_k = {}
      if st and st.valid then for k in pairs(es("station", st.unit_number, target).summaries) do table.insert(out_k, k) end end
      return out_k
    end
    local function analysed(st) return st and st.valid and es("station", st.unit_number, "gear").analysed or 0 end
    local function any(list, pattern) for _, k in ipairs(list) do if k:find(pattern) then return true end end return false end
    if K.legendary then
      local used = K.legendary.given - K.legendary.chest.get_inventory(defines.inventory.chest).get_item_count_filtered{name = "automation-science-pack", quality = "legendary"}
        - K.legendary.station.get_inventory(defines.inventory.chest).get_item_count_filtered{name = "automation-science-pack", quality = "legendary"}
      local n = analysed(K.legendary.station)
      table.insert(out, string.format("legendary packs (O): %d samples analysed, %d packs taken", n, used))
      need(n > 0 and used <= math.ceil(n / 12) + 1, "legendary packs go six times as far")
    end
    local KT = storage.kit_temps
    if KT then
      local P = KT.premix:gsub("%-", "%%-")
      for temp, st in pairs(KT.stations) do
        local ks = keys(st, "gear")
        local band = shared.temp_band(temp)
        local pattern = band == shared.temp_band(shared.premix.cold) and ("^" .. P .. ":") or ("^" .. P .. "@" .. band .. ":")
        table.insert(out, string.format("premix at %d (G): %s", temp, table.concat(ks, ", ")))
        need(any(ks, pattern), "premix results in the band of " .. temp .. " degrees")
      end
    end
    if K.chilled then
      local ks = keys(K.chilled.station, "gear")
      table.insert(out, "chilled lubricant (L): " .. table.concat(ks, ", "))
      need(any(ks, "^lubricant@%-"), "chilled lubricant in a cold band")
    end
    if K.chiller then
      local ks = keys(K.chiller.station, "gear")
      table.insert(out, "fluid chiller (L): " .. table.concat(ks, ", "))
      local ch = K.chiller.entity
      if ch and ch.valid then
        local function fb(i) local f = ch.fluidbox[i]; return f and string.format("%s %.0f @ %.0f", f.name, f.amount, f.temperature) or "empty" end
        local h = s.find_entities_filtered{name = "es-fluid-hopper", position = ch.position, radius = 5}[1]
        local hf = h and h.fluidbox[1]
        table.insert(out, string.format("  chiller: charges %d, burning %.0f kJ, in %s, out %s, status %s; hopper %s",
          ch.get_fuel_inventory().get_item_count("es-cold-charge"), (ch.burner.remaining_burning_fuel or 0) / 1000,
          fb(1), fb(2), tostring(ch.status), hf and string.format("%.0f @ %.0f", hf.amount, hf.temperature) or "empty"))
        for _, e in pairs(s.find_entities_filtered{position = ch.position, radius = 7}) do
          if e.fluidbox and #e.fluidbox > 0 then
            local parts = {}
            for i = 1, #e.fluidbox do local f = e.fluidbox[i]; parts[i] = f and string.format("%s %.0f@%.0f", f.name, f.amount, f.temperature) or "-" end
            table.insert(out, string.format("    %s %.1f,%.1f: %s", e.name, e.position.x, e.position.y, table.concat(parts, " | ")))
          end
        end
      end
      need(any(ks, "^" .. K.chiller.premix:gsub("%-", "%%-") .. "@%-"), "chilled premix in a cold band")
    end
    if K.vulcanus then
      local ks = keys(K.vulcanus.station, "gear")
      table.insert(out, "Vulcanus pressure heater (L): " .. table.concat(ks, ", "))
      need(any(ks, "@%d"), "Vulcanus hot band")
    end
    if K.gleba then
      local kg, kb = keys(K.gleba.station, "gear"), keys(K.gleba.bstation, "bioflux")
      table.insert(out, string.format("Gleba (J-K): gear %s; bioflux %s (freshness additive %s, %+.1f%%)", table.concat(kg, ", "),
        table.concat(kb, ", "), K.gleba.fresh, 100 * K.gleba.fv))
      local gst = es("station", K.gleba.station.unit_number, "gear")
      table.insert(out, string.format("  Gleba station: analysed %d, unreadable %d, failed %d; contents %s", gst.analysed,
        gst.unreadable, gst.failed, serpent.line(K.gleba.station.get_inventory(defines.inventory.chest).get_contents())))
      need(any(kg, "^yumako%-mash"), "Gleba ripeness bench")
      need(#kb > 0, "Gleba bioflux bench")
    end
    if K.fulgora then
      local st = K.fulgora.station
      local n = st.valid and es("station", st.unit_number, "gear").scrap_analysed or 0
      table.insert(out, "Fulgora scrap samples analysed (M): " .. tostring(n))
      local recycled = K.fulgora.recycler.valid and K.fulgora.recycler.products_finished or 0
      table.insert(out, "  Fulgora recycler crafts: " .. recycled)
      need((n or 0) > 0 and recycled > 0, "Fulgora scrap samples")
      need(es("achieved", "player")["es-cold-case"], "Cold case (a scrap sample read)")
    end
    -- Every bench off Nauvis: its status and dose, for a failed build.
    for _, surf in pairs(game.surfaces) do
      if surf.name ~= "nauvis" then
        for _, b in pairs(surf.find_entities_filtered{name = "es-test-bench"}) do
          local d = es("dose_state", b.unit_number)
          table.insert(out, string.format("  %s bench %.1f,%.1f %s: status %s, finished %d, dose %s", surf.name, b.position.x,
            b.position.y, b.get_recipe() and b.get_recipe().name or "-", tostring(status_name[b.status] or b.status),
            b.products_finished, serpent.line(d and d.status)))
        end
      end
    end
    if K.platform then
      -- A space science trial takes about as long as this run: proof is a trial under way or done.
      local n, b = analysed(K.platform.station), K.platform.bench
      table.insert(out, string.format("platform space science (N): %d samples analysed, trial %.0f%% done", n,
        100 * b.crafting_progress))
      need(n > 0 or b.crafting_progress > 0 or b.products_finished > 0, "platform space science")
    end
  end
  if storage.kit_complete then
    -- (Timed twice, as an opened and a reopened screen; scripts/make_playtest.sh reads the log: a guard.)
    es("profile_screen", "player", "nauvis"); es("profile_screen", "player", "nauvis")
    local kc = storage.kit_complete
    table.insert(out, string.format("complete: %d samples on %d targets", kc.samples, kc.targets))
    need(kc.targets >= 20 and kc.samples > 50000, "the complete history")
  end
  do  -- (0.72) The achievements this save's force earned, for the record.
    local names = {}
    for name in pairs(es("achieved", "player")) do table.insert(names, name) end
    table.sort(names)
    table.insert(out, "achievements: " .. (#names > 0 and table.concat(names, ", ") or "none"))
  end
  table.insert(out, #failed == 0 and "KIT OK" or ("KIT FAIL: " .. table.concat(failed, ", ")))
  helpers.write_file("es-kit-status.txt", table.concat(out, "\n") .. "\n")
end)
