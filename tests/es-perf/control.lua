-- A large base for measuring the mod's script cost (scripts/perf_test.sh reads Factorio's timings).
-- Real logistics: infinity chests feed through inserters; outputs go to chests that delete items.
local es = function(fn, ...) return remote.call("empirical-science", fn, ...) end
local shared = require("__empirical-science__.shared")
-- The mega variant (scripts/perf_test.sh mega): 800 more benches, 1,000 in all (a research array the
-- force pool invites), on a larger map. Selected by an empty marker mod.
local MEGA = script.active_mods["es-perf-mega"] ~= nil
local R = MEGA and 420 or 250
script.on_init(function()
  local s = game.surfaces.nauvis
  for _, t in pairs(game.forces.player.technologies) do t.researched = true end
  s.request_to_generate_chunks({0, 0}, MEGA and 16 or 12); s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities_filtered{area = {{-R, -R}, {R, R}}}) do e.destroy() end
  local tiles = {}
  for x = -R, R - 1 do for y = -R, R - 1 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
  s.set_tiles(tiles)
  local function place(name, x, y, dir)
    return s.create_entity{name = name, position = {x, y}, force = "player", raise_built = true, direction = dir}
  end
  local function source(x, y, items)
    local c = place("infinity-chest", x, y)
    local filters = {}
    for i, it in ipairs(items) do filters[i] = {name = it, count = 100, mode = "at-least", index = i} end
    c.infinity_container_filters = filters
    return c
  end
  local function sink(x, y) local c = place("infinity-chest", x, y); c.remove_unfiltered_items = true; return c end
  -- Power: one big interface and substations in a grid.
  local eei = place("electric-energy-interface", -240, -240)
  eei.power_production = 1e9; eei.electric_buffer_size = 1e9
  for x = -234, R - 10, 18 do for y = -234, R - 10, 18 do place("substation", x, y) end end
  -- A row of machines, each fed from an infinity chest above; with `dose`, a hopper on its right edge fed by
  -- an inserter from its own infinity chest (items), and for a fluid a fluid hopper below it reaching into the
  -- gap, fed by an infinity pipe.
  local function machine_row(name, recipe, x0, y0, count, inputs, dose, per_row)
    per_row = per_row or 20
    local list = {}
    for i = 0, count - 1 do
      local x = x0 + (i % per_row) * 6
      local y = y0 + math.floor(i / per_row) * 8
      local m = place(name, x, y)
      if recipe then m.set_recipe(recipe) end
      source(x, y - 3, inputs); place("fast-inserter", x, y - 2, defines.direction.north)
      place("fast-inserter", x, y + 2, defines.direction.north); sink(x, y + 3)
      if dose then
        place("es-hopper", x + 2, y)
        local items = {}
        for name in pairs(dose) do
          if name == "lubricant" then
            -- (1x2, as the pump: from the machine's edge out into the gap, the pipe at its far end.)
            place("es-fluid-hopper", x + 3, y + 1, defines.direction.east)
            local p = place("infinity-pipe", x + 4, y + 1)
            p.set_infinity_pipe_filter{name = "lubricant", percentage = 1, temperature = 25}
          else
            table.insert(items, name)
          end
        end
        if #items > 0 then source(x + 2, y - 2, items); place("fast-inserter", x + 2, y - 1, defines.direction.north) end
        local rows = {}
        for name, d in pairs(dose) do table.insert(rows, {name = name, dose = d}) end
        es("set_dose", m.unit_number, {rows = rows})
      end
      table.insert(list, m)
    end
    return list
  end
  -- Sulfur and lubricant (tier 2).
  machine_row("es-test-bench", "es-trial-gear-control", -230, -230, 200, {"iron-plate"}, {sulfur = 3})
  machine_row("assembling-machine-2", "iron-gear-wheel", -230, -140, 500, {"iron-plate"}, {sulfur = 3})
  machine_row("assembling-machine-2", "iron-gear-wheel", -230, -30, 500, {"iron-plate"})
  machine_row("es-test-bench", "es-trial-gear-control", -230, 80, 30, {"iron-plate"}, {lubricant = 40})
  machine_row("assembling-machine-2", "electronic-circuit", -230, 110, 20, {"iron-plate", "copper-cable"},
    {sulfur = 2, lubricant = 30})
  -- Freshness (0.52): 60 biochambers making bioflux, dosed with the tier 1 additive that restores most on
  -- this map (each is looked at every few ticks while it restores).
  if prototypes.recipe["bioflux"] then
    game.forces.player.recipes["bioflux"].enabled = true
    local best, bf = nil, 0
    for _, a in ipairs(shared.tier1) do
      local f = es("effect_on", "bioflux", {[a.name] = 5}, "freshness")
      if not shared.additive(a.name).fluid and f > bf then best, bf = a.name, f end
    end
    if best then
      machine_row("biochamber", "bioflux", -230, 140, 60, {"yumako-mash", "jelly", "nutrients"}, {[best] = 5})
      storage.fresh_rows = 60
    end
  end
  if MEGA then
    machine_row("es-test-bench", "es-trial-gear-control", -230, 180, 800, {"iron-plate"}, {sulfur = 3}, 40)
  end
  -- Hopper reports (0.49): 400 hoppers report to the circuit (the design's measuring point).
  local reporting = 0
  for _, h in pairs(game.surfaces.nauvis.find_entities_filtered{name = {"es-hopper", "es-fluid-hopper"}}) do
    if reporting >= 400 then break end
    es("hopper_report_set", h.unit_number, true)
    reporting = reporting + 1
  end
  storage.reporting = reporting
  for i = 0, 9 do
    local st = place("es-analysis-station", -230 + i * 8, 140)
    st.get_inventory(defines.inventory.chest).insert{name = "automation-science-pack", count = 200}
  end
end)

-- Proof of work: what the base actually did (a benchmark of an idle base would prove nothing).
script.on_nth_tick(7000, function(event)
  if event.tick == 0 then return end
  local s = game.surfaces.nauvis
  local out = {}
  for _, name in ipairs({"es-test-bench", "assembling-machine-2"}) do
    local crafts, active = 0, 0
    for _, e in pairs(s.find_entities_filtered{name = name}) do
      crafts = crafts + e.products_finished
      if e.products_finished > 0 then active = active + 1 end
    end
    table.insert(out, string.format("%s: %d crafts, %d of %d machines worked", name, crafts, active,
      #s.find_entities_filtered{name = name}))
  end
  local dosed = 0
  for _, e in pairs(s.find_entities_filtered{type = "assembling-machine"}) do
    local st = remote.call("empirical-science", "dose_state", e.unit_number)
    if st and st.status and st.status[1] == "es.dose-ok" then dosed = dosed + 1 end
  end
  table.insert(out, "machines dosed on their last crafts: " .. dosed)
  table.insert(out, "hoppers reporting to the circuit: " .. (storage.reporting or 0))
  table.insert(out, "freshness-dosed biochambers: " .. (storage.fresh_rows or 0))
  -- Benches are checked when their craft is due, not every tick: samples must still all be tagged.
  table.insert(out, "samples missed by tagging: " .. remote.call("empirical-science", "missed_tags"))
  helpers.write_file("es-perf-work.txt", table.concat(out, "\n") .. "\n")
end)
