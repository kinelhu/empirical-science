local shared = require("__empirical-science__.shared")
-- The showcase factory: a small red, green and oil factory built from raw ore only (no
-- infinity chests), in a world that has already run experiments (a simulated history through the mod's
-- own trial and analysis code). scripts/make_playtest.sh showcase builds it, runs ten game-minutes and
-- saves it only if every part produced.
local es = function(fn, ...) return remote.call("empirical-science", fn, ...) end
local s
local N, E, S, W = defines.direction.north, defines.direction.east, defines.direction.south, defines.direction.west

local function place(name, x, y, dir, extra)
  -- create_entity does not check collisions: a pipe once ran through the refinery unseen. Check first.
  if not s.can_place_entity{name = name, position = {x, y}, direction = dir, force = "player"} then
    local here = {}
    for _, e in pairs(s.find_entities_filtered{position = {x, y}, radius = 1.5}) do table.insert(here, e.name) end
    error("showcase: " .. name .. " at " .. x .. "," .. y .. " collides (" .. table.concat(here, ", ") .. ")")
  end
  local spec = {name = name, position = {x, y}, force = "player", raise_built = true, direction = dir}
  for k, v in pairs(extra or {}) do spec[k] = v end
  local e = s.create_entity(spec)
  if not e then error("showcase: could not place " .. name .. " at " .. x .. "," .. y) end
  return e
end
-- A straight belt from (x1, y) to (x2, y) or (x, y1) to (x, y2), moving toward the second end.
local function belt(x1, y1, x2, y2)
  local dir = x2 > x1 and E or x2 < x1 and W or y2 > y1 and S or N
  local dx, dy = x2 > x1 and 1 or x2 < x1 and -1 or 0, y2 > y1 and 1 or y2 < y1 and -1 or 0
  local x, y = x1, y1
  while true do
    place("transport-belt", x, y, dir)
    if x == x2 and y == y2 then break end
    x, y = x + dx, y + dy
  end
end
-- Pipes along an L: first along x, then along y (both end tiles included).
local function pipe(x1, y1, x2, y2)
  -- A run that starts on another's last tile shares it (the corner of an L made of two runs).
  local function one(x, y) if not s.find_entity("pipe", {x, y}) then place("pipe", x, y) end end
  local x, y = x1, y1
  one(x, y)
  while x ~= x2 do x = x + (x2 > x and 1 or -1); one(x, y) end
  while y ~= y2 do y = y + (y2 > y and 1 or -1); one(x, y) end
end
-- An ore field under a drill's mining area.
local function ore(name, x, y, half)
  for dx = -half, half do
    for dy = -half, half do
      s.create_entity{name = name, position = {x + dx, y + dy}, amount = 1000000}
    end
  end
end
-- Inserter conventions: the direction is where it picks from (as in the playtest kit).
local function inserter(x, y, from) return place("inserter", x, y, from) end
local function label(x, y, text)
  rendering.draw_text{text = text, surface = s, target = {x, y}, color = {1, 1, 1}, scale = 1.4, alignment = "center"}
end

-- What each part must have made for the save to be kept, and where to read it.
local parts = {}
local function part(name, entity) table.insert(parts, {name = name, entity = entity}) end

local function power()
  -- A lake, an offshore pump, three boilers on mined coal and six steam engines.
  local tiles = {}
  for x = -90, -81 do for y = -40, -31 do table.insert(tiles, {name = "water", position = {x, y}}) end end
  s.set_tiles(tiles)
  local pump = place("offshore-pump", -85.5, -29.5, N)
  local out = pump.fluidbox.get_pipe_connections(1)[1].target_position
  local boilers = {}
  -- Four boilers on four coal drills (2 coal/s, 8 MW of fuel for 7.2 MW of boilers): with two drills for
  -- three boilers, power was capped by coal mining, and a brownout slowed the coal drills too.
  for i, bx in ipairs({-62.5, -59.5, -56.5, -53.5}) do
    boilers[i] = place("boiler", bx, -26, N)
    -- The first coal by hand, as a player starts a steam plant: electric drills need power to mine more.
    boilers[i].insert{name = "coal", count = 20}
    place("steam-engine", bx, -29.5, N)
    place("steam-engine", bx, -34.5, N)
    inserter(bx, -24.5, S)
    part("boiler " .. i, boilers[i])
  end
  local inlet
  for _, c in ipairs(boilers[1].fluidbox.get_pipe_connections(1)) do
    if c.target_position.x < -63 then inlet = c.target_position end
  end
  pipe(out.x, out.y, inlet.x, out.y)
  pipe(inlet.x, out.y, inlet.x, inlet.y)
  -- Coal for the boilers: two drills facing north onto a belt running east under the inserters.
  for _, dx in ipairs({-64.5, -61.5, -58.5, -55.5}) do
    ore("coal", dx, -21.5, 2)
    place("electric-mining-drill", dx, -21.5, N)
  end
  belt(-65.5, -23.5, -52.5, -23.5)
  label(-60, -38, "Power: an offshore pump, boilers on mined coal, steam engines")
end

-- A smelting line: drills north of an ore belt (ore on its north lane), coal side-loaded onto its south
-- lane from a belt fed by its own drill, stone furnaces south of it, plates onto an output belt.
-- Ore never outruns the furnaces (drills 0.5/s, furnaces 0.3125/s), so the ore lane never jams the coal.
local function smelting(ore_name, x0, y0, drills, furnaces)
  local yb = y0 + 0.5  -- the ore belt
  for i = 0, drills - 1 do
    local dx = x0 + 1.5 + 3 * i  -- the first drops where the first furnace's inserter picks
    ore(ore_name, dx, y0 - 1.5, 2)
    place("electric-mining-drill", dx, y0 - 1.5, S)
  end
  local x_end = x0 + 2 * furnaces + 1
  -- It starts a tile early, so the coal joining at x0 + 0.5 side-loads (onto the near lane) rather than
  -- turning the belt's first tile.
  belt(x0 - 0.5, yb, x_end + 0.5, yb)
  -- Coal: a drill south-west of the line; its belt side-loads the ore belt from the south. A drill drops
  -- at a point just inside the belt tile, so the drills above put ore on the north lane: coal from the
  -- south takes the other lane, and a lane full of one never blocks the other (from the north they
  -- shared a lane and jammed, 2026-10-02).
  ore("coal", x0 - 3.5, y0 + 3.5, 2)
  place("electric-mining-drill", x0 - 3.5, y0 + 3.5, E)
  belt(x0 - 1.5, y0 + 3.5, x0 - 0.5, y0 + 3.5)
  belt(x0 + 0.5, y0 + 3.5, x0 + 0.5, y0 + 1.5)  -- its first tile faces north: the corner
  local out_y = y0 + 5.5
  local list = {}
  for i = 0, furnaces - 1 do
    local fx = x0 + 2 + 2 * i
    inserter(fx - 0.5, y0 + 1.5, N)
    local f = place("stone-furnace", fx, y0 + 3)
    inserter(fx - 0.5, y0 + 4.5, N)
    table.insert(list, f)
    part(ore_name .. " furnace " .. (i + 1), f)
  end
  belt(x0 + 1.5, out_y, x_end + 0.5, out_y)
  return list, out_y, x_end
end

-- The history (simulated through the mod's trial and analysis code): a screening of red science, then a
-- confirmation of the best minable additive's best cell. Returns the dose the factory adopts.
local function lower_net(sums, target, name, d)
  local c, x = sums.control, sums[name .. ":" .. d]
  if not (c and x and x.n >= 2 and c.n >= 2) then return nil end
  local tau = es("tau", target, {[name] = d})  -- per mille, as the means
  return x.mean - c.mean - tau - 1.96 * math.sqrt(x.var / x.n + c.var / c.n)
end
local function history()
  local plan = {{target = "red", n = 24}}
  for _, name in ipairs({"coal", "stone", "copper-cable"}) do
    for _, d in ipairs({2, 5, 8}) do table.insert(plan, {target = "red", mix = {[name] = d}, n = 8}) end
  end
  es("simulate_history", "player", "nauvis", plan)
  -- The best minable cell by the lower bound of its net gain (the rule the port's Best composition page uses).
  local sums = es("pool_summaries", "player", "nauvis", "red")
  local best
  for _, name in ipairs({"coal", "stone", "copper-cable"}) do
    for _, d in ipairs({2, 5, 8}) do
      local lo = lower_net(sums, "red", name, d)
      if lo and (not best or lo > best.lo) then best = {name = name, dose = d, lo = lo} end
    end
  end
  -- Confirmation: the best cell, its neighbours and the control, sixteen more each.
  local confirm = {{target = "red", n = 16}, {target = "red", mix = {[best.name] = best.dose}, n = 16}}
  for _, d in ipairs({best.dose - 1, best.dose + 1}) do
    if d >= 1 and d <= shared.max_dose then table.insert(confirm, {target = "red", mix = {[best.name] = d}, n = 16}) end
  end
  es("simulate_history", "player", "nauvis", confirm)
  sums = es("pool_summaries", "player", "nauvis", "red")
  local chosen = best
  for _, step in ipairs(confirm) do
    if step.mix then
      local d = step.mix[best.name]
      local lo = lower_net(sums, "red", best.name, d)
      if lo and lo > chosen.lo then chosen = {name = best.name, dose = d, lo = lo} end
    end
  end
  storage.history = {additive = chosen.name, dose = chosen.dose, lo = chosen.lo}
  return chosen
end

-- Mixtures in the history: on a target, each single's best screened dose, then the 2x2 (each alone,
-- together, control) in batches until the station's synergy test unlocks the pair's premix, or a cap.
local function best_dose(target, name)
  local sums = es("pool_summaries", "player", "nauvis", target)
  local bd, bm
  for _, d in ipairs({2, 5, 8}) do
    local x = sums[name .. ":" .. d]
    if x and x.n > 0 and (not bm or x.mean > bm) then bd, bm = d, x.mean end
  end
  return bd or 5
end
local function premix_unlocked(a, b)
  for _, v in ipairs({false, true}) do
    local r = game.forces.player.recipes[shared.premix_recipe(a, b, v)]
    if r and r.enabled then return shared.premix_name(a, b, v) end
  end
end
local function mixture_history(target, a, b)
  local plan = {{target = target, n = 6}}
  for _, name in ipairs({a, b}) do
    for _, d in ipairs({2, 5, 8}) do table.insert(plan, {target = target, mix = {[name] = d}, n = 6}) end
  end
  es("simulate_history", "player", "nauvis", plan)
  local da, db = best_dose(target, a), best_dose(target, b)
  for _ = 1, 6 do
    if premix_unlocked(a, b) then break end
    es("simulate_history", "player", "nauvis", {{target = target, n = 10}, {target = target, mix = {[a] = da}, n = 10},
      {target = target, mix = {[b] = db}, n = 10}, {target = target, mix = {[a] = da, [b] = db}, n = 10}})
  end
  return premix_unlocked(a, b)
end
-- The premix the factory makes (coal and stone, both mined): its doses screened once unlocked, the best
-- adopted by the lower bound of its net gain; without a synergy, the better single.
local function premix_history()
  local premix = mixture_history("gear", "coal", "stone")
  mixture_history("red", "coal", "copper-cable")   -- more of the world's chemistry, discovered or not
  mixture_history("red", "stone", "copper-cable")
  local sums
  if premix then
    local plan = {}
    for _, d in ipairs({2, 5, 8}) do table.insert(plan, {target = "gear", mix = {[premix] = d}, n = 10}) end
    es("simulate_history", "player", "nauvis", plan)
  end
  sums = es("pool_summaries", "player", "nauvis", "gear")
  local function best_of(names)
    local best
    for _, name in ipairs(names) do
      for _, d in ipairs({2, 5, 8}) do
        local lo = lower_net(sums, "gear", name, d)
        if lo and (not best or lo > best.lo) then best = {name = name, dose = d, lo = lo} end
      end
    end
    return best
  end
  -- The premix when it is proven to pay (its lower bound above zero), else the better single.
  local single = best_of({"coal", "stone"})
  local mixed = premix and best_of({premix})
  local adopted = mixed and mixed.lo > 0 and mixed or single
  storage.premix_history = {premix = premix, adopted = adopted, single = single, mixed = mixed}
  return premix, adopted, single, mixed
end

-- The assembly row (y 7 to 10) between the iron belt (y 5.5: iron on its south lane, the additive on
-- its north lane), the gear belt (y 4.5, by long inserters), the science belt (y 11.5) and the copper
-- belt (y 12.5, by long inserters). Assemblers every four tiles; chained ones hand over directly.
local ROW = 8.5
local function asm(recipe, x)
  local a = place("assembling-machine-2", x, ROW)
  a.set_recipe(recipe)
  part(recipe .. " at " .. x, a)
  return a
end
local function iron_in(x) inserter(x, 6.5, N) end                        -- iron (and the additive lane)
local function gear_in(x) place("long-handed-inserter", x, 6.5, N) end   -- gears from y 4.5
local function gear_out(x) place("long-handed-inserter", x, 6.5, S) end  -- onto the gear belt
local function copper_in(x) place("long-handed-inserter", x, 10.5, S) end
local function science_out(x) inserter(x, 10.5, N) end                   -- onto the science belt
local function production(chosen)
  -- Belts: iron on from smelting; gears; copper up from its smelting line; science east to the lab.
  belt(storage.ends.iron + 1.5, 5.5, 36.5, 5.5)
  belt(-31.5, 4.5, 36.5, 4.5)
  belt(storage.ends.copper + 1.5, 25.5, -34.5, 25.5)
  belt(-33.5, 25.5, -33.5, 13.5)
  belt(-33.5, 12.5, 36.5, 12.5)
  belt(-23.5, 11.5, 37.5, 11.5)
  -- The additive onto the iron belt's north lane: an ore by a drill side-loading from the north, copper
  -- cable by an assembler whose inserter drops onto that lane (an inserter fills the far lane).
  if chosen.name == "copper-cable" then
    asm("copper-cable", -32.5); copper_in(-33.5)
    inserter(-32.5, 6.5, S)  -- picks the assembler, drops onto the iron belt's far (north) lane
  else
    -- Two drills: three hoppers draw on this lane, the last one (bench 3) starved with one.
    for _, x in ipairs({-35.5, -32.5}) do
      ore(chosen.name, x, 1.5, 2)
      place("electric-mining-drill", x, 1.5, S)
      belt(x, 3.5, x, 4.5)
    end
  end
  label(-35.5, -1, "The additive found by experiment: " .. chosen.name .. (chosen.lo > 0 and "" or " (best estimate, not yet proven)"))
  -- Gears.
  -- One gear assembler here: the dosed one in the premix cell is the second (a third starved iron).
  asm("iron-gear-wheel", -28.5); iron_in(-29.5); gear_out(-27.5)
  -- Red science, dosed by the experiments' finding from one hopper between the two machines.
  local reds = {}
  for _, x in ipairs({-20.5, -16.5}) do
    local r = asm("automation-science-pack", x)
    gear_in(x); copper_in(x - 1); science_out(x + 1)
    table.insert(reds, r)
  end
  storage.red_hopper = place("es-hopper", -18.5, 7.5)
  -- One slot for the additive, as a player limits a chest: a full hopper upstream starved those after it.
  storage.red_hopper.get_inventory(defines.inventory.chest).set_bar(2)
  -- Filtered: the iron belt carries plates on its other lane.
  local fi = inserter(-18.5, 6.5, N); fi.use_filters = true; fi.set_filter(1, {name = chosen.name, quality = "normal"})
  -- (0.65: its residues leave the red science machines with their packs, onto the science belt; the
  -- overflow chest at the belt's end takes them.)
  for _, r in ipairs(reds) do es("set_dose", r.unit_number, {rows = {{name = chosen.name, dose = chosen.dose}}}) end
  storage.dosed_reds = reds
  -- Green science: cable, circuits, inserters and belts, handed over directly.
  asm("copper-cable", -12.5); copper_in(-13.5)
  inserter(-10.5, ROW, W)
  asm("electronic-circuit", -8.5); iron_in(-9.5)
  inserter(-6.5, ROW, W)
  asm("inserter", -4.5); iron_in(-5.5); gear_in(-3.5)
  inserter(-2.5, ROW, W)
  asm("logistic-science-pack", -0.5); science_out(-0.5)
  inserter(1.5, ROW, E)
  asm("transport-belt", 3.5); iron_in(2.5); gear_in(4.5)
  label(-12, 15, "Production: gears, red science dosed with " .. chosen.name .. " x" .. chosen.dose
    .. " (the experiments' best), green science")
end

-- The lab, east of the row: three benches on red science (a control, the adopted dose, a higher one),
-- the station taking samples and packs off the science belt, two labs researching Analysis productivity
-- with its research data and the packs, and an overflow chest at the belt's end for residues and spare packs.
local function dosing_hopper(x, chosen)
  place("es-hopper", x, 7.5).get_inventory(defines.inventory.chest).set_bar(2)
  local fi = inserter(x, 6.5, N); fi.use_filters = true; fi.set_filter(1, {name = chosen.name, quality = "normal"})
end
local function lab(chosen)
  local benches = {}
  for i, bx in ipairs({8.5, 13.5, 18.5}) do
    local b = place("es-test-bench", bx, ROW)
    b.set_recipe("es-trial-red-control")
    gear_in(bx); copper_in(bx - 1); science_out(bx + 1)
    part("bench " .. i, b)
    benches[i] = b
  end
  dosing_hopper(15.5, chosen)
  dosing_hopper(20.5, chosen)
  storage.bench3 = benches[3]
  es("set_dose", benches[2].unit_number, {rows = {{name = chosen.name, dose = chosen.dose}}})
  es("set_dose", benches[3].unit_number, {rows = {{name = chosen.name, dose = math.min(chosen.dose + 2, shared.max_dose)}}})
  -- The station, under the copper belt: long inserters reach the science belt over it.
  local st = place("es-analysis-station", 26.5, 15.5)
  for _, x in ipairs({25.5, 27.5}) do
    local li = place("long-handed-inserter", x, 13.5, N); li.use_filters = true
    li.set_filter(1, {name = "es-sample-automation-science-pack", quality = "normal"})  -- (0.72: its gear trials' kind)
    li.set_filter(2, {name = "automation-science-pack", quality = "normal"})
  end
  storage.station = st
  -- Two labs: packs from the belt, research data from the station, passed on from lab to lab.
  local l1 = place("lab", 30.5, 15.5)
  place("long-handed-inserter", 30.5, 13.5, N)
  local d = place("inserter", 28.5, 15.5, W); d.use_filters = true
  d.set_filter(1, {name = "es-research-data", quality = "normal"})
  place("lab", 34.5, 15.5)
  inserter(32.5, 15.5, W)
  place("long-handed-inserter", 34.5, 13.5, N)
  storage.labs = {l1}
  label(24, 20, "The lab: benches still experimenting (control, the adopted dose, a higher one), the station, "
    .. "labs researching Analysis productivity with its research data")
end

-- The premix cell, north of the gear belt: drills drop coal and stone straight into the premix assembler;
-- an inserter fills the hopper of a gear assembler dosed with the premix (or, without a synergy, the
-- better single from a drill), which takes iron by a long inserter and puts its gears on the gear belt.
local function premix_cell(premix, adopted, single, mixed)
  local gp = place("assembling-machine-2", -19.5, 1.5)
  gp.set_recipe("iron-gear-wheel")
  part("gears dosed with " .. adopted.name, gp)
  place("long-handed-inserter", -19.5, 3.5, S)   -- iron from y 5.5
  local go = inserter(-18.5, 3.5, N)              -- gears onto the gear belt (gears only: residues go north)
  go.use_filters = true; go.set_filter(1, {name = "iron-gear-wheel", quality = "normal"})
  local h = place("es-hopper", -21.5, 1.5)
  h.get_inventory(defines.inventory.chest).set_bar(2)
  -- Residues leave the machine (0.65), sorted off: a filtered inserter on its north edge into a chest.
  local f = place("inserter", -20.5, -0.5, S); f.use_filters = true
  local residues = {}
  local a = shared.additive(adopted.name)
  for _, m in ipairs(a.premix_of or {adopted.name}) do
    local r = shared.residue_of(m)
    if r then residues[r] = true end
  end
  local i = 1
  for r in pairs(residues) do f.set_filter(i, {name = r, quality = "normal"}); i = i + 1 end
  storage.residue_chest = place("wooden-chest", -20.5, -1.5)
  -- The source, west of the hopper in both cases: the premix assembler (drills drop coal and stone into
  -- it), or the single's drill into a chest.
  inserter(-22.5, 1.5, W)
  if premix and adopted.name == premix then
    local pa = place("assembling-machine-2", -24.5, 1.5)
    pa.set_recipe(premix)
    part("premix " .. premix, pa)
    ore("coal", -24.5, -1.5, 2); place("electric-mining-drill", -24.5, -1.5, S)
    ore("stone", -27.5, 1.5, 2); place("electric-mining-drill", -27.5, 1.5, E)
    label(-23, -4, "Premix of coal and stone: their synergy found by experiment, and it pays; it doses the gears beside it")
  else
    place("wooden-chest", -23.5, 1.5)
    ore(adopted.name, -25.5, 1.5, 2); place("electric-mining-drill", -25.5, 1.5, E)
    label(-23, -4, premix and ("Coal and stone premix discovered, not proven to pay on gears: the gears are dosed with "
      .. adopted.name) or ("No coal and stone synergy found on this map: the gears are dosed with " .. adopted.name))
  end
  es("set_dose", gp.unit_number, {rows = {{name = adopted.name, dose = adopted.dose}}})
  storage.premix_gears = gp
end

-- The residue hint in the history: the red line's residue (it reaches the science belt) screened on the
-- early targets, then the most promising one confirmed in batches until the station's test unlocks its
-- activation, or a cap.
local function catalyst_history(chosen)
  local residue = shared.residue_of(chosen.name)
  local spent_of = shared.additive(residue).spent_of
  local recipe = game.forces.player.recipes[shared.refine_recipe(spent_of)]
  local targets = {"gear", "circuit", "red", "green", "steel", "iron-plate", "copper-plate"}
  local plan = {}
  for _, t in ipairs(targets) do
    table.insert(plan, {target = t, n = 6}); table.insert(plan, {target = t, mix = {[residue] = 5}, n = 6})
  end
  es("simulate_history", "player", "nauvis", plan)
  local best, bestd
  for _, t in ipairs(targets) do
    local sums = es("pool_summaries", "player", "nauvis", t)
    local x, c = sums[residue .. ":5"], sums.control
    if x and c and x.n > 0 and (not bestd or x.mean - c.mean > bestd) then best, bestd = t, x.mean - c.mean end
  end
  for _ = 1, 8 do
    if recipe.enabled then break end
    es("simulate_history", "player", "nauvis", {{target = best, n = 10}, {target = best, mix = {[residue] = 5}, n = 10}})
  end
  storage.catalyst_history = {residue = residue, target = best, unlocked = recipe.enabled, recipe = recipe.name}
  return recipe.enabled and recipe.name or nil, residue
end

-- Oil, north of the gear belt: a pumpjack and a refinery (petroleum gas), a second offshore pump, the
-- sulfur and sulfuric acid plants (iron by a long inserter from the iron belt), and at the science
-- belt's end the activation plant taking its residue and the acid. Different fluids never touch: their
-- pipes run two tiles apart, and petroleum crosses the water branch underground.
local function oil(activation, residue)
  local tiles = {}
  for x = 14, 23 do for y = -24, -15 do table.insert(tiles, {name = "water", position = {x, y}}) end end
  s.set_tiles(tiles)
  local pump = place("offshore-pump", 18.5, -13.5, N)
  local wt = pump.fluidbox.get_pipe_connections(1)[1].target_position
  local s1 = place("chemical-plant", 4.5, 1.5, N); s1.set_recipe("sulfur")
  local a = place("chemical-plant", 8.5, 1.5, N); a.set_recipe("sulfuric-acid")
  part("sulfur", s1); part("sulfuric acid", a)
  inserter(6.5, 1.5, W)                              -- sulfur into the acid plant
  place("long-handed-inserter", 8.5, 3.5, S)         -- iron from y 5.5
  -- Water: the main west then down to the acid plant, a branch at y -2.5 to the sulfur plant.
  pipe(wt.x, wt.y, 7.5, wt.y)
  pipe(7.5, wt.y + 1, 7.5, -0.5)
  pipe(6.5, -2.5, 3.5, -2.5)
  pipe(3.5, -1.5, 3.5, -0.5)
  -- Crude oil and the refinery (facing south: its outputs below it).
  s.create_entity{name = "crude-oil", position = {-3.5, -10.5}, amount = 3000000}
  local jack = place("pumpjack", -3.5, -10.5, N)
  local ref = place("oil-refinery", 3.5, -10.5, S); ref.set_recipe("basic-oil-processing")
  part("refinery", ref)
  -- A machine with a recipe lists only the fluidboxes it uses: find them by role (and by fluid).
  local function box(entity, kind, fluid, pick)
    -- By the connection's flow direction (a box's prototype did not always report its production type).
    for i = 1, #entity.fluidbox do
      local locked = entity.fluidbox.get_locked_fluid and entity.fluidbox.get_locked_fluid(i)
      local best
      for _, c in ipairs(entity.fluidbox.get_pipe_connections(i)) do
        if c.flow_direction == kind and (not fluid or locked == fluid)
            and (not best or (pick == "east" and c.target_position.x > best.x)) then best = c.target_position end
      end
      if best then return best end
    end
    local have = {}
    for i = 1, #entity.fluidbox do
      table.insert(have, tostring(entity.fluidbox.get_prototype(i).production_type) .. "/"
        .. tostring(entity.fluidbox.get_locked_fluid and entity.fluidbox.get_locked_fluid(i)))
    end
    local r = entity.get_recipe()
    error(entity.name .. ": no " .. kind .. " box" .. (fluid and (" for " .. fluid) or "") .. "; recipe "
      .. (r and r.name or "none") .. "; boxes " .. table.concat(have, ", "))
  end
  local function target(entity, index) return entity.fluidbox.get_pipe_connections(index)[1].target_position end
  local jt, crude_in, petro_out = target(jack, 1), box(ref, "input"), box(ref, "output")
  -- Around the refinery's north side (a straight line ran through it).
  pipe(jt.x, jt.y, jt.x, crude_in.y - 1)
  pipe(jt.x + 1, crude_in.y - 1, crude_in.x, crude_in.y - 1)
  place("pipe", crude_in.x, crude_in.y)
  -- Petroleum to the sulfur plant's second input, under the water branch.
  pipe(petro_out.x, petro_out.y, 5.5, petro_out.y)
  pipe(5.5, petro_out.y, 5.5, -4.5)
  place("pipe-to-ground", 5.5, -3.5, N)
  place("pipe-to-ground", 5.5, -1.5, S)
  place("pipe", 5.5, -0.5)
  -- The activation plant at the science belt's end, and an overflow for everything else.
  if activation then
    local act = place("chemical-plant", 40.5, 11.5, N); act.set_recipe(activation)
    part("activation " .. activation, act)
    local fi = inserter(38.5, 11.5, W); fi.use_filters = true; fi.set_filter(1, {name = residue, quality = "normal"})
    local at = box(act, "input")
    local ao = box(a, "output", nil, "east")  -- its west connection faces the iron inserter
    pipe(ao.x, ao.y, at.x, ao.y)
    pipe(at.x, ao.y, at.x, at.y)
    inserter(42.5, 11.5, W)
    place("steel-chest", 43.5, 11.5)
    label(41, 7, "Activation: the red line's residue and sulfuric acid make an activated catalyst (chest on the right)")
  else
    label(8, -6, "No residue hint found on this map's early targets: the acid waits for one")
  end
  -- The overflow takes everything but the activation's residue (unfiltered, it took the residue first).
  local over = inserter(37.5, 12.5, N)
  if activation then
    over.use_filters = true; over.inserter_filter_mode = "blacklist"
    over.set_filter(1, {name = residue, quality = "normal"})
  end
  place("steel-chest", 37.5, 13.5)
  label(4, -16, "Oil: crude oil to petroleum gas, sulfur, sulfuric acid")
end

-- Circuits, as a player wires them: the station asked for red science's best doses (port page 3), an
-- arithmetic combinator passing on only the additive this factory supplies, bench 3 in circuit mode
-- (its dose follows the evidence as it comes in); a lamp lit while the red science hopper's machines are
-- dosed (its report).
local RED_W, GREEN_W = defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green
local function rig(chosen, bench3, red_hopper)
  local st = storage.station
  local cc = place("constant-combinator", 23.5, 17.5)
  local sec = cc.get_or_create_control_behavior().get_section(1) or cc.get_or_create_control_behavior().add_section()
  sec.filters = {{value = {type = "recipe", name = "automation-science-pack", quality = "normal"}, min = 1},
                 {value = {type = "virtual", name = "es-page", quality = "normal"}, min = 3}}
  cc.get_wire_connector(RED_W, true).connect_to(st.get_wire_connector(RED_W, true))
  local port = s.find_entities_filtered{name = "es-station-port", position = {st.position.x + 1, st.position.y + 1}, radius = 0.6}[1]
  local ac = place("arithmetic-combinator", 22.5, 14.5, N)
  local item = {type = "item", name = chosen.name, quality = "normal"}
  ac.get_or_create_control_behavior().parameters = {first_signal = item, second_constant = 0, operation = "+",
    output_signal = item}
  port.get_wire_connector(GREEN_W, true).connect_to(ac.get_wire_connector(defines.wire_connector_id.combinator_input_green, true))
  ac.get_wire_connector(defines.wire_connector_id.combinator_output_red, true).connect_to(bench3.get_wire_connector(RED_W, true))
  es("set_dose", bench3.unit_number, {rows = {}, circuit = true})
  storage.rig_bench = bench3
  -- The hopper's report and its lamp.
  es("hopper_report_set", red_hopper.unit_number, true)
  local reporter = s.find_entities_filtered{name = "es-hopper-reporter", position = red_hopper.position, radius = 0.5}[1]
  local lamp = place("small-lamp", -16.5, 2.5)
  local lb = lamp.get_or_create_control_behavior()
  lb.circuit_enable_disable = true
  lb.circuit_condition = {first_signal = {type = "virtual", name = "es-fed"}, comparator = ">", constant = 0}
  reporter.get_wire_connector(RED_W, true).connect_to(lamp.get_wire_connector(RED_W, true))
  storage.lamp = lamp
  label(22.5, 21.5, "Circuits: the station asked for red science's best doses; bench 3 follows them (" .. chosen.name .. ")")
  label(-14, 1, "Lit while the red science machines are dosed (the hopper's report)")
end

script.on_init(function()
  s = game.surfaces.nauvis
  -- Everything researched but Analysis productivity, the labs' work (red packs and empirical science packs;
  -- 0.72: Mastery, which they researched before, is gone), and mining productivity (researched, the factory's
  -- iron fell short of the acid plant at the iron belt's end on every map tried, 2026-10-09; why not traced).
  for name, t in pairs(game.forces.player.technologies) do
    if not name:find("^es%-station%-throughput") and not name:find("^mining%-productivity") then t.researched = true end
  end
  s.request_to_generate_chunks({0, 0}, 6); s.force_generate_chunk_requests()
  -- No enemies: a demonstration factory (on one map in fifteen, small biters ate the power poles mid-run).
  s.peaceful_mode = true
  game.map_settings.enemy_expansion.enabled = false
  for _, e in pairs(s.find_entities_filtered{force = "enemy"}) do e.destroy() end
  for _, e in pairs(s.find_entities_filtered{area = {{-110, -60}, {110, 70}}}) do
    if e.type ~= "character" then e.destroy() end
  end
  local tiles = {}
  for x = -110, 109 do for y = -60, 69 do table.insert(tiles, {name = "landfill", position = {x, y}}) end end
  s.set_tiles(tiles)
  power()
  -- Benches eat 20 gears and 20 copper a trial: five iron drills, four copper (drills below furnaces).
  local _, _, iron_end = smelting("iron-ore", -70, 0, 8, 13)  -- 4 ore/s, furnaces 4.06/s
  local _, _, copper_end = smelting("copper-ore", -62, 20, 6, 11)
  storage.ends = {iron = iron_end, copper = copper_end}
  local chosen = history()
  production(chosen)
  lab(chosen)
  rig(chosen, storage.bench3, storage.red_hopper)
  premix_cell(premix_history())
  oil(catalyst_history(chosen))
  game.forces.player.research_queue = {"es-station-throughput-1"}
  -- Power poles: a grid of medium poles wherever there is room.
  for x = -100, 100, 6 do
    for y = -50, 60, 6 do
      if s.can_place_entity{name = "medium-electric-pole", position = {x + 0.5, y + 0.5}, force = "player"} then
        place("medium-electric-pole", x + 0.5, y + 0.5)
      end
    end
  end
  -- Then every electric entity still off the network gets a pole beside it.
  for _ = 1, 3 do
    for _, e in pairs(s.find_entities_filtered{area = {{-110, -60}, {110, 70}}, type = {"mining-drill", "inserter",
        "assembling-machine", "furnace", "offshore-pump", "lab", "pump", "constant-combinator"}}) do
      if e.electric_buffer_size and e.electric_buffer_size > 0 and not e.is_connected_to_electric_network() then
        local p = s.find_non_colliding_position("medium-electric-pole", e.position, 4, 1, true)
        if p then place("medium-electric-pole", p.x, p.y) end
      end
    end
  end
  storage.parts = parts
end)

-- Proof that every part works (make_playtest.sh showcase runs ten game-minutes and reads this).
script.on_nth_tick(35800, function(event)
  if event.tick == 0 then return end
  local out, failed = {}, {}
  for _, p in ipairs(storage.parts or {}) do
    local e = p.entity
    -- A boiler counts when it holds fuel and makes steam (its status flickers at a given tick).
    local made = e.valid and (e.type == "boiler"
      and ((e.get_fuel_inventory().get_item_count("coal") > 0 or e.burner.currently_burning)
        and e.fluidbox[2] and e.fluidbox[2].amount > 0 and 1 or 0)
      or e.products_finished) or 0
    local status = e.valid and e.status
    for k, v in pairs(defines.entity_status) do if v == status then status = k end end
    table.insert(out, string.format("%s: %s (%s)", p.name, tostring(made), tostring(status)))
    if made <= 0 then table.insert(failed, p.name) end
  end
  table.insert(out, "map seed " .. game.surfaces[1].map_gen_settings.seed .. " (SEED=<it> scripts/make_playtest.sh showcase)")
  -- What died during the run, and what killed it (a part that is gone says nothing about why).
  for _, d in ipairs(storage.deaths or {}) do table.insert(out, "died: " .. d) end
  local h = storage.history or {}
  table.insert(out, string.format("history: %s x%s adopted (net lower bound %.1f per mille)", tostring(h.additive),
    tostring(h.dose), h.lo or 0))
  if storage.station and storage.station.valid then
    local st = es("station", storage.station.unit_number, "red")
    table.insert(out, "station analysed " .. st.analysed .. " samples live (pool " .. st.pool_analysed .. ")")
    if st.analysed <= 0 then table.insert(failed, "station") end
  end
  for i, r in ipairs(storage.dosed_reds or {}) do
    local d = es("dose_state", r.unit_number)
    table.insert(out, "red science " .. i .. " dose: " .. serpent.line(d.status))
    if not (d.status and d.status[1] == "es.dose-ok") then table.insert(failed, "red dose " .. i) end
  end
  if storage.rig_bench and storage.rig_bench.valid then
    local d = es("dose_state", storage.rig_bench.unit_number)
    table.insert(out, "bench 3 by circuit: " .. serpent.line(d.mix) .. ", " .. serpent.line(d.status))
    if not (d.mix and d.mix[h.additive]) then table.insert(failed, "circuit rig") end
    -- Supplied, not only set: a starved hopper makes its trials controls.
    if not (d.status and d.status[1] == "es.dose-ok") then table.insert(failed, "circuit rig supply") end
  end
  if storage.lamp and storage.lamp.valid then
    local lit = storage.lamp.get_control_behavior().disabled == false
    table.insert(out, "hopper report lamp lit: " .. tostring(lit))
    if not lit then table.insert(failed, "report lamp") end
  end
  local ch = storage.catalyst_history or {}
  table.insert(out, string.format("catalyst: %s on %s, activation %s", tostring(ch.residue), tostring(ch.target),
    ch.unlocked and "unlocked" or "not found"))
  local ph = storage.premix_history or {}
  table.insert(out, "premix: " .. tostring(ph.premix) .. "; gears dosed with " .. tostring(ph.adopted and ph.adopted.name)
    .. " x" .. tostring(ph.adopted and ph.adopted.dose))
  if storage.premix_gears and storage.premix_gears.valid then
    local d = es("dose_state", storage.premix_gears.unit_number)
    table.insert(out, "premix gears dose: " .. serpent.line(d.status))
    if not (d.status and d.status[1] == "es.dose-ok") then table.insert(failed, "premix gears supply") end
    -- (0.65) Its residues sorted off into their chest, none on the gear belt.
    local rc = storage.residue_chest
    local sorted = rc and rc.valid and #rc.get_inventory(defines.inventory.chest).get_contents() > 0
    local on_belt = 0
    for _, b in pairs(game.surfaces.nauvis.find_entities_filtered{type = "transport-belt"}) do  -- (s is set in on_init only)
      for line = 1, 2 do
        for _, it in pairs(b.get_transport_line(line).get_contents()) do
          if it.name:find("^es%-spent%-") then on_belt = on_belt + it.count end
        end
      end
    end
    table.insert(out, string.format("residues: sorted into their chest %s; on belts %d", tostring(sorted), on_belt))
    if not sorted then table.insert(failed, "gear residues sorted off") end
  end
  local unlocked = {}
  for name, r in pairs(game.forces.player.recipes) do
    if name:find("^es%-premix%-") and r.enabled and not name:find("%-barrel") and not name:find("%-recycling$") then
      table.insert(unlocked, name)
    end
  end
  table.insert(out, "premixes discovered: " .. (#unlocked > 0 and table.concat(unlocked, ", ") or "none"))
  -- (0.72) A premix found by evidence earns Sum of the parts (recorded per force: the run has no player).
  if #unlocked > 0 and not es("achieved", "player")["es-sum-of-parts"] then table.insert(failed, "achievement Sum of the parts") end
  local research = game.forces.player.current_research
  table.insert(out, "researching: " .. (research and research.name or "nothing") .. ", progress "
    .. string.format("%.3f", game.forces.player.research_progress or 0))
  table.insert(out, #failed == 0 and "KIT OK" or ("KIT FAIL: " .. table.concat(failed, ", ")))
  helpers.write_file("es-kit-status.txt", table.concat(out, "\n") .. "\n")
end)

-- Deaths, for the report: a factory part destroyed mid-run (one map in fifteen lost its boilers).
script.on_event(defines.events.on_entity_died, function(ev)
  storage.deaths = storage.deaths or {}
  if #storage.deaths < 30 then
    local e, c = ev.entity, ev.cause
    table.insert(storage.deaths, string.format("%s at %.0f,%.0f by %s (%s)", e.name, e.position.x, e.position.y,
      c and c.valid and c.name or "nothing", ev.damage_type and ev.damage_type.name or "?"))
  end
end)
