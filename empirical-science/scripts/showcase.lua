-- The main menu's scenes (0.70, user): vanilla's own menu saves with the mod's machines added (augment):
-- a layout built by hand in the map editor and pasted (scenes/<key>.lua, scripts/scene_workshop.sh), or the
-- mod's scripted additions. The scenes interface only (simulations and tests). (0.71: the three scenes built
-- from nothing, dose study, before and after, frontier, retired: user, bland beside vanilla's.)
local shared = require("shared")
local dosing = require("scripts.dosing")

local showcase = {}

local N, E, S, W = defines.direction.north, defines.direction.east, defines.direction.south, defines.direction.west

-- Clear the map's own things (trees, rocks, cliffs, water, decoratives) under what is about to be built.
local function clear(s, x, y, r)
  local area = {{x - r, y - r}, {x + r, y + r}}
  for _, e in pairs(s.find_entities_filtered{area = area, type = {"tree", "simple-entity", "cliff", "fish"}}) do
    if e.valid then e.destroy() end
  end
  s.destroy_decoratives{area = area}
  local tiles = {}
  for tx = math.floor(x - r), math.ceil(x + r) - 1 do
    for ty = math.floor(y - r), math.ceil(y + r) - 1 do
      local t = s.get_tile(tx, ty)
      if t.collides_with("water_tile") then table.insert(tiles, {name = "grass-1", position = {tx, ty}}) end
    end
  end
  if #tiles > 0 then s.set_tiles(tiles) end
end

local function place(s, name, x, y, dir, force)
  local cb = prototypes.entity[name].collision_box
  local r = math.max(-cb.left_top.x, -cb.left_top.y, cb.right_bottom.x, cb.right_bottom.y) + 0.6
  clear(s, x, y, r)
  return s.create_entity{name = name, position = {x, y}, direction = dir, force = force, raise_built = true}
end
local function pipes(s, from, to, force)  -- horizontal first, then vertical
  local x, y = math.floor(from.x or from[1]) + 0.5, math.floor(from.y or from[2]) + 0.5
  local tx, ty = math.floor(to.x or to[1]) + 0.5, math.floor(to.y or to[2]) + 0.5
  local function put() if not s.find_entity("pipe", {x, y}) then place(s, "pipe", x, y, nil, force) end end
  put()
  while x ~= tx do x = x + (tx > x and 1 or -1); put() end
  while y ~= ty do y = y + (ty > y and 1 or -1); put() end
end
local function port_of(e, fluid)  -- where a pipe must stand to reach the fluid box holding `fluid`
  local fb = e.fluidbox
  for i = 1, #fb do
    local f = fb.get_locked_fluid(i) or (fb.get_filter(i) or {}).name
    if not fluid or f == fluid then
      local c = fb.get_pipe_connections(i)[1]
      if c then return c.target_position end
    end
  end
end

----------------------------------------------------------------------------------------------------------
-- Vanilla's own scenes, augmented (the scripted scenes looked bland; vanilla's look
-- organic). The base game's menu saves load as they are; the mod's machines then take places in them.
----------------------------------------------------------------------------------------------------------
local function spawn(s, name, pos, dir, force)
  return s.create_entity{name = name, position = pos, direction = dir, force = force, raise_built = true}
end

-- A dosed district, laid out as a player would build it, one character per tile, its top left 27 tiles left of
-- the camera and 6 below. Gear machines in two rows, each hopper between two of them so it doses both. The
-- upper hoppers take coal from the plate belt's second lane (filtered inserters, k); the lower ones are fluid
-- hoppers (f) taking a liquid premix, piped from a chemical plant at the bottom edge, under the output belt
-- (pipes to ground, A and V).
-- The output column crosses the input belt underground (U, D); a filter splitter (Z) sorts the residue off
-- it. Both columns dip under the residue's belt (U D, X Y), which crosses vanilla's belts on a long underground
-- ([ ]) into a clearing on the left: a chemical plant (R) refines it, acid piped from a tank (K), and its
-- catalyst runs north through the trees (L, N) to a hopper dosing vanilla's own smelter. Below the screen
-- (SOURCES): loaders and infinity chests feed the input column and empty the output, infinity pipes supply
-- the premix plant's water and the refinery's acid. Only the game's own entities: the menu loads no other mod.
local DISTRICT = {x = -27, y = 6, rows = [[
........................................
...................v<<<<<<<<<<<<<<<.....
...................v.n...n...n...n......
...................vGGGoGGG.GGGoGGG.....
..Neh..............vGGG.GGG.GGG.GGG.....
..N................vGGGhGGGhGGGhGGG.....
..N................U.n.k.n.k.n.k.n......
..N...............>>>>>>>>>>>>>>>>>.....
..N...............^D.s.o.s...s.o.s......
..N...............^vgggfgggfgggfggg.....
..NLLLLLLL........^vgggfgggfgggfggg.....
.........n........^vggg+ggg+ggg+ggg.....
....KKK+RRR.......^v.s.A.s.A.s.A.s......
....KKK+RRRwN.....^v<<<<<<<<<<<<<<<.....
....KKK+RRR.N.....^ZZo.V.o.V.o.V.o......
............N.....XUv.++++++++++........
............N].....[L..CCC..............
..................YD...CCC..............
..................^v...CCC..............
..................^v....................
..................^}}...................
]]}
local PREMIX_LINE = "es-premix-coal-water"
local TILE = {
  -- Express belt: eight gear machines take 24 plates a second (one lane), and give 12 gears.
  ["<"] = {"express-transport-belt", W}, [">"] = {"express-transport-belt", E}, ["^"] = {"express-transport-belt", N},
  ["v"] = {"express-transport-belt", S},
  U = {"express-underground-belt", S, "input"}, D = {"express-underground-belt", S, "output"},
  Y = {"express-underground-belt", N, "input"}, X = {"express-underground-belt", N, "output"},
  ["["] = {"fast-underground-belt", W, "input"}, ["]"] = {"fast-underground-belt", W, "output"},
  L = {"transport-belt", W}, N = {"transport-belt", N},   -- the residue's and the catalyst's belts
  ["}"] = {"transport-belt", E},                           -- the output's way to its sink
  -- (An inserter's direction names the side it picks from.)
  n = {"inserter", S}, s = {"inserter", N}, k = {"inserter", S, nil, "coal"}, e = {"inserter", W},
  w = {"inserter", E},
  h = {"es-hopper"}, f = {"es-fluid-hopper"}, ["+"] = {"pipe"}, A = {"pipe-to-ground", N}, V = {"pipe-to-ground", S},
  o = {"medium-electric-pole"},
  G = {"assembling-machine-2", nil, nil, nil, "coal"}, g = {"assembling-machine-2", nil, nil, nil, PREMIX_LINE},
  C = {"chemical-plant", S, nil, nil, nil, PREMIX_LINE}, R = {"chemical-plant", W, nil, nil, nil, "es-refine-coal"},
  K = {"storage-tank"},
}
local BIG = {G = true, g = true, C = true, R = true, K = true}

-- Off-screen sources and sinks, from the camera (tiles): {entity, x, y, direction, loader type, item, void}.
-- The input column runs down to the first row with room on both sides (vanilla's own belts run below the
-- screen too): a loader each side sideloads onto it, plates on one lane, coal on the other.
local SOURCES = {
  {"infinity-chest", -11, 0, nil, nil, "iron-plate"}, {"loader-1x1", -10, 0, E, "output"},
  {"loader-1x1", -8, 0, W, "output"}, {"infinity-chest", -7, 0, nil, nil, "coal"},
}
-- (A loader's "input" puts into its container, "output" takes from it.)
local SINK = {{"loader-1x1", -6, 26, E, "input"}, {"infinity-chest", -5, 26, nil, nil, nil, true}}
local function infinity_pipe(s, force, pos, fluid)
  local p = place(s, "infinity-pipe", pos.x, pos.y, nil, force)
  p.set_infinity_pipe_filter{name = fluid, percentage = 1, mode = "exactly"}
  return p
end
local function sources(s, force, c)
  local cx, cy = math.floor(c.x), math.floor(c.y)
  local function free(x, y)
    return s.can_place_entity{name = "transport-belt", position = {cx + x + 0.5, cy + y + 0.5}, force = force}
  end
  local function build(list, dy)
    for _, src in ipairs(list) do
      local x, y = cx + src[2] + 0.5, cy + src[3] + dy + 0.5
      clear(s, x, y, 0.6)
      -- (A loader's type goes in at creation: set afterwards, it turns the loader round.)
      local e = s.create_entity{name = src[1], position = {x, y}, direction = src[4], type = src[5], force = force}
      if e and src[6] then e.infinity_container_filters = {{index = 1, name = src[6], count = 100, mode = "exactly"}} end
      if e and src[7] then e.remove_unfiltered_items = true end
    end
  end
  build(SINK, 0)
  local row
  for y = 27, 40 do
    local ok = true
    for x = -11, -7 do ok = ok and free(x, y) end
    if ok then row = y break end
  end
  if row then
    for y = 27, row do place(s, "express-transport-belt", cx - 8.5, cy + y + 0.5, N, force) end
    build(SOURCES, row)
  end
  -- The premix plant's water and coal, from below it.
  local plant = s.find_entities_filtered{position = {cx - 2.5, cy + 23.5}, name = "chemical-plant"}[1]
  local w = plant and port_of(plant, "water")
  if w then infinity_pipe(s, force, w, "water") end
  if plant then
    local bb = plant.bounding_box
    local x = w and (w.x < plant.position.x and plant.position.x + 1 or plant.position.x - 1) or plant.position.x
    place(s, "inserter", x, bb.right_bottom.y + 0.5, S, force)   -- (it picks from the south)
    local ch = place(s, "infinity-chest", x, bb.right_bottom.y + 1.5, nil, force)
    ch.infinity_container_filters = {{index = 1, name = "coal", count = 50, mode = "exactly"}}
    place(s, "medium-electric-pole", x + 1, bb.right_bottom.y + 1.5, nil, force)   -- (the district's poles end above)
  end
  -- The refinery's tank: acid from below the screen, under the trees.
  local tank = s.find_entities_filtered{position = {cx - 21.5, cy + 19.5}, name = "storage-tank"}[1]
  if tank then
    local low
    for _, cn in ipairs(tank.fluidbox.get_pipe_connections(1)) do
      if not low or cn.target_position.y > low.y then low = cn.target_position end
    end
    place(s, "pipe-to-ground", low.x, low.y, N, force)
    place(s, "pipe-to-ground", low.x, cy + 24.5, S, force)
    infinity_pipe(s, force, {x = low.x, y = cy + 25.5}, "sulfuric-acid")
  end
end

local function district(s, force, c)
  local ox, oy = math.floor(c.x) + DISTRICT.x, math.floor(c.y) + DISTRICT.y
  local rows = {}
  for line in DISTRICT.rows:gmatch("[^\n]+") do table.insert(rows, line) end
  local at = function(x, y) return rows[y] and rows[y]:sub(x, x) or "" end
  local built, missed, machines, belts = 0, {}, {}, {}
  -- (A premix and a residue's refining unlock when discovered.)
  force.recipes[PREMIX_LINE].enabled = true
  force.recipes["es-refine-coal"].enabled = true
  for y = 1, #rows do
    for x = 1, #rows[y] do
      local ch = at(x, y)
      local t = TILE[ch]
      -- A 3x3 machine is built from its top left tile (the first of its letter met).
      local big = BIG[ch]
      -- A fluid hopper (f) is 1x2, upright: built from its top tile.
      if ch == "f" then
        if at(x, y - 1) ~= "f" then
          clear(s, ox + x - 0.5, oy + y, 1.2)
          local e = s.create_entity{name = "es-fluid-hopper", position = {ox + x - 0.5, oy + y}, direction = N,
            force = force, raise_built = true}
          if e then built = built + 1 else table.insert(missed, "f@" .. (x - 1) .. "," .. (y - 1)) end
        end
        goto next_tile
      end
      if ch == "Z" and at(x - 1, y) ~= "Z" then
        local sp = place(s, "express-splitter", ox + x, oy + y - 0.5, S, force)
        sp.splitter_filter = {name = shared.residue_of("coal")}
        sp.splitter_output_priority = "left"   -- (facing south, its left is east: the residue's belt)
        built = built + 1
      end
      if t and (not big or (at(x - 1, y) ~= ch and at(x, y - 1) ~= ch)) then
        local px, py = ox + x - 1 + (big and 1.5 or 0.5), oy + y - 1 + (big and 1.5 or 0.5)
        local cb = prototypes.entity[t[1]].collision_box
        clear(s, px, py, math.max(cb.right_bottom.x, cb.right_bottom.y) + 0.5)
        local e = s.create_entity{name = t[1], position = {px, py}, direction = t[2], type = t[3], force = force,
          raise_built = true}
        if e then
          built = built + 1
          if t[4] then e.use_filters = true; e.set_filter(1, t[4]) end
          -- The input belt (the column up, then the row east): plates on one lane, coal on the other.
          if (ch == "^" or ch == ">") and e.type == "transport-belt" then table.insert(belts, e) end
          if t[1] == "assembling-machine-2" then
            e.set_recipe("iron-gear-wheel")
            table.insert(machines, {e, t[5]})
          elseif ch == "C" then
            e.set_recipe(t[6]); storage.showcase_plant = e
          elseif ch == "R" then
            e.set_recipe(t[6]); storage.showcase_refinery = e
            e.insert{name = "es-spent-coal", count = 24}
          elseif ch == "K" then
            e.insert_fluid{name = "sulfuric-acid", amount = 20000}
          elseif ch == "N" or ch == "L" then
            -- Residue on its way in (right of the refinery), catalyst on its way out (left).
            local item = e.position.x > math.floor(c.x) - 17 and "es-spent-coal" or "es-refined-coal"
            e.get_transport_line(1).insert_at(0.5, {name = item, count = 1})
          end
        else
          table.insert(missed, ch .. "@" .. (x - 1) .. "," .. (y - 1))
        end
      end
      ::next_tile::
    end
  end
  -- The plant's premix output to the pipe line's west end.
  local plant = storage.showcase_plant
  if plant and plant.valid then
    local p = port_of(plant, PREMIX_LINE)
    if p then pipes(s, p, {math.floor(c.x) - 4.5, math.floor(c.y) + 21.5}, force) end
  end
  -- The catalyst's hopper doses the vanilla smelter beside it.
  local cx, cy = math.floor(c.x), math.floor(c.y)
  local ch = s.find_entity("es-hopper", {cx - 22.5, cy + 10.5})
  local furnace = ch and s.find_entities_filtered{position = {cx - 21.5, cy + 10.5}, type = "furnace"}[1]
  if furnace then
    ch.insert{name = "es-refined-coal", count = 5}
    -- (A tree's crown reaches up over the tiles north of its trunk: cut the ones hiding the hopper.)
    for _, t in pairs(s.find_entities_filtered{area = {{cx - 26, cy + 9}, {cx - 20, cy + 15}}, type = "tree"}) do
      t.destroy()
    end
    table.insert(machines, {furnace, "es-refined-coal"})
  else
    table.insert(missed, "smelter beside the catalyst hopper")
  end
  -- Already running when the scene opens, as vanilla's saved scenes are.
  for _, b in ipairs(belts) do
    for lane, item in ipairs({"iron-plate", "coal"}) do
      local line = b.get_transport_line(lane)
      for k = 0, 3 do line.insert_at(k * 0.25 + 0.125, {name = item, count = 1}) end
    end
  end
  for _, m in ipairs(machines) do
    if m[1].type == "assembling-machine" then m[1].insert{name = "iron-plate", count = 20} end
    local area = {{m[1].position.x - 2.6, m[1].position.y - 1.6}, {m[1].position.x + 2.6, m[1].position.y + 1.6}}
    for _, h in pairs(s.find_entities_filtered{area = area, name = "es-hopper"}) do
      if prototypes.item[m[2]] then h.insert{name = m[2], count = 10} end
    end
    for _, p in pairs(s.find_entities_filtered{area = area, name = "es-fluid-hopper"}) do
      if prototypes.fluid[m[2]] then p.insert_fluid{name = m[2], amount = 100} end
    end
  end
  local dosed = 0
  for i, m in ipairs(machines) do
    dosing.set(m[1], {rows = {{name = m[2], dose = m[2] == PREMIX_LINE and 20 or 2 + i % 3}}})
    if #dosing.rows(m[1].unit_number) > 0 then dosed = dosed + 1 end
  end
  sources(s, force, c)
  return {built = built, missed = missed, dosed = dosed}
end

local function augment_lab(s, force, c)
  local function view(dx0, dy0, dx1, dy1) return {{c.x + dx0, c.y + dy0}, {c.x + dx1, c.y + dy1}} end
  local report = district(s, force, c)
  -- Labs: every other one becomes an analysis station (the test bench's samples ride the packs' belt to them).
  local labs = s.find_entities_filtered{area = view(8, -10, 40, 10), type = "lab"}
  table.sort(labs, function(a, b) return a.position.x + a.position.y * 0.01 < b.position.x + b.position.y * 0.01 end)
  for i, l in ipairs(labs) do
    if i % 2 == 1 then
      local pos = l.position
      l.destroy()
      local st = spawn(s, "es-analysis-station", pos, nil, force)
      if st then st.insert{name = "automation-science-pack", count = 100} end
    end
  end
  -- Science: the red science machine nearest the menu runs trials; its samples ride the packs' belt.
  local best, bd
  for _, a in pairs(s.find_entities_filtered{area = view(-40, -23, 40, 23), name = "assembling-machine-2"}) do
    local r = a.get_recipe()
    local d = (a.position.x - c.x) ^ 2 + (a.position.y - c.y) ^ 2
    if r and r.name == "automation-science-pack" and (not bd or d < bd) then best, bd = a, d end
  end
  if best then
    local pos = best.position
    best.destroy()
    local b = spawn(s, "es-test-bench", pos, nil, force)
    if b then b.set_recipe(shared.trial_recipe("red")); report.bench = true end
  end
  return report
end

local AUGMENT = {lab = augment_lab}

-- Scenes built by hand (scripts/scene_workshop.sh): a blueprint of what a person added to vanilla's save, the
-- doses they set and what they removed. Read at load (a scene without a file keeps its scripted additions).
local HAND = {}
for _, key in ipairs({"lab"}) do
  local ok, data = pcall(require, "scenes." .. key)
  if ok then HAND[key] = data end
end

local function paste(s, force, c, data)
  local report = {pasted = 0, failed = {}, dosed = 0, removed = 0}
  local function at(x, y) return {c.x + x, c.y + y} end
  for _, r in ipairs(data.removed or {}) do
    local e = s.find_entity(r[1], at(r[2], r[3]))
    if e then e.destroy(); report.removed = report.removed + 1 else table.insert(report.failed, "remove " .. r[1]) end
  end
  if data.blueprint then
    local inv = game.create_inventory(1)
    local bp = inv[1]
    if bp.import_stack(data.blueprint) ~= 0 then
      table.insert(report.failed, "blueprint import")
    else
      -- Built so its first entity stands where it stood in the workshop. The engine centres a blueprint on the
      -- position given, so the first build only measures the shift: each ghost votes for the offset between
      -- it and the blueprint's entities of its name; the winner places the second build exactly.
      local want = at(data.first.x, data.first.y)
      local function build(pos)
        return bp.build_blueprint{surface = s, force = force, position = pos, build_mode = defines.build_mode.forced}
      end
      local ents = bp.get_blueprint_entities() or {}
      local by_name = {}
      for _, be in ipairs(ents) do
        by_name[be.name] = by_name[be.name] or {}
        table.insert(by_name[be.name], be.position)
      end
      local q = function(v) return math.floor(v * 256 + 0.5) end
      local function shift(ghosts)
        local votes, best, bn = {}, nil, 0
        for _, g in ipairs(ghosts) do
          if g.valid and g.type == "entity-ghost" then
            for _, p in ipairs(by_name[g.ghost_name] or {}) do
              local k = q(g.position.x - p.x) .. "," .. q(g.position.y - p.y)
              votes[k] = (votes[k] or 0) + 1
              if votes[k] > bn then best, bn = {g.position.x - p.x, g.position.y - p.y}, votes[k] end
            end
          end
        end
        return best
      end
      -- Water under anything pasted is landfilled, as a player would (vanilla's lab scene draws its WUBE chip in
      -- water tiles, under the menu). Each entity ends at its blueprint position less the first's, plus want.
      local fill = {}
      for _, be in ipairs(ents) do
        local cb = prototypes.entity[be.name].collision_box
        local r = math.max(-cb.left_top.x, -cb.left_top.y, cb.right_bottom.x, cb.right_bottom.y)
        local px, py = be.position.x - data.first.bx + want[1], be.position.y - data.first.by + want[2]
        for tx = math.floor(px - r), math.ceil(px + r) - 1 do
          for ty = math.floor(py - r), math.ceil(py + r) - 1 do
            if s.get_tile(tx, ty).collides_with("water_tile") then table.insert(fill, {name = "landfill", position = {tx, ty}}) end
          end
        end
      end
      if #fill > 0 then s.set_tiles(fill) end
      local ghosts = build(want)
      local best = shift(ghosts)
      for _, g in ipairs(ghosts) do if g.valid then g.destroy() end end
      if best then
        -- The first entity landed at its blueprint position + best: shift by what it lacks.
        local fx, fy = data.first.bx + best[1], data.first.by + best[2]
        ghosts = build({want[1] + (want[1] - fx), want[2] + (want[2] - fy)})
        local check = shift(ghosts)
        if not check or math.abs(data.first.bx + check[1] - want[1]) > 0.01
          or math.abs(data.first.by + check[2] - want[2]) > 0.01 then
          table.insert(report.failed, "built off its place")
        end
      else
        ghosts = {}
        table.insert(report.failed, "no ghost built to align on")
      end
      local expected, want_n, got_n = 0, {}, {}
      for _, be in ipairs(bp.get_blueprint_entities() or {}) do
        expected = expected + 1
        want_n[be.name] = (want_n[be.name] or 0) + 1
      end
      for _, g in ipairs(ghosts) do
        if g.valid and g.type == "entity-ghost" then
          local b = g.bounding_box
          for _, t in pairs(s.find_entities_filtered{area = b, type = {"tree", "simple-entity", "cliff", "fish"}}) do
            t.destroy()
          end
          s.destroy_decoratives{area = b}
          local name = g.ghost_name
          local _, e = g.revive{raise_revive = true}
          if e then
            report.pasted = report.pasted + 1
            got_n[e.name] = (got_n[e.name] or 0) + 1
            local r = (e.type == "assembling-machine" or e.type == "furnace") and e.get_recipe()
            if r then
              force.recipes[r.name].enabled = true   -- (premixes and refining unlock when discovered)
              -- A scene opens mid-production (a blueprint carries no contents): one craft's worth of each item
              -- ingredient in every machine (user: a ten-second warm-up left a refinery waiting on residue).
              for _, ing in ipairs(r.ingredients) do
                if ing.type == "item" then e.insert{name = ing.name, count = math.ceil(ing.amount)} end
              end
            end
          else
            local in_way = {}
            if g.valid then
              for _, o in pairs(s.find_entities_filtered{area = g.bounding_box}) do
                if o ~= g then in_way[#in_way + 1] = o.name end
              end
            end
            table.insert(report.failed, name .. " (in the way: " .. table.concat(in_way, " ") .. ")")
          end
        end
      end
      -- A forced build marks what is in its way for deconstruction: what the revive did not need keeps no mark
      -- (the measuring build's marks included).
      for _, e in pairs(s.find_entities_filtered{to_be_deconstructed = true}) do e.cancel_deconstruction(force) end
      for name, n in pairs(want_n) do
        if (got_n[name] or 0) < n then table.insert(report.failed, string.format("%s %d of %d", name, got_n[name] or 0, n)) end
      end
    end
    inv.destroy()
  end
  -- What no blueprint holds (the 1x1 loader), created directly.
  for _, l in ipairs(data.loose or {}) do
    local x, y = c.x + l.x, c.y + l.y
    for _, t in pairs(s.find_entities_filtered{area = {{x - 0.5, y - 0.5}, {x + 0.5, y + 0.5}}, type = {"tree", "simple-entity"}}) do
      t.destroy()
    end
    local e = s.create_entity{name = l.name, position = {x, y}, direction = l.direction, type = l.loader_type,
      force = force, raise_built = true}
    if e then report.pasted = report.pasted + 1 else table.insert(report.failed, l.name .. " at " .. l.x .. "," .. l.y) end
  end
  for _, d in ipairs(data.doses or {}) do
    local m = s.find_entities_filtered{position = at(d[1], d[2]), type = {"assembling-machine", "furnace"}}[1]
    if m then
      dosing.set(m, {rows = d[3]})
      if #dosing.rows(m.unit_number) > 0 then report.dosed = report.dosed + 1 end
    else
      table.insert(report.failed, "dose at " .. d[1] .. "," .. d[2])
    end
  end
  return report
end


-- Adds the mod's machines to a vanilla menu scene already loaded; `c` is where its camera looks.
-- `scripted`: the mod's own additions even when a hand-built scene exists (the workshop starts from them).
function showcase.augment(key, surface_name, c, scripted)
  local s = game.surfaces[surface_name]
  local force = game.forces.player
  for _, t in pairs(force.technologies) do t.researched = true end
  local at = {x = c[1] or c.x, y = c[2] or c.y}
  local report
  if HAND[key] and not scripted then
    report = paste(s, force, at, HAND[key])
  else
    report = AUGMENT[key](s, force, at)
    report.failed = report.missed
  end
  -- Every hopper's joints drawn again on the first tick (dosing.redraw_dirty): drawn during the scene's start-up
  -- they did not show in the menu, redrawn after it they do (user saw it, 2026-10-06; why, not found).
  storage.chute_dirty = storage.chute_dirty or {}
  for unit in pairs(storage.hoppers) do storage.chute_dirty[unit] = true end
  return report
end

return showcase
