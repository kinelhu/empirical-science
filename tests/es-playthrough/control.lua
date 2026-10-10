-- A robot player runs the loop the way a careful player would, using only what the station shows:
-- screen (every tier 1 additive at doses 2, 5, 8 plus a control), confirm (best dose +-1 against the
-- control), and if the best beats the control at p < 0.05, save it as a preset and dose production
-- lines with it (hoppers against the machines), then measure the factory.
-- It starts where a new game does (the method researched, nothing staged) and carries the research data
-- the station makes into labs researching the first technology of the branch, Analysis precision 1 (0.72:
-- Process routes, the first stage before, is retired), as a player would.
-- The hidden truth is read only for the final report. scripts/playthrough.sh runs it.
local es = function(fn, ...) return remote.call("empirical-science", fn, ...) end
local OUT = "es-playthrough.txt"
-- The first research target a player would pick: red science (simple products like gears barely
-- respond to additives).
local TARGET, RESULT = "red", "automation-science-pack"
-- The early set (0.70: wood waits for Tree seeding, so a careful player starts without it).
local shared = require("__empirical-science__.shared")
local TIER1 = {}
for _, a in ipairs(shared.early) do table.insert(TIER1, a.name) end
local SCREEN_N, CONFIRM_N = 8, 16

local function place(name, x, y, dir)
  return game.surfaces.nauvis.create_entity{name = name, position = {x, y}, force = "player", raise_built = true,
    direction = dir}
end
-- A bench's dose: set in its panel (rows), taken from the hopper on its top edge.
local function dose_bench(b, cell)
  es("set_dose", b.entity.unit_number, {rows = cell.additive and {{name = cell.additive, dose = cell.dose}} or {}})
  b.additive = cell.additive
end
-- Keep a hopper stocked with an additive.
local function tend(hopper, additive)
  local inv = hopper.get_inventory(defines.inventory.chest)
  if additive and inv.get_item_count(additive) < 30 then inv.insert{name = additive, count = 30 - inv.get_item_count(additive)} end
end
local function key_for(additive, dose) return additive and (additive .. ":" .. dose) or "control" end

script.on_init(function()
  local s = game.surfaces.nauvis
  -- Peaceful: an hour of pollution draws attacks that destroy the lab (a chest gone near the end).
  s.peaceful_mode = true
  for _, e in pairs(s.find_entities_filtered{force = "enemy"}) do e.destroy() end
  for _, t in pairs({"es-empirical-method", "automation-science-pack"}) do game.forces.player.technologies[t].researched = true end
  s.request_to_generate_chunks({0, 0}, 4); s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities_filtered{area = {{-80, -80}, {80, 80}}}) do e.destroy() end
  local tiles = {}
  for x = -80, 79 do for y = -80, 79 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
  s.set_tiles(tiles)
  local eei = place("electric-energy-interface", -70, -70); eei.power_production = 1e8; eei.electric_buffer_size = 1e8
  for x = -66, 72, 18 do for y = -66, 72, 18 do place("substation", x, y) end end
  storage.station = place("es-analysis-station", 0, 30)
  -- Labs for the first stage: what a new game shows before any of it is researched.
  local force = game.forces.player
  storage.start_state = {first = force.technologies["es-precision-instruments-1"].researched,
    mixtures = force.technologies["es-mixtures"].researched}
  storage.labs = {}
  for i = 0, 5 do table.insert(storage.labs, place("lab", -30 + i * 4, 45)) end
  force.add_research("es-precision-instruments-1")
  storage.data_moved = 0
  -- Screening design: control + 5 additives x doses 2, 5, 8 = 16 cells, one bench each.
  storage.cells = {{}}
  for _, a in ipairs(TIER1) do for _, d in ipairs({2, 5, 8}) do table.insert(storage.cells, {additive = a, dose = d}) end end
  storage.benches = {}
  for i, cell in ipairs(storage.cells) do
    local x = -60 + (i - 1) * 6
    local b = place("es-test-bench", x, 0)
    b.set_recipe("es-trial-" .. TARGET .. "-control")
    place("fast-inserter", x, 2, defines.direction.north)
    local bench = {entity = b, chest = place("iron-chest", x, 3), hopper = place("es-hopper", x, -2)}
    dose_bench(bench, cell)
    table.insert(storage.benches, bench)
  end
  storage.phase, storage.t0, storage.packs = "screen", 0, 0
  storage.log = {}
end)

local function summary(key) return es("station", storage.station.unit_number, TARGET).summaries[key] or {n = 0} end
local function log(s) table.insert(storage.log, s) end

local function feed_and_collect(entity, chest, station_inv)
  if not (entity.valid and chest.valid) then
    storage.lost = (storage.lost or 0) + 1
    return
  end
  local recipe = entity.get_recipe()
  local inv = entity.get_inventory(defines.inventory.crafter_input)
  for _, ing in pairs(recipe.ingredients) do inv.insert{name = ing.name, count = ing.amount * 3} end
  local c = chest.get_inventory(defines.inventory.chest)
  -- (0.72) A sample moves when the station has room (it holds four waiting); otherwise it waits in the chest,
  -- and a full chest holds its bench up, as an inserter would. Products go.
  for i = 1, #c do
    local st = c[i]
    if st.valid_for_read then
      if not shared.is_sample(st.name) then st.clear()
      elseif station_inv.insert(st) == 1 then st.clear() end
    end
  end
end

local function set_design(cells)
  storage.design = cells
  for i, b in ipairs(storage.benches) do
    dose_bench(b, cells[(i - 1) % #cells + 1])
  end
end

local function all_have(cells, n)
  for _, cell in ipairs(cells) do if summary(key_for(cell.additive, cell.dose)).n < n then return false end end
  return true
end

local function production_setup()
  storage.lines = {}
  for i = 0, 9 do
    for _, kind in ipairs({"dosed", "vanilla"}) do
      local x = -60 + i * 6
      local y = kind == "dosed" and 15 or -15
      local a = place("assembling-machine-2", x, y)
      a.set_recipe(RESULT)
      local line = {entity = a, kind = kind, plates = 0, gears = 0}
      if kind == "dosed" then
        -- The saved preset becomes the machine's rows, as a player would pick it in the panel.
        local preset = es("presets", "player")[1]
        local rows = {}
        for name, dose in pairs(preset.mix) do table.insert(rows, {name = name, dose = dose}) end
        es("set_dose", a.unit_number, {rows = rows})
        line.hopper, line.additive = place("es-hopper", x, y - 2), next(preset.mix)
      end
      table.insert(storage.lines, line)
    end
  end
end

-- Progress every ten game-minutes, so a stalled run says where it stalled.
script.on_nth_tick(36000, function(event)
  if event.tick == 0 or storage.reported then return end
  local counts = {}
  for _, cell in ipairs(storage.design or storage.cells) do
    table.insert(counts, (cell.additive or "control") .. ":" .. (cell.dose or 0) .. "=" .. summary(key_for(cell.additive, cell.dose)).n)
  end
  local b = storage.benches[2]
  local st = es("dose_state", b.entity.unit_number)
  local status
  for name, v in pairs(defines.entity_status) do if v == b.entity.status then status = name end end
  helpers.write_file("es-playthrough-progress.txt", string.format("tick %d phase %s; %s; bench 2: recipe %s (enabled %s), "
    .. "status %s, crafts %d, input %s, dose %s\n",
    event.tick, storage.phase, table.concat(counts, " "), b.entity.get_recipe() and b.entity.get_recipe().name or "-",
    tostring(b.entity.get_recipe() and game.forces.player.recipes[b.entity.get_recipe().name].enabled), tostring(status),
    b.entity.products_finished, serpent.line(b.entity.get_inventory(defines.inventory.crafter_input).get_contents()),
    serpent.line(st)), true)
end)

script.on_nth_tick(60, function(event)
  if event.tick == 0 then return end
  local station_inv = storage.station.get_inventory(defines.inventory.chest)
  local have = station_inv.get_item_count("automation-science-pack")
  if have < 20 then storage.packs = storage.packs + station_inv.insert{name = "automation-science-pack", count = 20 - have} end
  if storage.phase ~= "produce" then
    for _, b in ipairs(storage.benches) do tend(b.hopper, b.additive); feed_and_collect(b.entity, b.chest, station_inv) end
  end
  -- Research data from the station into the labs, with red packs (the stage's other ingredient).
  local data = station_inv.get_item_count("es-research-data")
  for i, lab in ipairs(storage.labs) do
    local li = lab.get_inventory(defines.inventory.lab_input)
    if li.get_item_count("automation-science-pack") < 5 then
      storage.lab_packs = (storage.lab_packs or 0) + li.insert{name = "automation-science-pack", count = 5}
    end
    local share = math.floor(data / (#storage.labs - i + 1))
    if share > 0 then
      local moved = li.insert{name = "es-research-data", count = share}
      if moved > 0 then station_inv.remove{name = "es-research-data", count = moved} end
      data, storage.data_moved = data - moved, storage.data_moved + moved
    end
  end

  if storage.phase == "screen" and all_have(storage.cells, SCREEN_N) then
    local best, best_mean = nil, -1e9
    for _, cell in ipairs(storage.cells) do
      if cell.additive then
        local s = summary(key_for(cell.additive, cell.dose))
        if s.mean > best_mean then best, best_mean = cell, s.mean end
      end
    end
    log(string.format("screen done at %.1f min: best cell %s x%d (%+.1f%%)", event.tick / 3600, best.additive, best.dose,
      best_mean / 10))
    storage.screen_best = best
    local design = {{}}
    for _, d in ipairs({best.dose - 1, best.dose, best.dose + 1}) do
      if d >= 1 and d <= 9 then table.insert(design, {additive = best.additive, dose = d}) end
    end
    set_design(design)
    storage.phase = "confirm"
  elseif storage.phase == "confirm" and all_have(storage.design, CONFIRM_N) then
    local control = summary("control")
    local best, best_s = nil, nil
    for _, cell in ipairs(storage.design) do
      if cell.additive then
        local s = summary(key_for(cell.additive, cell.dose))
        if not best_s or s.mean > best_s.mean then best, best_s = cell, s end
      end
    end
    local p = es("welch", best_s, control)
    log(string.format("confirm done at %.1f min: best %s x%d %+.1f%% [%+.1f, %+.1f], p vs control %.4f",
      event.tick / 3600, best.additive, best.dose, best_s.mean / 10, best_s.lo / 10, best_s.hi / 10, p))
    storage.samples_used = 0
    for _, key in ipairs({"control"}) do end
    storage.confirmed = best
    storage.adopt_decision = p < 0.05 and best_s.mean > 0
    if storage.adopt_decision then
      es("add_preset", "player", TARGET, {[best.additive] = best.dose})
      production_setup()
      storage.produce_start = event.tick
      storage.phase = "produce"
    else
      log("no adoption: the evidence did not clear p < 0.05")
      storage.phase = "report"
    end
  elseif storage.phase == "produce" then
    for _, l in ipairs(storage.lines) do
      if l.hopper then tend(l.hopper, l.additive) end
      local inv = l.entity.get_inventory(defines.inventory.crafter_input)
      for _, ing in pairs(l.entity.get_recipe().ingredients) do
        local have_i = inv.get_item_count(ing.name)
        if have_i < ing.amount * 3 then
          local added = inv.insert{name = ing.name, count = ing.amount * 3 - have_i}
          if ing.name == "iron-plate" then l.plates = l.plates + added end
        end
      end
      local out = l.entity.get_inventory(defines.inventory.crafter_output)
      l.gears = l.gears + out.get_item_count(RESULT)
      out.clear()
      l.crafts = l.entity.products_finished  -- counted with the gears collected so far
    end
    if event.tick - storage.produce_start >= 36000 then storage.phase = "report" end
  elseif storage.phase == "report" and not storage.reported then
    storage.reported = true
    local lines, failed = {}, 0
    local function check(name, ok, detail)
      if not ok then failed = failed + 1 end
      table.insert(lines, (ok and "PASS " or "FAIL ") .. name .. (detail ~= nil and ("  " .. tostring(detail)) or ""))
    end
    for _, l in ipairs(storage.log) do table.insert(lines, "INFO " .. l) end
    local st = es("station", storage.station.unit_number, TARGET)
    table.insert(lines, string.format("INFO samples analysed %d, packs used %d", st.analysed, storage.packs))
    -- Hidden truth, for the report only.
    local best_true, best_name = -1, nil
    for _, a in ipairs(TIER1) do
      for d = 1, 9 do
        local g = es("gain", TARGET, a, d)
        if g > best_true then best_true, best_name = g, a .. " x" .. d end
      end
    end
    table.insert(lines, string.format("INFO best possible (truth): %s %+.1f%%", best_name, best_true * 100))
    if storage.adopt_decision then
      local c = storage.confirmed
      local g = es("gain", TARGET, c.additive, c.dose)
      -- Gears per completed craft against the recipe's nominal (a craft still in progress has used its
      -- plates without producing yet, so plates fed would undercount the adopted line's output).
      local per = {dosed = {g = 0, c = 0}, vanilla = {g = 0, c = 0}}
      for _, l in ipairs(storage.lines) do
        per[l.kind].g = per[l.kind].g + l.gears
        per[l.kind].c = per[l.kind].c + (l.crafts or 0)
      end
      local realized = (per.dosed.g / per.dosed.c) / (per.vanilla.g / per.vanilla.c) - 1
      table.insert(lines, string.format("INFO adopted %s x%d: true gain %+.1f%% (%.0f%% of the best possible); factory "
        .. "products per craft %+.1f%% vs vanilla", c.additive, c.dose, g * 100, 100 * g / best_true, realized * 100))
      check("the robot adopted a real improvement", g > 0.02, string.format("%+.1f%%", g * 100))
      check("the factory realises the true gain", math.abs(realized - g) < 0.02,
        string.format("%+.1f%% vs %+.1f%%", realized * 100, g * 100))
    end
    check("the whole discovery took under an hour of game time", event.tick < 3600 * 60 + 36000 + 600,
      string.format("%.1f min", event.tick / 3600))
    check("the lab is intact", (storage.lost or 0) == 0, storage.lost)
    -- Staged reveal: the run started with nothing staged, and bought Analysis precision 1 with its own data.
    local force = game.forces.player
    local ss = storage.start_state
    check("a new game starts with nothing staged (no Analysis precision, no Mixtures)",
      not ss.first and not ss.mixtures, string.format("analysis precision %s, mixtures %s", tostring(ss.first), tostring(ss.mixtures)))
    check("the data this discovery earned bought Analysis precision 1",
      force.technologies["es-precision-instruments-1"].researched,
      string.format("empirical science packs carried to labs %d (and %d red packs), researched at %s min", storage.data_moved,
        storage.lab_packs or 0, storage.first_at and string.format("%.1f", storage.first_at / 3600) or "never"))
    table.insert(lines, failed == 0 and "DONE ALL PASSED" or ("DONE " .. failed .. " FAILED"))
    helpers.write_file(OUT, table.concat(lines, "\n") .. "\n")
  end
end)

script.on_event(defines.events.on_research_finished, function(event)
  if event.research.name == "es-precision-instruments-1" then storage.first_at = event.tick end
end)
