local shared = require("__empirical-science__.shared")
-- GUI smoke test, run in the real game window by scripts/guitest.sh. A player joins; the test fills a
-- station with samples, opens its panel and drives every view. Any GUI error crashes the mod, which
-- the shell script sees in the log; success writes es-guitest-results.txt.
local OUT = "es-guitest-results.txt"
local es = function(fn, ...) return remote.call("empirical-science", fn, ...) end

local lines, failed = {}, 0
local function check(name, ok, detail)
  if not ok then failed = failed + 1 end
  table.insert(lines, (ok and "PASS " or "FAIL ") .. name .. (detail ~= nil and ("  " .. tostring(detail)) or ""))
end

-- The sample a target's trial makes (0.72: one kind per science pack).
local function SAMPLE_OF(target) return prototypes.recipe["es-trial-" .. target .. "-control"].main_product.name end

script.on_init(function()
  -- (0.72: stations read a sample every 5 s; this test analyses its queue at the old pace, as es-test does.)
  remote.call("empirical-science", "analysis_ticks", 30)
  for _, t in ipairs({"es-empirical-method", "es-mixtures", "es-thermal-studies",
                      "es-precision-instruments-1", "es-circuit-instrumentation-1", "es-theory"}) do
    game.forces.player.technologies[t].researched = true
  end
  -- Wood waits for Tree seeding on new maps (0.70, Space Age only): open it, so every list below is whole.
  if prototypes.technology["tree-seeding"] then game.forces.player.technologies["tree-seeding"].researched = true end
  -- The dose picker offers what the force has made or can make: count every vanilla additive as made,
  -- so the picker checks below see the whole list (the rule itself is checked in es-test).
  local force = game.forces.player
  -- Additives only (every item would include module 3s, whose achievements pop up over the screenshots).
  for _, a in ipairs(shared.additives) do
    if not a.name:find("^es%-") or a.residue_of then  -- residues count as made too
      local st = a.fluid and force.get_fluid_production_statistics(game.surfaces.nauvis) or force.get_item_production_statistics(game.surfaces.nauvis)
      st.on_flow(a.name, 1)
    end
  end
  -- Every target's trial unlocked, so the screen lists every target for the view sweep below.
  for name, r in pairs(force.recipes) do if name:find("^es%-trial%-.+%-control$") then r.enabled = true end end
  local s = game.surfaces.nauvis
  s.request_to_generate_chunks({0, 0}, 1)
  s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities_filtered{area = {{-10, -10}, {10, 10}}}) do e.destroy() end
  storage.station = s.create_entity{name = "es-analysis-station", position = {0, 0}, force = "player", raise_built = true}
  -- (0.72) Its queue mixes kinds of sample (gears, engines): the layout before 0.72, every kind in every slot.
  remote.call("empirical-science", "station_any", storage.station.unit_number)
  -- A test bench dosed lubricant 37 + stone 2 (a fluid hopper on its right, piped; a hopper below it), and a
  -- gear assembler dosed from a preset, with a hopper on its top edge.
  storage.dosebench = s.create_entity{name = "es-test-bench", position = {8.5, 0.5}, force = "player", raise_built = true}
  storage.dosebench.set_recipe("es-trial-engine-control")
  -- (1x2, as the pump: from the bench's edge out to the right, the pipe at its far end.)
  s.create_entity{name = "es-fluid-hopper", position = {11, 0.5}, direction = defines.direction.east, force = "player", raise_built = true}
  s.create_entity{name = "pipe", position = {12.5, 0.5}, force = "player"}
  -- A hopper below it (0.71: items; the fluid hopper beside it takes the lubricant): in the lineup and the
  -- close-up, the two side by side.
  s.create_entity{name = "es-hopper", position = {8.5, 2.5}, force = "player", raise_built = true}
  remote.call("empirical-science", "set_dose", storage.dosebench.unit_number,
    {rows = {{name = "lubricant", dose = 37}, {name = "stone", dose = 2}}})
  s.create_entity{name = "es-test-bench", position = {-5.5, 0.5}, force = "player", raise_built = true}
  storage.assembler = s.create_entity{name = "assembling-machine-2", position = {2.5, 10.5}, force = "player", raise_built = true}
  -- The fluid heaters, for the lineup screenshot (their own look).
  s.create_entity{name = "es-fluid-heater", position = {-9, 12}, force = "player", direction = defines.direction.north}
  s.create_entity{name = "es-heat-fluid-heater", position = {13, 12}, force = "player", direction = defines.direction.north}
  storage.assembler.set_recipe("iron-gear-wheel")
  s.create_entity{name = "es-hopper", position = {2.5, 8.5}, force = "player", raise_built = true}
  remote.call("empirical-science", "add_preset", "player", "gear", {coal = 4, stone = 2})
  -- Fake but well-formed samples: stone at every dose, a control, and a few engine samples.
  local inv = storage.station.get_inventory(defines.inventory.chest)
  -- Samples wait in a queue and are fed in as the (30-slot) station frees space.
  storage.queue = {}
  local function sample(target, additive, dose, y)
    -- Speed and pollution too (7d): a mild slowdown and a pollution cost that grow with the dose.
    table.insert(storage.queue, {name = SAMPLE_OF(target), count = 1, tags = {target = target, additive = additive, dose = dose,
      y = y, sp = 100 - 1.5 * dose + (y % 3), pp = 100 - 4 * dose + (y % 5), ef = 100 - dose + (y % 2),
      pack = target == "engine" and "logistic-science-pack" or "automation-science-pack"}})
  end
  for rep = 1, 2 do
    -- Yields are measured in % of nominal.
    sample("gear", "", 0, 98 + 3 * rep)
    for d = 1, 9 do sample("gear", "stone", d, 100 + math.floor(30 * math.sin(d / 3)) + 3 * rep) end
  end
  for rep = 1, 3 do sample("engine", "coal", 2, 108 + 4 * (rep % 2)) end
  -- The temperature axis and ripeness (0.61-0.62): lubricant on gears at five temperatures, below zero to
  -- above Nauvis's reach; yumako mash fresh and half spoiled.
  local function at_state(name, dose, state, y)
    table.insert(storage.queue, {name = SAMPLE_OF("gear"), count = 1, tags = {target = "gear", mix = {[name] = dose}, additive = "",
      dose = 0, temps = {[name] = state}, y = y, pack = "automation-science-pack"}})
  end
  for rep = 1, 2 do
    for _, ty in ipairs({{-100, 104}, {-40, 108}, {20, 112}, {60, 109}, {150, 103}}) do
      at_state("lubricant", 40, ty[1], ty[2] + rep)
    end
    if prototypes.item["yumako-mash"] then
      at_state("yumako-mash", 4, 0.05, 102 + rep); at_state("yumako-mash", 4, 0.5, 110 + rep)
    end
  end
  -- Engine controls: a second target with a single-additive result, so the Theory tab can fit (0.59).
  for rep = 1, 2 do sample("engine", "", 0, 99 + 2 * rep) end
  -- Sulfur (oil era) at two doses: its adopt choices are the tested doses, not 1 to 9.
  for rep = 1, 2 do
    sample("gear", "sulfur", 2, 103 + 2 * rep)
    sample("gear", "sulfur", 5, 107 + 2 * rep)
  end
  -- A coal x stone design for the mixtures tab: yields (% of nominal) from a known surface.
  local function mixed(mix, y) table.insert(storage.queue, {name = SAMPLE_OF("gear"), count = 1, tags = {target = "gear",
    mix = mix, additive = "", dose = 0, y = y, pack = "automation-science-pack"}}) end
  local function surface(c, st) return 100 + 3 * c + 2 * st - 0.3 * c * c - 0.2 * st * st + 0.4 * c * st end
  for rep = -1, 1, 2 do
    for _, cs in ipairs({{2, 0}, {5, 0}, {8, 0}, {0, 2}, {0, 5}, {0, 8}, {2, 2}, {5, 5}, {8, 2}, {2, 8}}) do
      local mix = {}
      if cs[1] > 0 then mix.coal = cs[1] end
      if cs[2] > 0 then mix.stone = cs[2] end
      mixed(mix, surface(cs[1], cs[2]) + rep * 1.5)
    end
  end
  inv.insert{name = "automation-science-pack", count = 50}
  inv.insert{name = "logistic-science-pack", count = 10}
  storage.phase = 0
end)

-- An additive's position in the screen's lists (0.72: the lists hold only what the force can make or has
-- evidence on, so positions are not fixed).
local function A(player, name)
  for i, n in ipairs(remote.call("empirical-science", "visible_names", player.index)) do if n == name then return i end end
  error("additive not listed: " .. name)
end

-- The Empirical Science screen (the force's evidence); the station's own window is es_station.
local function panel(player) return player.gui.screen.es_science and player.gui.screen.es_science.panel end

-- A screenshot of the screen as it is now. The test runs at game speed 8, eight ticks to a rendered frame, so a
-- screenshot taken then showed a tab chosen a few ticks later (Coverage came out as Presets): at speed 1 for
-- the tick it is taken and the few after it, it renders what this step set up.
local function shot(player, path)
  game.speed = 1
  storage.speed_back = storage.phase + 4
  game.take_screenshot{player = player, show_gui = true, path = path}
end

script.on_event(defines.events.on_tick, function(event)
  local player = game.get_player(1)
  if not player or not storage.station then return end
  storage.phase = storage.phase + 1
  local p = storage.phase
  if storage.speed_back == p then game.speed = 8; storage.speed_back = nil end
  if p % 30 == 0 and #storage.queue > 0 then
    local inv = storage.station.get_inventory(defines.inventory.chest)
    while #storage.queue > 0 and inv.insert(storage.queue[1]) == 1 do table.remove(storage.queue, 1) end
  end
  if p == 1 then game.speed = 8 end
  if p == 1800 then  -- ~20 samples analysed at 2 per second (game speed 8)
    player.opened = storage.station
  elseif p == 1830 then
    local w = player.gui.relative.es_station
    check("the station's window shows its counts and its port's target", w ~= nil
      and w.panel.counts.v_analysed.caption ~= "" and w.panel.counts.v_data.caption ~= ""
      and #w.panel.port.port_target.items >= 11,
      w and (w.panel.counts.v_analysed.caption .. " analysed, " .. w.panel.counts.v_data.caption .. " data"))
    -- 0.24-0.28 additions: failed runs row; the start hint hidden once samples are analysed.
    check("the station's window lists failed runs, and hides its start hint once it has analysed",
      w ~= nil and w.panel.counts.v_failed ~= nil and w.panel.hint.visible == false)
    -- 0.59: the page its port serves (page 0 and the chosen target without a wire).
    local port = w and w.panel.counts.v_port and w.panel.counts.v_port.caption
    check("the station's window says what its port serves", type(port) == "table" and port[1] == "es.st-port-value",
      serpent.line(port))
    -- 0.72: Unreadable hidden while it counts nothing (the signal table moved to Tips and tricks).
    check("the station window hides Unreadable while it counts nothing",
      w ~= nil and w.panel.counts.k_unreadable.visible == false and w.panel.counts.v_unreadable.visible == false)
    shot(player, "es-station-window.png")
  elseif p == 1845 then
    es("open_science", player.index)  -- what the window's button does (a tick after its screenshot)
  elseif p == 1860 then
    local pn = panel(player)
    check("the Empirical Science screen opens", pn ~= nil and player.gui.relative.es_station == nil)
    if not pn then return end
    -- 0.24-0.28 additions: the planet selector (Nauvis here), the empty-state text hidden (evidence
    -- exists), the Data column header.
    local sdd = pn.top.surface
    -- Any fluid additive shows the temperature selector on Dose-response (lubricant here).
    local vis = {}
    for i, a in ipairs(remote.call("empirical-science", "visible_names", player.index)) do vis[a] = i end
    if vis["lubricant"] then
      es("gui_set", player.index, {additive = vis["lubricant"]})
      check("the temperature selector shows for a fluid additive (lubricant)", pn.pages.dose.head.temp.visible == true)
      es("gui_set", player.index, {additive = A(player, "coal")})
    end
    -- 0.70: by default the Target list holds the sampled targets, each with its count; "All targets" adds
    -- the rest (the steps below pick targets by position in the full list).
    local items = pn.top.target.items
    local unticked = pn.top.all_targets.state == false
    local counted = 0
    for _, it in ipairs(items) do if type(it) == "table" and tostring(it[3]):find("^ %(%d+%)$") then counted = counted + 1 end end
    es("gui_set", player.index, {all_targets = true})
    local all_n = #panel(player).top.target.items
    check("the Target list shows sampled targets with their counts; All targets lists more",
      #items >= 1 and counted == #items and all_n > #items and unticked and panel(player).top.all_targets.state,
      string.format("%d sampled (%d with a count), %d in all", #items, counted, all_n))
    pn = panel(player)
    check("the screen has a planet selector showing Nauvis", sdd ~= nil and #sdd.items >= 1 and sdd.selected_index >= 1,
      sdd and serpent.line(sdd.items))
    check("the screen hides its start text once there is evidence", pn.pages.screening.empty.visible == false)
    check("the Dose-response tab has a temperature selector, hidden for an ordinary additive",
      pn.pages.dose.head.temp ~= nil and pn.pages.dose.head.temp.visible == false)
    local data_col
    for i = 1, pn.pages.screening.grid_scroll.overview.column_count do
      local c = pn.pages.screening.grid_scroll.overview.children[i].caption
      if type(c) == "table" and c[1] == "es.col-data" then data_col = i end
    end
    check("the Screening grid has a Net column", data_col ~= nil, tostring(data_col))
    -- (0.72) Best dose and Packs per sample headers; every row a full set of cells.
    local ov = pn.pages.screening.grid_scroll.overview
    local heads = {}
    for i = 1, ov.column_count do local c = ov.children[i].caption; heads[i] = type(c) == "table" and c[1] or c end
    check("Screening: Best dose and Packs per sample headers, every row full",
      heads[4] == "es.col-best-dose" and heads[data_col + 1] == "es.col-rate" and #ov.children % ov.column_count == 0,
      string.format("heads %s; %d cells, %d columns", serpent.line(heads), #ov.children, ov.column_count))
    check("screening table filled", #pn.pages.screening.grid_scroll.overview.children >= 6 * (1 + 1 + 15),
      #pn.pages.screening.grid_scroll.overview.children)
    pn.pages.selected_tab_index = 2
    -- (0.70) The Dose-response table: as many cells per row as headers (0.67 to 0.69: rows slid by one).
    local dt = pn.pages.dose.detail_scroll.detail
    local heads = 0
    for i = 1, dt.column_count do
      local c = dt.children[i] and dt.children[i].caption
      if type(c) == "table" or c == "" then heads = heads + 1 end
    end
    local control = dt.children[dt.column_count + 1] and dt.children[dt.column_count + 1].caption
    check("the Dose-response table's rows line up under its headers",
      #dt.children % dt.column_count == 0 and type(control) == "table" and control[1] == "es.control",
      string.format("%d cells, %d columns, first row starts %s", #dt.children, dt.column_count, serpent.line(control)))
    storage.views = 0
    -- Drive every target x additive x model through the same code the drop-downs use.
    for ti = 1, 3 do
      for _, an in ipairs({"coal", "stone", "copper-cable", "sulfur", "lubricant"}) do
        local ai = A(player, an)
        for mi = 1, 5 do  -- Automatic and the four models
          es("gui_set", player.index, {target = ti, additive = ai, model = mi})
          storage.views = storage.views + 1
        end
      end
    end
    check("all views rendered", storage.views == 75, storage.views)
    es("gui_set", player.index, {target = 1, mix_a = A(player, "coal"), mix_b = A(player, "stone")})
    check("mixtures tab lists tested mixtures", #pn.pages.mixtures.tested_scroll.tested.children >= 5 * 5,
      #pn.pages.mixtures.tested_scroll.tested.children)
    check("mixtures heat map drawn", es("chart_objects_mix", player.index) > 100, es("chart_objects_mix", player.index))
    es("gui_set", player.index, {target = 1, additive = A(player, "stone"), model = 1})
    pn = panel(player)
    check("fit line shows a fit for stone", pn.pages.dose.fit.line1.caption ~= "", serpent.line(pn.pages.dose.fit.line1.caption))
    check("chart has render objects", es("chart_objects", player.index) > 20, es("chart_objects", player.index))
    check("detail table filled", #pn.pages.dose.detail_scroll.detail.children > 6, #pn.pages.dose.detail_scroll.detail.children)
    -- Screenshots with the GUI, for a human (or Claude) to look at: current zoom, then zoom 1.
    storage.camera_zoom = pn.pages.dose.chart.zoom
    table.insert(lines, string.format("INFO display_scale %.2f, camera zoom %.2f, resolution %dx%d",
      player.display_scale, pn.pages.dose.chart.zoom, player.display_resolution.width, player.display_resolution.height))
    check("drop-downs show the selection", pn.pages.dose.head.additive.selected_index == 3
      and pn.top.target.selected_index == 1, pn.pages.dose.head.additive.selected_index)
    shot(player, "es-panel-gear.png")
    return
  elseif p == 1865 then
    panel(player).pages.selected_tab_index = 1
    shot(player, "es-panel-screening.png")
  elseif p == 1870 then
    -- Its own moment: a screenshot is taken at the end of the tick, after any later tab switch.
    panel(player).pages.selected_tab_index = 3
    shot(player, "es-panel-mixtures.png")
  elseif p == 1880 then
    panel(player).pages.selected_tab_index = 2
  elseif p == 1900 then
    local pn = panel(player)
    -- Second view: the engine target, to see another chart and the target drop-down.
    es("gui_set", player.index, {target = 3, additive = A(player, "coal"), model = 2})
    shot(player, "es-panel-engine.png")
  elseif p == 1910 then
    -- The effect selector: gears, stone, speed; the chart and fit follow.
    es("gui_set", player.index, {target = 1, additive = A(player, "stone"), model = 1, effect = 2})
    local pn = panel(player)
    check("effect selector switches the dose-response view to speed", pn.pages.dose.head.effect.selected_index == 2
      and pn.pages.mixtures.head.effect.selected_index == 2 and es("chart_objects", player.index) > 10,
      pn.pages.dose.head.effect.selected_index)
    shot(player, "es-panel-speed.png")
  elseif p == 1914 then
    -- The full cost view (0.44): the price row shows, the chart and fit follow, a preset can be chosen.
    local fullcost = 0
    for i, v in ipairs(es("gui_views")) do if v == "fullcost" then fullcost = i end end
    es("gui_set", player.index, {target = 1, additive = A(player, "stone"), model = 1, effect = fullcost})
    local pn = panel(player)
    check("the full cost view shows prices, a chart and a fit", pn.pages.dose.prices.visible
      and pn.pages.dose.head.effect.selected_index == fullcost and pn.pages.mixtures.head.effect.selected_index == 1
      and es("chart_objects", player.index) > 10 and pn.pages.dose.fit.line1.caption ~= "",
      serpent.line(pn.pages.dose.fit.line1.caption))
    shot(player, "es-panel-fullcost.png")
    -- Prices by planet (0.50): on Vulcanus pollution is not priced, and the row says so.
    if prototypes.space_location.vulcanus then es("set_view_surface", player.index, "vulcanus") end
  elseif p == 1915 then
    -- A screenshot shows the GUI a tick or more after it is requested: requested here, between the
    -- change (1914) and the next step's changes.
    if prototypes.space_location.vulcanus then
      shot(player, "es-panel-fullcost-vulcanus.png")
    end
  elseif p == 1917 then
    -- Prices by planet (0.50), a tick later so the screenshot shows what a player sees.
    if prototypes.space_location.vulcanus then
      local note = panel(player).pages.dose.price_note
      check("the price row says what the planet changes (Vulcanus: no pollution price), on its own line",
        note.visible and type(note.caption) == "table"
          and serpent.line(note.caption):find("es.price-no-pollution", 1, true) ~= nil, serpent.line(note.caption))
    end
  elseif p == 1920 then
    if prototypes.space_location.vulcanus then es("set_view_surface", player.index, "nauvis") end
    es("gui_set", player.index, {effect = 1})
    local grid = panel(player).pages.screening.grid_scroll.overview
    -- (0.68 added a Dose column at 4: the effects start at 5.)
    check("screening grid has yield, speed and pollution columns", grid.children[5].caption[1] == "es.col-yield"
      and grid.children[7].caption[1] == "es.col-pollution", serpent.line(grid.children[5].caption))
    -- The control row's efficiency cell (column 8) holds a value once samples carry one.
    local ef_cell = grid.children[grid.column_count + 8]
    check("screening shows the control's efficiency", grid.children[8].caption[1] == "es.col-efficiency"
      and ef_cell.caption ~= "–", serpent.line(ef_cell.caption))
  elseif p == 1940 then
    player.opened = nil
    check("the screen closes like a window", player.gui.screen.es_science == nil)
    -- A hopper's window (0.49): the "Report to circuit" checkbox, showing whether it reports.
    local s = game.surfaces.nauvis
    -- The checkbox comes with Circuit dosing 1 (staged reveal).
    game.forces.player.technologies["es-circuit-instrumentation-1"].researched = true
    -- Within the player's reach (a window out of reach does not open).
    local at = s.find_non_colliding_position("es-hopper", {player.position.x + 2, player.position.y + 2}, 6, 1, true)
    local h = s.create_entity{name = "es-hopper", position = at, force = "player", raise_built = true}
    es("hopper_report_set", h.unit_number, true)
    -- (0.71) A fluid hopper's window: its side panel has the fluid line, beside the tank's own window.
    local fat = s.find_non_colliding_position("es-fluid-hopper", {player.position.x - 2, player.position.y + 2}, 6, 1, true)
    local fh = s.create_entity{name = "es-fluid-hopper", position = fat, force = "player", raise_built = true}
    fh.insert_fluid{name = "lubricant", amount = 50, temperature = 25}
    player.opened = fh
    local ff = player.gui.relative.es_hopper
    check("a fluid hopper's side panel has its fluid line", ff and ff.fluid ~= nil,
      ff and ff.fluid and serpent.line(ff.fluid.caption) or ("no panel; opened " .. tostring(player.opened and player.opened.name)))
    player.opened = nil
    player.opened = h
    local f = player.gui.relative.es_hopper
    check("a hopper's side panel has no fluid line (it takes items)", f and f.fluid == nil,
      f and f.fluid and serpent.line(f.fluid.caption) or "")
    check("a hopper's window has the report checkbox, ticked when it reports", f and f.report and f.report.state == true,
      f and tostring(f.report and f.report.state) or ("no frame; opened " .. tostring(player.opened and player.opened.name)
        .. ", reach " .. tostring(player.can_reach_entity(h))))
    shot(player, "es-hopper.png")
    player.opened = nil
    player.opened = storage.dosebench
  elseif p == 1980 then
    local f = player.gui.relative.es_dose
    check("dose panel opens on a test bench", f ~= nil)
    if f then
      local rows = f.panel.rows
      check("dose panel shows the bench's rows as icons and doses", rows.slot_1.sprite == "fluid/lubricant"
        and rows.amount_1.text == "37" and rows.slot_2.sprite == "item/stone" and rows.limit_1.caption[2] == "100",
        rows.slot_1.sprite .. " " .. rows.amount_1.text .. " / " .. rows.slot_2.sprite .. " " .. serpent.line(rows.limit_1.caption))
      -- Every additive but the catalysts (hidden until discovered), premixes (until unlocked) and quality
      -- agents (until researched), plus "no additive".
      local shown = 1
      for _, a in ipairs(shared.additives) do if not a.refined_from and not a.premix_of then shown = shown + 1 end end
      storage.picker_base = shown
      check("dose picker hides undiscovered catalysts", #f.panel.picker.grid.children == shown,
        string.format("%d icons, %d expected", #f.panel.picker.grid.children, shown))
      check("dose panel says what the bench tests", f.panel.making.caption[1] == "es.dose-testing",
        serpent.line(f.panel.making.caption))
      -- (Two: the fluid hopper on its right and the hopper below it.)
      check("dose panel counts the hoppers touching the bench", tonumber(f.panel.status.caption[2]) == 2, serpent.line(f.panel.status.caption))
      -- Picking from the grid fills the third row.
      es("dose_panel_pick", player.index, 3, "coal")
      local d = es("dose_state", storage.dosebench.unit_number)
      check("picking an icon sets a row (dose 1 to start)", d.mix and d.mix.coal == 1 and f.panel.rows.slot_3.sprite == "item/coal",
        serpent.line(d.mix))
    end
    shot(player, "es-dose-bench.png")
    -- Removing a row: right-click clears it and the rows below move up; clearing
    -- through the picker's "no additive" does the same.
    local f = player.gui.relative.es_dose
    if f then
      local function sprites()
        local r = f.panel.rows
        return {r.slot_1.sprite, r.slot_2.sprite, r.slot_3.sprite}
      end
      local before = sprites()
      es("dose_panel_click", player.index, 1, "right")
      local after = sprites()
      local d = es("dose_state", storage.dosebench.unit_number)
      check("right-click removes a row and the rows below move up",
        after[1] == before[2] and after[2] == before[3] and (after[3] or "") == "" and d.mix
        and not d.mix[before[1]:match("/(.+)$")], serpent.line({before = before, after = after, mix = d.mix}))
      es("dose_panel_pick", player.index, 1, "")
      local again = sprites()
      check("clearing a row in the picker moves the rows below up too",
        again[1] == after[2] and (again[2] or "") == "", serpent.line(again))
    end
  elseif p == 2000 then
    -- A discovery while playing: the panel lists the refined catalyst once reopened.
    player.opened = nil
    game.forces.player.recipes["es-refine-coal"].enabled = true
    player.opened = storage.dosebench
    local f = player.gui.relative.es_dose
    check("dose picker shows a discovered catalyst", f and #f.panel.picker.grid.children == storage.picker_base + 1,
      f and #f.panel.picker.grid.children)
    -- A preset fills the rows (preset 1: coal 4 + stone 2).
    es("dose_panel_preset", player.index, 2)
    local d = es("dose_state", storage.dosebench.unit_number)
    check("choosing a preset sets the rows", d.mix and d.mix.coal == 4 and d.mix.stone == 2 and not d.mix.lubricant,
      serpent.line(d.mix))
  elseif p == 2020 then
    player.opened = nil
    check("dose panel closes", player.gui.relative.es_dose == nil)
    game.take_screenshot{surface = game.surfaces.nauvis, position = {2, 5}, resolution = {1500, 950}, zoom = 1.2,
      show_gui = false, show_entity_info = false, path = "es-lineup.png"}
    -- 0.63: the hoppers up close (0.71: the dosed bench's piped fluid hopper and the hopper below it).
    game.take_screenshot{surface = game.surfaces.nauvis, position = {9, 1.5}, resolution = {900, 700}, zoom = 2.5,
      show_gui = false, show_entity_info = false, path = "es-hoppers.png"}
    -- 0.67: the same lineup in alt mode (each bench's and machine's dose, greyed when starved).
    game.take_screenshot{surface = game.surfaces.nauvis, position = {2, 5}, resolution = {1500, 950}, zoom = 1.2,
      show_gui = false, show_entity_info = true, path = "es-lineup-alt.png"}
    -- Opening needs reach: stand next to the assembler first.
    player.teleport({storage.assembler.position.x, storage.assembler.position.y - 4})
    player.opened = storage.assembler
  elseif p == 2060 then
    local f = player.gui.relative.es_dose
    check("dose panel opens on an assembler", f ~= nil)
    if f then check("dose panel says what the assembler makes", f.panel.making.caption[1] == "es.dose-making",
      serpent.line(f.panel.making.caption)) end
    shot(player, "es-dose-assembler.png")
  elseif p == 2100 then
    player.opened = nil
    es("open_science", player.index)
  elseif p == 2110 then
    -- Sulfur was tested at 2 and 5: its save choices are those, plus maybe the fitted optimum; never the
    -- 1-9 of a tier 1 item.
    es("gui_set", player.index, {target = 1, additive = A(player, "sulfur")})
    storage.adopt_items = #panel(player).pages.dose.adopt.dose.items
    check("save choices for an oil-era additive are its tested doses", storage.adopt_items >= 2
      and storage.adopt_items <= 3, storage.adopt_items)
    player.opened = nil
  elseif p == 2120 then
    es("open_science", player.index)
  elseif p == 2130 then
    check("save choices survive reopening the panel", #panel(player).pages.dose.adopt.dose.items == storage.adopt_items,
      #panel(player).pages.dose.adopt.dose.items .. " vs " .. storage.adopt_items)
    -- A discovery while the panel is open: the additive drop-downs grow with the visible list.
    game.forces.player.recipes["es-refine-wood"].enabled = true
    es("gui_set", player.index, {target = 1})
    local pn = panel(player)
    local visible = 0
    for _, a in pairs(prototypes.item) do
      if a.name:find("^es%-refined%-") and game.forces.player.recipes["es-refine-" .. a.name:sub(12)].enabled then
        visible = visible + 1
      end
    end
    local expected = storage.picker_base - 1 + visible  -- additives always shown, plus discovered catalysts
    check("drop-downs grow when a catalyst is discovered with the panel open",
      #pn.pages.dose.head.additive.items == expected and #pn.pages.mixtures.head.mix_a.items == expected,
      string.format("%d and %d items, %d expected", #pn.pages.dose.head.additive.items,
        #pn.pages.mixtures.head.mix_a.items, expected))
  elseif p == 2140 then
    -- A premix unlocked (a blend and a slurry): listed with the additives, its phase as its family.
    local blend, slurry
    for name, r in pairs(prototypes.recipe) do
      if name:find("^es%-premix%-") and not name:find("%-v$") then
        if r.category == "crafting" then blend = blend or name elseif r.category == "chemistry" then slurry = slurry or name end
      end
    end
    local before = #panel(player).pages.dose.head.additive.items
    game.forces.player.recipes[blend].enabled = true
    game.forces.player.recipes[slurry].enabled = true
    es("gui_set", player.index, {target = 1})
    local pn = panel(player)
    check("drop-downs list unlocked premixes", #pn.pages.dose.head.additive.items == before + 2,
      string.format("%d -> %d (%s, %s)", before, #pn.pages.dose.head.additive.items, blend, slurry))
    local phases = {}
    for _, c in ipairs(pn.pages.screening.grid_scroll.overview.children) do
      if type(c.caption) == "table" and (c.caption[1] == "es.family-blend" or c.caption[1] == "es.family-slurry") then
        phases[c.caption[1]] = true
      end
    end
    check("screening shows a premix's phase as its family", phases["es.family-blend"] and phases["es.family-slurry"],
      serpent.line(phases))
    pn.pages.selected_tab_index = 1
    shot(player, "es-panel-premix.png")
  elseif p == 2150 then
    -- Presets tab: the preset saved at setup, with a delete button (by name: 0.70's Coverage tab moved the
    -- positions, and 4 had been Theory's since 0.53).
    local pn = panel(player)
    for i, t in ipairs(pn.pages.tabs) do if t.tab.name == "tab_presets" then pn.pages.selected_tab_index = i end end
    es("gui_set", player.index, {target = 1})
  elseif p == 2160 then
    -- 0.70: the Coverage tab: per target, samples, additives tested of those on offer, verdicts, families.
    local pn = panel(player)
    local idx
    for i, t in ipairs(pn.pages.tabs) do if t.tab.name == "tab_coverage" then idx = i end end
    pn.pages.selected_tab_index = idx
    es("gui_set", player.index, {})  -- (a refresh, as the tab's own event does)
    local cov = panel(player).pages.coverage
    local tbl = cov.scroll.body.coverage
    local sum = cov.summary.caption
    local gear_tested
    for i = 1, #tbl.children - 5 do
      local c = tbl.children[i].caption
      if type(c) == "table" and serpent.line(c):find("iron-gear-wheel", 1, true) then
        local t = tbl.children[i + 2].caption
        local n = type(t) == "table" and tonumber(t[2])
        if n and (not gear_tested or n > gear_tested) then gear_tested = n end  -- (routes of gears match too)
      end
    end
    -- (0.72) The column of what a settled question pays; every row full.
    local heads = {}
    for i = 1, tbl.column_count do local c = tbl.children[i].caption; heads[i] = type(c) == "table" and c[1] or c end
    check("Coverage has the When settled column and every row is full",
      heads[6] == "es.cov-settled" and #tbl.children % tbl.column_count == 0,
      string.format("heads %s; %d cells, %d columns", serpent.line(heads), #tbl.children, tbl.column_count))
    check("the Coverage tab counts samples and tested additives per target, the Target row hidden",
      type(sum) == "table" and sum[1] == "es.cov-summary" and gear_tested and gear_tested >= 2
        and panel(player).top.target.visible == false,
      serpent.line({summary = sum, gear_tested = gear_tested}))
  elseif p == 2165 then
    shot(player, "es-panel-coverage.png")
  elseif p == 2168 then
    -- Back to Presets for its check and screenshot.
    local pn = panel(player)
    for i, t in ipairs(pn.pages.tabs) do if t.tab.name == "tab_presets" then pn.pages.selected_tab_index = i end end
    es("gui_set", player.index, {})
  elseif p == 2170 then
    local pre = panel(player).pages.presets
    local rows = (#pre.list_scroll.list.children - 4) / 4
    check("presets tab lists the saved presets", rows == #remote.call("empirical-science", "presets", "player"), rows)
    shot(player, "es-panel-presets.png")
  elseif p == 2175 then
    -- 0.59: the Theory tab (shape columns), world strength in the summary, freshness absent on gears.
    local pn = panel(player)
    local idx
    for i, t in ipairs(pn.pages.tabs) do if t.tab.name == "tab_theory" then idx = i end end
    pn.pages.selected_tab_index = idx
    local fams = pn.pages.theory.families
    local heads = {}
    for i = 1, math.min(8, #fams.children) do
      local c = fams.children[i].caption
      heads[i] = type(c) == "table" and c[1] or c
    end
    check("the Theory tab shows its families table with three shape columns", pn.pages.tab_theory.visible
      and fams.column_count == 8 and heads[6] == "es.theory-col-shape" and heads[8] == "es.theory-col-shape",
      serpent.line(heads))
    check("the summary line names the world strength",
      serpent.line(pn.summary.caption):find("es-world-strength-", 1, true) ~= nil, serpent.line(pn.summary.caption))
    es("gui_set", player.index, {target = 1})
    local grid = pn.pages.screening.grid_scroll.overview
    local fresh = false
    for i = 1, grid.column_count do
      local c = grid.children[i].caption
      if type(c) == "table" and c[1] == "es.col-freshness" then fresh = true end
    end
    check("the Screening grid has no freshness column on a target that does not spoil", not fresh)
  elseif p == 2178 then
    -- 0.70: the Theory tab reads one effect at a time; speed refits on the speed evidence.
    local pn = panel(player)
    local idx
    for i, t in ipairs(pn.pages.tabs) do if t.tab.name == "tab_theory" then idx = i end end
    pn.pages.selected_tab_index = idx
    es("gui_set", player.index, {theory_effect = 2})
    local th = panel(player).pages.theory
    local fit = th.fit.caption
    fit = type(fit) == "table" and fit[1] or fit
    check("the Theory tab's effect selector switches to speed and refits",
      th.head.effect.selected_index == 2 and (fit == "es.theory-fit" or fit == "es.theory-none"),
      string.format("selected %d, %s", th.head.effect.selected_index, tostring(fit)))
    local top = panel(player).top
    check("the Theory tab hides the Target row (it does not depend on the target); Planet stays",
      top.target.visible == false and top.target_label.visible == false and top.surface.visible ~= false
        and panel(player).foot.visible == false)
    -- (0.72) Where to look next: no prediction wider than ±50%, or one line saying there are none.
    local nxt = th.next_scroll.next
    local widest, rows, none = 0, 0, false
    for _, c in ipairs(nxt.children) do
      local cap = c.caption
      if type(cap) == "table" and cap[1] == "es.theory-cell" then
        rows = rows + 1
        widest = math.max(widest, tonumber((cap[4]:gsub("%%", ""))) - tonumber((cap[3]:gsub("%%", ""))))
      elseif type(cap) == "table" and cap[1] == "es.theory-next-none" then none = true end
    end
    check("Where to look next shows no prediction wider than ±50%, or says there is none",
      (rows > 0 and widest <= 100 and not none) or (rows == 0 and none),
      string.format("%d rows, widest %.1f points, none line %s", rows, widest, tostring(none)))
  elseif p == 2180 then
    shot(player, "es-panel-theory.png")
  elseif p == 2182 then
    -- 0.61-0.62: a fluid's band list spans the axis; "All temperatures" fits over it, below zero included;
    -- a living additive's list is ripeness bands.
    local pn = panel(player)
    pn.pages.selected_tab_index = 2
    es("gui_set", player.index, {target = 1})
    check("Dose-response shows the Target row again", panel(player).top.target.visible == true)
    local vis = {}
    for i, n in ipairs(remote.call("empirical-science", "visible_names", player.index)) do vis[n] = i end
    es("gui_set", player.index, {additive = vis["lubricant"]})
    local head = pn.pages.dose.head
    local n_temp = #head.temp.items
    es("gui_set", player.index, {temp_band = n_temp})  -- the last entry: all temperatures
    local line1 = pn.pages.dose.fit.line1.caption
    check("a fluid's bands span the temperature axis; the temperature view fits over them, below zero too",
      n_temp == #shared.all_bands() + 1 and type(line1) == "table" and line1[1] == "es.temp-view" and tonumber(line1[2]) >= 3,
      string.format("%d bands; %s", n_temp, serpent.line(line1)))
    storage.ripe_ok = vis["yumako-mash"] ~= nil
    if storage.ripe_ok then
      es("gui_set", player.index, {additive = vis["yumako-mash"]})
      check("a living additive's bands are ripeness bands", #head.temp.items == shared.ripe.bands + 1
        and head.temp_label.caption[1] == "es.ripe", string.format("%d items, %s", #head.temp.items,
          serpent.line(head.temp_label.caption)))
    end
  elseif p == 2184 then
    local vis = {}
    for i, n in ipairs(remote.call("empirical-science", "visible_names", player.index)) do vis[n] = i end
    es("gui_set", player.index, {additive = vis["lubricant"]})
    es("gui_set", player.index, {temp_band = #panel(player).pages.dose.head.temp.items})
  elseif p == 2186 then
    shot(player, "es-panel-temperature.png")
  elseif p == 2187 then
    -- 0.62: the grid scrolls, sorts and filters. All rows, then tested only; sorted by samples, the first
    -- additive row has the most samples.
    local pn = panel(player)
    pn.pages.selected_tab_index = 1
    es("gui_set", player.index, {target = 1, screen_show = 1, screen_sort = 1})
    local grid = pn.pages.screening.grid_scroll.overview
    local all_rows = #grid.children / grid.column_count
    es("gui_set", player.index, {screen_show = 2, screen_sort = 3})
    grid = pn.pages.screening.grid_scroll.overview
    local tested_rows = #grid.children / grid.column_count
    local n_first = tonumber(grid.children[2 * grid.column_count + 3].caption) or -1
    local n_second = tonumber(grid.children[3 * grid.column_count + 3] and grid.children[3 * grid.column_count + 3].caption) or -1
    check("the Screening grid scrolls, shows tested additives only, and sorts by samples",
      pn.pages.screening.grid_scroll.type == "scroll-pane" and tested_rows < all_rows and n_first >= n_second and n_first > 0,
      string.format("%d rows, %d tested; first two by samples %d, %d", all_rows, tested_rows, n_first, n_second))
  elseif p == 2188 then
    shot(player, "es-panel-screening-sorted.png")
  elseif p == 2189 then
    es("gui_set", player.index, {screen_show = 1, screen_sort = 1})
  elseif p == 2190 then
    -- Staged reveal: the same screen and panel with nothing staged researched (a new game).
    player.opened = nil
    for _, t in ipairs({"es-mixtures", "es-thermal-studies", "es-precision-instruments-1",
                        "es-circuit-instrumentation-1", "es-theory"}) do
      game.forces.player.technologies[t].researched = false
    end
  elseif p == 2200 then
    es("open_science", player.index)
  elseif p == 2215 then
    local pn = panel(player)
    if pn then
      pn.pages.selected_tab_index = 1
      local head5 = pn.pages.screening.grid_scroll.overview.children[6]  -- (after 0.68's Dose column)
      check("before their stage: Mixtures tab and the effect selector hidden",
        pn.pages.tab_mixtures == nil and pn.pages.dose.head.effect.visible == false,
        string.format("mixtures tab %s, effect %s", tostring(pn.pages.tab_mixtures ~= nil),
          tostring(pn.pages.dose.head.effect.visible)))
      -- (0.70) Researched, Mixtures joins the panel (rebuilt, on the same tab); unresearched, it leaves.
      local mt = game.forces.player.technologies["es-mixtures"]
      mt.researched = true
      es("gui_set", player.index, {})
      local joined = panel(player).pages.tab_mixtures ~= nil and panel(player).pages.selected_tab_index == 1
      mt.researched = false
      es("gui_set", player.index, {})
      check("Mixtures joins the panel when researched and leaves when not, the tab kept",
        joined and panel(player).pages.tab_mixtures == nil,
        string.format("joined %s, left %s", tostring(joined), tostring(panel(player).pages.tab_mixtures == nil)))
      pn = panel(player)
      head5 = pn.pages.screening.grid_scroll.overview.children[6]  -- (the rebuild replaced the grid)
      local note = pn.pages.screening.mixnote.caption
      check("before Mixtures: the mixtures note says where its results will show",
        note == "" or note[1] == "es.mix-note-locked", serpent.line(note))
      check("before Precision instruments 1: one grey column for the later measurements, saying why",
        head5.caption[1] == "es.col-side-effects" and head5.tooltip and head5.tooltip[1] == "es.side-unmeasured",
        serpent.line(head5.caption))
      shot(player, "es-panel-staged.png")
    else
      check("the screen reopens with nothing staged", false)
    end
  elseif p == 2230 then
    player.opened = nil
    player.opened = storage.dosebench
  elseif p == 2245 then
    local f = player.gui.relative.es_dose
    local st = f and f.panel.status.caption
    check("before Mixtures: a set second row stays visible and the panel says it waits; no circuit checkbox",
      f ~= nil and f.panel.rows.slot_2.visible and not f.panel.rows.slot_3.visible
        and not f.panel.from_circuit.visible and st[4] and st[4][1] == "es.dose-needs-mixtures",
      st and serpent.line(st))
    shot(player, "es-dose-staged.png")
  elseif p == 2262 and game.forces.player.technologies["es-quality-additives"] then
    -- A quality agent dosed (with the quality mod): the panel says products may come out a tier up.
    player.opened = nil
    game.forces.player.technologies["es-quality-additives"].researched = true
    remote.call("empirical-science", "set_dose", storage.dosebench.unit_number, {rows = {{name = "uranium-235", dose = 3}}})
    player.opened = storage.dosebench
  elseif p == 2270 and game.forces.player.technologies["es-quality-additives"] then
    local f = player.gui.relative.es_dose
    local st = f and f.panel.status.caption
    check("a dose panel with a quality agent says products may come out a tier up",
      st and st[4] and st[4][1] == "es.dose-agent", st and serpent.line(st))
    shot(player, "es-dose-agent.png")
  elseif p == 2280 then
    -- The answer key (debug): opens, lists the best forty additives of a target, re-sorts.
    player.opened = nil
    es("open_answer_key", player.index)
    local f = player.gui.screen.es_answer_key
    local rows = f and f.ak_tabs.target_page.scroll.rows
    local n1 = rows and #rows.children or 0
    es("answer_key_select", player.index, "ak-sort", 2)
    local n2 = rows and rows.valid and #rows.children or 0
    check("the answer key opens with a target's table and re-sorts", f ~= nil and n1 == 16 * 41 and n2 == n1,
      string.format("%d then %d cells", n1, n2))
    shot(player, "es-answer-key.png")
  elseif p == 2284 then
    -- 0.66: the Dossiers tab (each reached planet's quota and the exceptional set) and the summary window.
    if player.gui.screen.es_answer_key then player.gui.screen.es_answer_key.destroy() end
    es("open_science", player.index)
    local pn = panel(player)
    local idx
    for i, t in ipairs(pn.pages.tabs) do if t.tab.name == "tab_dossiers" then idx = i end end
    pn.pages.selected_tab_index = idx
    es("gui_set", player.index, {target = 1})  -- (refreshes the panel)
    local body = pn.pages.dossiers.scroll.body
    check("the Dossiers tab lists Nauvis's targets and the exceptional set",
      idx ~= nil and body.planet_nauvis ~= nil and body.exceptional ~= nil
        and #body.exceptional.children == 5 * 7,
      string.format("tab %s, nauvis %s, exceptional cells %s", tostring(idx), tostring(body.planet_nauvis ~= nil),
        tostring(body.exceptional and #body.exceptional.children)))
  elseif p == 2286 then
    shot(player, "es-panel-dossiers.png")
    -- (0.70) The tab strip as the engine holds it: each tab's caption and visibility, in order.
    local strip = {}
    for i, t in ipairs(panel(player).pages.tabs) do
      local c = t.tab.caption
      table.insert(strip, string.format("%d %s %s", i, type(c) == "table" and c[1] or tostring(c), tostring(t.tab.visible)))
    end
    check("the tab strip holds every tab in order (diagnostic)", true, table.concat(strip, "; ")
      .. "; selected " .. tostring(panel(player).pages.selected_tab_index))
  elseif p == 2287 then
    player.opened = nil
    es("dossier_summary_open", player.index)
    check("the dossier summary opens", player.gui.screen.es_dossier_summary ~= nil)
  elseif p == 2289 then
    shot(player, "es-dossier-summary.png")
  elseif p == 2290 then
    if player.gui.screen.es_answer_key then player.gui.screen.es_answer_key.destroy() end
    if player.gui.screen.es_dossier_summary then player.gui.screen.es_dossier_summary.destroy() end
    -- 0.72: the Progress tab, on a made-up history of 24 snapshots (this run is too short to record any).
    es("progress_seed", "player", 24)
    es("open_science", player.index)
    local pn = panel(player)
    for i, t in ipairs(pn.pages.tabs) do if t.tab.name == "tab_progress" then pn.pages.selected_tab_index = i end end
    es("gui_set", player.index, {})
  elseif p == 2292 then
    local pn = panel(player)
    local pg = pn and pn.pages.progress
    local drawn = es("chart_objects_progress", player.index)
    check("the Progress tab draws its graph, with a legend by science pack and the findings checkbox",
      pg ~= nil and drawn > 20 and pg.legend.visible and pg.head.marks.state == true and #pg.head.graph.items == 7,
      string.format("%d objects drawn", drawn))
    shot(player, "es-panel-progress.png")
  elseif p == 2294 then
    -- (0.72) The empirical science pack sits beside vanilla's packs in an endless technology's cost.
    player.opened = nil
    local tech
    for _, t in pairs(player.force.technologies) do
      if t.prototype.max_level >= 4294967295 then  -- (an endless technology's top level, as the engine gives it)
        local has_es, has_prod = false, false
        for _, ing in ipairs(t.research_unit_ingredients) do
          if ing.name == "es-research-data" then has_es = true end
          if ing.name == "production-science-pack" then has_prod = true end
        end
        if has_es and has_prod and (not tech or t.name < tech.name) then tech = t end
      end
    end
    check("an endless technology lists empirical science packs beside production science", tech ~= nil, tech and tech.name)
    -- (No screenshot: the technology screen does not show in game.take_screenshot, seen 2026-10-09.)
  elseif p == 2299 then
    table.insert(lines, failed == 0 and "DONE ALL PASSED" or ("DONE " .. failed .. " FAILED"))
    helpers.write_file(OUT, table.concat(lines, "\n") .. "\n")
  end
end)
