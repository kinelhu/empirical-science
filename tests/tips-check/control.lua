-- The circuit tips' scenes as a Tips window runs them (0.72): with no mod but this one and its library, so
-- no Space Age, no Quality, and no test hooks. The headless test runs them with Space Age, and missed a scene
-- whose blueprint only fitted a Space Age station; this check, named "es-tips-check" at first, switched the
-- test hooks on (any mod named "es-..." does), and missed a scene that called one (the
-- Station port tip showed an error). Judged as a player sees it: the machine made something, and its hopper's
-- additive was used.
local shared_pack = "automation-science-pack"
local KEYS = {"dose_signal", "dose_sweep", "adopt_best", "first_experiment", "samples", "production", "residues", "fluid_hoppers"}

script.on_init(function()
  storage.scenes, storage.errors = {}, {}
  for _, t in pairs(game.forces.player.technologies) do t.researched = true end
  for _, key in ipairs(KEYS) do
    local s = game.create_surface("tip-" .. key)
    s.request_to_generate_chunks({0, 0}, 1); s.force_generate_chunk_requests()
    -- (A tip's simulation map is bare lab floor: no trees, rocks or water.)
    for _, e in pairs(s.find_entities_filtered{area = {{-30, -30}, {30, 30}}}) do e.destroy() end
    local tiles = {}
    for x = -30, 29 do for y = -30, 29 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
    s.set_tiles(tiles)
    -- As data.lua's scene init: power, then the scene's own build.
    local eei = s.create_entity{name = "electric-energy-interface", position = {-12, -8}, force = "player"}
    eei.power_production, eei.electric_buffer_size = 1e8, 1e8
    s.create_entity{name = "substation", position = {-6, -6}, force = "player"}
    s.create_entity{name = "substation", position = {6, -6}, force = "player"}
    local ok, err = pcall(remote.call, "empirical-science-scenes", "build_scene", key, s.name)
    storage.scenes[key] = s.name
    if not ok then storage.errors[key] = tostring(err) end
  end
end)

script.on_event(defines.events.on_tick, function(event)
  -- The dose-signal tip's update.
  if storage.scenes then remote.call("empirical-science-scenes", "scene_tick", storage.scenes.dose_signal, event.tick) end
end)

script.on_nth_tick(7200, function(event)
  if event.tick == 0 or storage.done then return end  -- (an nth-tick handler also fires on tick 0)
  storage.done = true
  local lines, failed = {}, 0
  for _, key in ipairs(KEYS) do
    local s = game.surfaces[storage.scenes[key]]
    local ok, detail
    local function count(name, item)
      local n = 0
      for _, e in pairs(s.find_entities_filtered{name = name}) do
        n = n + e.get_inventory(defines.inventory.chest).get_item_count(item)
      end
      return n
    end
    if key == "samples" then
      local packs = count("es-analysis-station", "es-research-data")
      local st = s.find_entities_filtered{name = "es-analysis-station"}[1]
      local b = s.find_entities_filtered{name = "es-test-bench"}[1]
      local waiting = 0
      for _, it in pairs(st and st.get_inventory(defines.inventory.chest).get_contents() or {}) do
        if it.name:find("^es%-sample") then waiting = waiting + it.count end
      end
      local red = st and st.get_inventory(defines.inventory.chest).get_item_count(shared_pack) or -1
      -- (A first reading earns less than one whole pack: judged by the samples it took.)
      local passed = 0
      for _, c in pairs(s.find_entities_filtered{name = "infinity-chest"}) do
        for _, it in pairs(c.get_inventory(defines.inventory.chest).get_contents()) do
          if it.name:find("^es%-sample") then passed = passed + it.count end
        end
      end
      local trials = b and b.products_finished or 0
      local read = trials - waiting - passed
      local ports = #s.find_entities_filtered{name = "es-station-port"}
      ok, detail = trials >= 2 and read >= 1, string.format("samples made %d, read %d, waiting %d, passed by %d; packs %d, red packs %d; ports %d",
        trials, read, waiting, passed, packs, red, ports)
    elseif key == "residues" then
      local r = count("wooden-chest", "es-spent-coal")
      local m = s.find_entities_filtered{name = "assembling-machine-2"}[1]
      local trash = m and m.get_inventory(defines.inventory.assembling_machine_trash)
      local sink = s.find_entities_filtered{name = "infinity-chest"}
      local in_sink = 0
      for _, c in pairs(sink) do in_sink = in_sink + c.get_inventory(defines.inventory.chest).get_item_count("es-spent-coal") end
      ok, detail = r > 0, string.format("residue sorted %d, in the machine's trash %d, past the sorter %d, made %d", r,
        trash and trash.get_item_count("es-spent-coal") or -1, in_sink, m and m.products_finished or -1)
    elseif key == "fluid_hoppers" then
      local fh = s.find_entities_filtered{name = "es-fluid-hopper"}[1]
      local f = fh and fh.fluidbox[1]
      local made = 0
      for _, m in pairs(s.find_entities_filtered{name = "assembling-machine-2"}) do made = made + m.products_finished end
      ok, detail = f ~= nil and f.name == "lubricant" and made > 0, string.format("hopper %s, made %d", f and f.name or "empty", made)
    else
      local m = s.find_entities_filtered{name = key == "adopt_best" and "assembling-machine-2"
        or (key == "production" and "assembling-machine-2") or "es-test-bench"}[1]
      local h = s.find_entities_filtered{name = "es-hopper"}[1]
      local left = h and h.get_inventory(defines.inventory.chest).get_item_count() or -1
      local given = key == "adopt_best" and 100 or 50  -- (what build_scene puts in the hopper)
      ok = m and h and m.products_finished > 0 and left < given
      detail = string.format("made %d, hopper %d of %d left", m and m.products_finished or -1, left, given)
    end
    ok = ok and not storage.errors[key]
    if not ok then failed = failed + 1 end
    table.insert(lines, (ok and "PASS " or "FAIL ") .. key .. "  " .. (storage.errors[key]
      or detail))
  end
  table.insert(lines, failed == 0 and "DONE ALL PASSED" or ("DONE " .. failed .. " FAILED"))
  helpers.write_file("es-tips-check.txt", table.concat(lines, "\n") .. "\n")
end)
