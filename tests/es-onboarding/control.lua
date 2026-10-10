-- Builds the onboarding save: a new game's first hour with the mod. Only
-- red science and the Empirical method are researched; nothing staged is. Near spawn: free power, a
-- starter chest with what a first experiment needs, and labs. scripts/make_playtest.sh onboarding saves
-- it to the dev profile, and refuses to unless the staged state is what a new game has.
local s

local function place(name, x, y, dir)
  local e = s.create_entity{name = name, position = {x, y}, force = "player", raise_built = true, direction = dir}
  if not e then error("could not place " .. name .. " at " .. x .. "," .. y) end
  return e
end

-- What a player would have built or crafted by the time the method is researched, and the mod's
-- buildings for a first screen (a station, four benches with hoppers).
local STARTER = {
  {"es-analysis-station", 1}, {"es-test-bench", 4}, {"es-hopper", 4}, {"assembling-machine-1", 4},
  {"inserter", 30}, {"transport-belt", 200}, {"wooden-chest", 20}, {"small-electric-pole", 50}, {"lab", 4},
  {"automation-science-pack", 400}, {"iron-plate", 400}, {"copper-plate", 400}, {"iron-gear-wheel", 200},
  {"coal", 200}, {"stone", 200}, {"wood", 100}, {"stone-brick", 100}, {"copper-cable", 200},
}

script.on_init(function()
  s = game.surfaces.nauvis
  local force = game.forces.player
  for _, t in ipairs({"automation-science-pack", "es-empirical-method"}) do force.technologies[t].researched = true end
  s.request_to_generate_chunks({0, 0}, 3); s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities_filtered{area = {{-12, -12}, {12, 12}}}) do
    if e.type ~= "character" then e.destroy() end
  end
  -- What a player has mined by the time the method is researched (the dose picker offers what the
  -- force has made or can make).
  for _, name in ipairs({"coal", "stone", "wood", "iron-ore", "copper-ore"}) do
    force.get_item_production_statistics(s).on_flow(name, 50)
  end
  local eei = place("electric-energy-interface", -6, -6)
  eei.power_production, eei.electric_buffer_size = 1e7, 1e7
  place("small-electric-pole", -4, -6)
  local chest = place("steel-chest", 0, -6)
  local inv = chest.get_inventory(defines.inventory.chest)
  for _, it in ipairs(STARTER) do inv.insert{name = it[1], count = it[2]} end
  local panel = place("display-panel", 2, -6)
  panel.display_panel_text = "Onboarding: free power (left) and a starter chest. The method is researched; nothing else of Empirical Science is."
  panel.display_panel_always_show = true

  -- The staged state a new game has, checked before the save is kept.
  local staged = {}
  for _, name in ipairs({"es-mixtures", "es-thermal-studies", "es-precision-instruments-1",
                         "es-circuit-instrumentation-1"}) do
    if force.technologies[name].researched then table.insert(staged, name) end
  end
  local missing = {}
  for _, it in ipairs(STARTER) do
    if inv.get_item_count(it[1]) < it[2] then table.insert(missing, it[1]) end
  end
  local ok = #staged == 0 and #missing == 0
  helpers.write_file("es-kit-status.txt", string.format("staged researched: %s; starter missing: %s\n%s\n",
    #staged > 0 and table.concat(staged, ", ") or "none", #missing > 0 and table.concat(missing, ", ") or "none",
    ok and "KIT OK" or "KIT FAIL"))
end)
