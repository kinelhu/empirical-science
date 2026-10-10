-- One showcase scene alone in the main menu (scripts/menu_preview.sh writes which into scene.lua and captures
-- the screen: a simulation cannot write files). Its code runs guarded, any error drawn in the scene (the
-- engine's own message hides behind the main menu). Dev profile only: a player's game never has this mod.
local which = require("scene")
local sims = data.raw["utility-constants"]["default"].main_menu_simulations
-- A test layout (not a scene): crate hoppers beside each row of a machine, to see their joints.
sims.es_jointtest = {
  checkboard = true, mods = {"empirical-science", "factorio-charts"}, length = 60 * 20,
  init = [[
    local s = game.surfaces[1]
    local m = s.create_entity{name = "assembling-machine-2", position = {0.5, 0.5}, force = "player", raise_built = true}
    m.set_recipe("iron-gear-wheel")
    for _, p in ipairs({{-1.5, -0.5}, {-1.5, 0.5}, {-1.5, 1.5}, {2.5, -0.5}, {0.5, 2.5}}) do
      s.create_entity{name = "es-hopper", position = p, force = "player", raise_built = true}
    end
    game.simulation.camera_position = {0.5, 0.5}
    game.simulation.camera_zoom = 2.5
    game.tick_paused = false
  ]],
  update = "",
}
-- The lab scene, the camera close on one spot (`labzoom`, for inspecting a detail).
if sims.es_lab then
  sims.es_labzoom = table.deepcopy(sims.es_lab)
  sims.es_labzoom.init = sims.es_labzoom.init .. [[
    local lg = game.surfaces.nauvis.find_entities_filtered{name = "factorio-logo-11tiles", limit = 1}[1]
    game.simulation.camera_position = {lg.position.x + 6, lg.position.y + 9.75 + 16}
    game.simulation.camera_zoom = 3
  ]]
end
local sim = table.deepcopy(sims["es_" .. which])
for k in pairs(sims) do sims[k] = nil end
local function guarded(code, where)
  return "local ok, err = pcall(function()\n" .. code .. "\nend)\n"
    .. "if not ok then\n"
    .. "  rendering.draw_text{text = '" .. where .. ": ' .. tostring(err), surface = game.surfaces[1], "
    .. "target = (function() local l = game.surfaces[1].find_entities_filtered{name = 'factorio-logo-11tiles', limit = 1}[1] "
    .. "return l and {l.position.x - 20, l.position.y + 6} or {-20, -4} end)(), color = {1, 0.3, 0.3}, scale = 2, time_to_live = 600}\n"
    .. "end\n"
end
-- A minute before it restarts (the menu replays a scene when it ends; with one scene, every 10 s, each restart
-- reloading the save, pasting and warming up: a hitch every 10 s).
sim.length = 60 * 60
sim.init = guarded(sim.init, "init")
sim.update = guarded(sim.update, "update")
sims["es_" .. which] = sim
