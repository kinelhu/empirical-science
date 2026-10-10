-- The mod page's pictures (scripts/page_shots.sh), taken in a real game window from real saves.
--   hero: the menu's lab scene baked into a save (scene_workshop.sh bake lab), shot where the menu's camera
--     stands, without the GUI.
--   panels: the findings playtest save run fast to its ending (its gear line finishes the last finding), then
--     its Empirical Science screen open on each tab.
local MODE = require("mode")   -- {shot = "hero" | "panels", camera = {x =, y =}?}
local function es(name, ...) return remote.call("empirical-science", name, ...) end
local OUT = "es-page-shots-done.txt"

-- Each screenshot in its own step: one is rendered at the end of its tick, after any later change in it.
local function hero_steps(player)
  local c = MODE.camera
  local function shot(path, daytime, w, h, zoom, info)
    game.take_screenshot{surface = player.surface, position = c, resolution = {w, h}, zoom = zoom, daytime = daytime,
      show_gui = false, show_entity_info = info, anti_alias = true, quality = 100, path = path}
  end
  return {
    function()
      if player.character then player.character.destroy() end   -- (out of the picture)
      player.set_controller{type = defines.controllers.spectator}
    end,
    function() shot("es-hero-night.png", 0.5, 2560, 1440, 1) end,
    function() shot("es-hero-day.png", 0, 2560, 1440, 1) end,
    function() shot("es-hero-day-1080.png", 0, 1920, 1080, 1) end,
    function() shot("es-hero-day-alt.png", 0, 2560, 1440, 1, true) end,
  }
end

local function panels_steps(player)
  local steps = {function() es("open_science", player.index) end}
  local function tab(name)
    local pn = player.gui.screen.es_science and player.gui.screen.es_science.panel
    if not pn then return false end
    for i, t in ipairs(pn.pages.tabs) do
      if t.tab.name == name then pn.pages.selected_tab_index = i; return true end
    end
    return false
  end
  for _, name in ipairs({"tab_screening", "tab_dose", "tab_coverage", "tab_dossiers", "tab_theory"}) do
    table.insert(steps, function()
      if tab(name) then
        es("gui_set", player.index, {})   -- (a scripted tab change raises no event: Coverage fills on refresh)
      else
        storage.missing = (storage.missing or "") .. " " .. name
      end
    end)
    table.insert(steps, function()
      if tab(name) then
        game.take_screenshot{player = player, show_gui = true, path = "es-page-" .. name:sub(5) .. ".png"}
      else
        storage.missing = (storage.missing or "") .. " " .. name
      end
    end)
  end
  return steps
end

script.on_event(defines.events.on_tick, function(e)
  local player = game.get_player(1)
  if not player or storage.finished then return end
  storage.t = (storage.t or 0) + 1
  if storage.t < 60 then return end                   -- (the window settles)
  if MODE.shot == "panels" and not storage.ended then
    -- Run to the ending, then close what it opened: only the screen in the picture.
    game.speed = 32
    -- (This reading is fresh; the screen shows the mod's own judgement, made every 600 ticks: one more passes.)
    if not storage.fin_at and storage.t % 60 == 0 and es("dossier_state", "player").finished then storage.fin_at = storage.t end
    if (storage.fin_at and storage.t >= storage.fin_at + 700) or storage.t > 45000 then
      game.speed = 1
      storage.ended = storage.t
      if not es("dossier_state", "player").finished then storage.missing = (storage.missing or "") .. " ending" end
      for _, w in pairs(player.gui.screen.children) do if w.name ~= "es_science" then w.destroy() end end
      player.surface.daytime = 0
      player.surface.freeze_daytime = true
    end
    return
  end
  local t0 = storage.ended and storage.ended + 60 or 60
  local steps = MODE.shot == "hero" and hero_steps(player) or panels_steps(player)
  if storage.t < t0 then return end
  local i = (storage.t - t0) / 20 + 1                 -- a step every 20 ticks
  if i == math.floor(i) and steps[i] then steps[i]() end
  -- Written well after the last screenshot (they are written to disk a moment after they are taken).
  if i == #steps + 3 then
    storage.finished = true
    helpers.write_file(OUT, "done " .. MODE.shot .. (storage.missing and (" missing:" .. storage.missing) or "") .. "\n")
  end
end)
