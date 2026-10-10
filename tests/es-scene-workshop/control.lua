-- The menu-scene workshop (scripts/scene_workshop.sh): a person builds a scene in the map editor, a script
-- does the rest. Dev profile only.
--   prepare: vanilla's menu save, everything researched and the visible frame outlined in hazard concrete just
--     outside the view; its own entities listed (vanilla_<scene>.lua), saved for the editor.
--   extract: the edited save against that list: what was added becomes a blueprint (with the doses set on its
--     machines), what was removed a list; written as the mod's scene file (scenes/<scene>.lua).
--   bake: vanilla's menu save with the scene pasted as the menu pastes it, without Factorio's logo, run as long
--     as the menu runs it before it shows, saved (es-bake-<scene>) for screenshots (scripts/page_shots.sh).
local MODE = require("mode")   -- {action = "prepare" | "extract" | "bake", scene = "lab", from_script = true?}
local VANILLA = MODE.action == "extract" and require("vanilla_" .. MODE.scene) or nil

-- What a scene keeps from one load to the next: buildings, trees, rocks. Not what moves or is transient.
local SKIP = {character = true, ["spider-vehicle"] = true, ["spider-leg"] = true, car = true, unit = true,
  ["item-entity"] = true, corpse = true, ["character-corpse"] = true, fish = true, ["entity-ghost"] = true,
  ["tile-ghost"] = true, explosion = true, ["particle-source"] = true, projectile = true, stream = true,
  ["highlight-box"] = true, ["deconstructible-tile-proxy"] = true, ["item-request-proxy"] = true}
local R = 1 / 256
local function key(name, x, y) return name .. "@" .. math.floor(x / R + 0.5) .. "," .. math.floor(y / R + 0.5) end
local function camera(s)
  local logo = s.find_entities_filtered{name = "factorio-logo-11tiles", limit = 1}[1]
  return logo and {x = logo.position.x, y = logo.position.y + 9.75}
end
local AREA = {70, 45}   -- around the camera: the 80 x 45 view and a margin for what feeds it
local function area(c) return {{c.x - AREA[1], c.y - AREA[2]}, {c.x + AREA[1], c.y + AREA[2]}} end
local function kept(s, c)
  local out = {}
  for _, e in pairs(s.find_entities_filtered{area = area(c)}) do
    if not SKIP[e.type] and not e.name:find("^factorio%-logo") then table.insert(out, e) end
  end
  return out
end
local function num(v) return string.format("%.6g", v) end

local function prepare(s, c)
  local f = game.forces.player
  f.research_all_technologies()
  for _, r in pairs(f.recipes) do r.enabled = true end   -- (premixes and refining unlock when discovered)
  local lines = {"return {"}
  for _, e in pairs(kept(s, c)) do
    table.insert(lines, string.format("  [%q] = true,", key(e.name, e.position.x - c.x, e.position.y - c.y)))
  end
  table.insert(lines, "}")
  helpers.write_file("vanilla_" .. MODE.scene .. ".lua", table.concat(lines, "\n") .. "\n")
  -- A starting point (--from-script): the mod's scripted additions, built after the list so they count as added.
  if MODE.from_script and remote.interfaces["empirical-science-scenes"] then
    remote.call("empirical-science-scenes", "augment_showcase", MODE.scene, s.name, {c.x, c.y}, true)
  end
  -- The frame: hazard concrete one tile outside the 80 x 45 view (a 2560 x 1440 window at zoom 1), refined
  -- hazard concrete at the corners of the 60 x 34 view (1920 x 1080). Tiles only: the scene takes entities.
  local tiles = {}
  local function ring(hw, hh, name, corners)
    local x0, x1 = math.floor(c.x - hw) - 1, math.ceil(c.x + hw)
    local y0, y1 = math.floor(c.y - hh) - 1, math.ceil(c.y + hh)
    for x = x0, x1 do for _, y in ipairs({y0, y1}) do
      if not corners or x - x0 < 3 or x1 - x < 3 then table.insert(tiles, {name = name, position = {x, y}}) end
    end end
    for y = y0, y1 do for _, x in ipairs({x0, x1}) do
      if not corners or y - y0 < 3 or y1 - y < 3 then table.insert(tiles, {name = name, position = {x, y}}) end
    end end
  end
  ring(40, 22.5, "hazard-concrete-left")
  ring(30, 17, "refined-hazard-concrete-left", true)
  s.set_tiles(tiles, true, false)
  storage.save_at = game.tick + 2   -- (a save cannot be made inside on_init: a headless server saves it)
  game.tick_paused = false          -- (menu saves are stored paused)
end
-- The menu's own warm-up (data.lua, init_update_count) and daytime, so the save shows what the menu shows.
local function bake(s, c)
  local r = remote.call("empirical-science-scenes", "augment_showcase", MODE.scene, s.name, {c.x, c.y})
  -- A guard: a scene pasted short is not saved.
  if not r or #r.failed > 0 or r.pasted == 0 then
    helpers.write_file("workshop-status.txt", "not baked: " .. serpent.line(r and r.failed) .. "\n")
    return
  end
  log(string.format("workshop: pasted %d, dosed %d", r.pasted, r.dosed))
  for _, e in pairs(s.find_entities_filtered{area = area(c)}) do
    if e.name:find("^factorio%-logo") then e.destroy() end
  end
  s.daytime = 0.5
  s.freeze_daytime = true
  helpers.write_file("camera_" .. MODE.scene .. ".lua", string.format("return {x = %s, y = %s}\n", num(c.x), num(c.y)))
  storage.save_at = game.tick + 600
  game.tick_paused = false
end

script.on_event(defines.events.on_tick, function(e)
  if storage.save_at and e.tick >= storage.save_at then
    storage.save_at = nil
    log("workshop: saving at tick " .. e.tick)
    local baked = MODE.action == "bake"
    game.server_save((baked and "es-bake-" or "es-scene-") .. MODE.scene)
    helpers.write_file("workshop-status.txt", baked and "baked\n" or "prepared\n")
  end
end)

local function extract(s, c)
  local now, new = {}, {}
  for _, e in pairs(kept(s, c)) do
    local k = key(e.name, e.position.x - c.x, e.position.y - c.y)
    now[k] = true
    if not VANILLA[k] then new[e.unit_number or k] = e end
  end
  local removed = {}
  for k in pairs(VANILLA) do
    if not now[k] then
      local name, x, y = k:match("^(.*)@(-?%d+),(-?%d+)$")
      table.insert(removed, string.format("    {%q, %s, %s},", name, num(tonumber(x) * R), num(tonumber(y) * R)))
    end
  end
  table.sort(removed)
  -- The added entities as a blueprint (create_blueprint takes everything in an area: the rest is dropped).
  local box
  for _, e in pairs(new) do
    local b = e.bounding_box
    box = box or {{b.left_top.x, b.left_top.y}, {b.right_bottom.x, b.right_bottom.y}}
    box[1][1], box[1][2] = math.min(box[1][1], b.left_top.x), math.min(box[1][2], b.left_top.y)
    box[2][1], box[2][2] = math.max(box[2][1], b.right_bottom.x), math.max(box[2][2], b.right_bottom.y)
  end
  local doses = {}
  -- Doses on every machine around, added or vanilla's own (a hopper may dose a vanilla machine).
  if remote.interfaces["empirical-science-scenes"] then
    for _, m in pairs(s.find_entities_filtered{area = area(c), type = {"assembling-machine", "furnace"}}) do
      local rows = remote.call("empirical-science-scenes", "dose_of", m.unit_number)
      if rows and #rows > 0 then
        table.insert(doses, string.format("    {%s, %s, %s},", num(m.position.x - c.x), num(m.position.y - c.y),
          serpent.line(rows)))
      end
    end
    table.sort(doses)
  end
  local out = {"-- Generated by scripts/scene_workshop.sh extract " .. MODE.scene .. ": do not edit.", "return {"}
  local count, loose = 0, {}
  if box then
    local inv = game.create_inventory(1)
    local bp = inv[1]
    bp.set_stack("blueprint")
    local map = bp.create_blueprint{surface = s, force = "player", area = box, include_entities = true,
      include_modules = true, include_fuel = true, always_include_tiles = false}
    local keep, renum = {}, {}
    for _, be in ipairs(bp.get_blueprint_entities() or {}) do
      local e = map[be.entity_number]
      if e and e.valid and new[e.unit_number or key(e.name, e.position.x - c.x, e.position.y - c.y)] then
        table.insert(keep, {be = be, e = e})
      end
    end
    -- What a blueprint cannot hold (no item places it: the 1x1 loader), recorded to be created directly.
    local in_bp = {}
    local function id(e) return e.unit_number or key(e.name, e.position.x, e.position.y) end
    for _, k in ipairs(keep) do in_bp[id(k.e)] = true end   -- (two lookups of one entity are not equal as keys)
    for _, e in pairs(new) do
      -- (Not the mod's hidden companions, flagged not-blueprintable: the mod makes them with their owner.)
      if not in_bp[id(e)] and not (e.prototype.flags or {})["not-blueprintable"] then
        table.insert(loose, string.format("    {name = %q, x = %s, y = %s, direction = %d%s},", e.name,
          num(e.position.x - c.x), num(e.position.y - c.y), e.direction,
          e.type == "loader-1x1" and string.format(", loader_type = %q", e.loader_type) or ""))
      end
    end
    local list = {}
    for i, k in ipairs(keep) do renum[k.be.entity_number] = i end
    for i, k in ipairs(keep) do
      local be = k.be
      be.entity_number = i
      if be.wires then
        local w = {}
        for _, wire in ipairs(be.wires) do
          if renum[wire[1]] and renum[wire[3]] then table.insert(w, {renum[wire[1]], wire[2], renum[wire[3]], wire[4]}) end
        end
        be.wires = #w > 0 and w or nil
      end
      table.insert(list, be)
    end
    bp.set_blueprint_entities(list)
    count = #list
    local first = keep[1] and keep[1].e
    table.insert(out, string.format("  blueprint = %q,", bp.export_stack()))
    -- Where the blueprint's first entity stands, from the camera: the paste aligns on it.
    -- (Its position within the blueprint, read back after the entities were set: the paste builds at
    -- where it stood, less this.)
    local rel = bp.get_blueprint_entities()[1].position
    table.insert(out, string.format("  first = {name = %q, x = %s, y = %s, bx = %s, by = %s},", first.name,
      num(first.position.x - c.x), num(first.position.y - c.y), num(rel.x), num(rel.y)))
    inv.destroy()
  end
  table.sort(loose)
  table.insert(out, "  loose = {\n" .. table.concat(loose, "\n") .. "\n  },")
  table.insert(out, "  doses = {\n" .. table.concat(doses, "\n") .. "\n  },")
  table.insert(out, "  removed = {\n" .. table.concat(removed, "\n") .. "\n  },")
  table.insert(out, "}")
  helpers.write_file("scene_" .. MODE.scene .. ".lua", table.concat(out, "\n") .. "\n")
  helpers.write_file("workshop-status.txt", string.format("extracted %d added (%d outside the blueprint), %d removed, %d dosed\n",
    count + #loose, #loose, #removed, #doses))
end

local done = false
local function run()
  if done then return end
  done = true
  local s = game.surfaces.nauvis
  local c = camera(s)
  log("workshop: " .. MODE.action .. " " .. MODE.scene)
  if not c then helpers.write_file("workshop-status.txt", "no logo\n"); return end
  if MODE.action == "prepare" then prepare(s, c) elseif MODE.action == "bake" then bake(s, c) else extract(s, c) end
end
script.on_init(run)
-- Extraction also on the first tick: a save that already holds this mod gets no on_init.
if MODE.action == "extract" then script.on_nth_tick(1, function() run() end) end
