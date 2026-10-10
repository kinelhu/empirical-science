-- Survey of a vanilla menu scene save (scripts/scene_survey.sh): what stands around the camera (9.75 tiles
-- below the logo), as JSON in script-output. Dev profile only.
local AUGMENT = (pcall(require, "augment")) and require("augment") or nil
local SHOWN   -- products made by each machine when the scene starts showing
local STATUS = {}
for n, v in pairs(defines.entity_status) do STATUS[v] = n end
local function survey()
  local out, problems = {}, {}
  for _, s in pairs(game.surfaces) do
    local logo = s.find_entities_filtered{name = {"factorio-logo-11tiles", "factorio-logo-16tiles", "factorio-logo-22tiles"}, limit = 1}[1]
    if logo then
      local c = {x = logo.position.x, y = logo.position.y + 9.75}
      local area = {{c.x - 45, c.y - 26}, {c.x + 45, c.y + 26}}
      local counts, machines = {}, {}
      for _, e in pairs(s.find_entities_filtered{area = area}) do
        counts[e.name] = (counts[e.name] or 0) + 1
        if e.type == "assembling-machine" or e.type == "furnace" or e.type == "lab" or e.type == "mining-drill" then
          local r = (e.type == "assembling-machine" or e.type == "furnace") and e.get_recipe() or nil
          table.insert(machines, {e.name, math.floor(e.position.x - c.x), math.floor(e.position.y - c.y), r and r.name or "",
            e.direction})
        end
      end
      -- A character map of the view (80 x 46 tiles: a 2560-wide window at zoom 1), one letter per entity kind.
      local rows = {}
      for y = 1, 46 do rows[y] = {} for x = 1, 80 do rows[y][x] = "." end end
      local sym = {lab = "L", ["assembling-machine"] = "A", furnace = "F", ["transport-belt"] = "=",
        ["underground-belt"] = "u", inserter = "i", ["electric-pole"] = "P", lamp = "*", splitter = "s",
        tree = "T", cliff = "C", ["mining-drill"] = "D", pipe = "|", ["pipe-to-ground"] = "|", container = "B",
        ["storage-tank"] = "K", ["simple-entity"] = "r", wall = "W"}
      for _, e in pairs(s.find_entities_filtered{area = {{c.x - 40, c.y - 23}, {c.x + 40, c.y + 23}}}) do
        local ch = sym[e.type] or (e.type == "optimized-decorative" and nil) or "?"
        if e.name:find("logo") then ch = "O" end
        local bb = e.bounding_box
        for y = math.floor(bb.left_top.y - c.y + 23) + 1, math.ceil(bb.right_bottom.y - c.y + 23) do
          for x = math.floor(bb.left_top.x - c.x + 40) + 1, math.ceil(bb.right_bottom.x - c.x + 40) do
            if rows[y] and rows[y][x] and ch then rows[y][x] = ch end
          end
        end
      end
      local lines = {}
      for y = 1, 46 do lines[y] = table.concat(rows[y]) end
      helpers.write_file("scene-map.txt", table.concat(lines, "\n") .. "\n")
      local on_belts = {}
      for _, b in pairs(s.find_entities_filtered{area = {{c.x - 40, c.y - 23}, {c.x + 40, c.y + 23}},
        type = {"transport-belt", "underground-belt", "splitter"}}) do
        for i = 1, b.get_max_transport_line_index() do
          for _, it in pairs(b.get_transport_line(i).get_contents()) do on_belts[it.name] = (on_belts[it.name] or 0) + it.count end
        end
      end
      local held = {}
      if AUGMENT then
        for _, e in pairs(s.find_entities_filtered{area = {{c.x - 40, c.y - 23}, {c.x + 40, c.y + 23}},
          name = {"es-hopper", "es-fluid-hopper", "assembling-machine-2", "chemical-plant", "electric-furnace"}}) do
          local k = e.name .. "@" .. math.floor(e.position.x - c.x) .. "," .. math.floor(e.position.y - c.y)
          if e.name == "es-hopper" or e.name == "es-fluid-hopper" then
            -- (What it holds, and how many joints it drew into machines.)
            held[k] = {holds = e.name == "es-hopper" and e.get_inventory(defines.inventory.chest).get_contents()
              or e.get_fluid_contents(), joints = remote.call("empirical-science", "bridges", e.unit_number),
              chutes = remote.call("empirical-science", "chutes", e.unit_number),
              sprites = remote.call("empirical-science", "bridge_sprites", e.unit_number),
              machines = (function()
                local out = {}
                for _, m in pairs(s.find_entities_filtered{position = e.position, radius = 3, type = {"assembling-machine", "furnace"}}) do
                  table.insert(out, string.format("%s %.1f,%.1f", m.name, m.position.x - c.x, m.position.y - c.y))
                end
                return out
              end)(), at = {e.position.x - c.x, e.position.y - c.y}}
          elseif e.position.y - c.y > 5 then held[k] = {status = STATUS[e.status], products = e.products_finished, spent = e.get_item_count("es-spent-coal"),
              fluids = e.type ~= "furnace" and e.get_fluid_contents() or nil, coal = e.get_item_count("coal"),
              output = e.get_output_inventory().get_contents(),
              trash = e.type == "assembling-machine" and e.get_inventory(defines.inventory.assembling_machine_trash)
                and e.get_inventory(defines.inventory.assembling_machine_trash).get_contents() or nil,
              dose = remote.call("empirical-science-scenes", "dose_of", e.unit_number)}
            local before = SHOWN and SHOWN[e.unit_number] or 0
            held[k].made_while_shown = e.products_finished - before
            -- (A refinery waits for residue between batches: anything made since the scene was built counts, or
            -- some of an ingredient held: connected and fed, a batch not yet gathered.)
            local fed = false
            local r = e.get_recipe()
            for _, ing in ipairs(r and r.ingredients or {}) do
              if ing.type == "item" and e.get_item_count(ing.name) > 0 then fed = true end
            end
            if AUGMENT and e.products_finished <= 0 and held[k].status ~= "full_output" and not fed then
              table.insert(problems, k .. " " .. tostring(held[k].status))
            end
          end
        end
      end
      table.insert(out, {held = held, on_belts = on_belts, surface = s.name, center = c, daytime = s.daytime, counts = counts, machines = machines})
    end
  end
  helpers.write_file("scene-survey.json", helpers.table_to_json(out))
  -- A guard, not a report: written first, so a failure leaves its evidence.
  if #problems > 0 then error("district machines not running: " .. table.concat(problems, "; ")) end
end
-- With the mod loaded (scripts/scene_survey.sh --augment <scene>), the scene as the mod's menu shows it.
script.on_init(function()
  if AUGMENT and remote.interfaces["empirical-science-scenes"] then
    for _, s in pairs(game.surfaces) do
      local logo = s.find_entities_filtered{name = "factorio-logo-11tiles", limit = 1}[1]
      if logo then
        local built = remote.call("empirical-science-scenes", "augment_showcase", AUGMENT, s.name,
          {logo.position.x, logo.position.y + 9.75})
        log("augmented: " .. serpent.line(built))
        local c0 = {x = math.floor(logo.position.x), y = math.floor(logo.position.y + 9.75)}
        for y = 21, 45 do
          local row = ""
          for x = -16, 2 do
            row = row .. (s.can_place_entity{name = "transport-belt", position = {c0.x + x + 0.5, c0.y + y + 0.5}, force = "player"} and "." or "#")
          end
          log("rowmap " .. y .. " " .. row)
        end
        for _, e in pairs(s.find_entities_filtered{area = {{c0.x - 13, c0.y + 21}, {c0.x + 1, c0.y + 30}}}) do
          if e.type ~= "tree" and e.type ~= "simple-entity" then
            log(string.format("source %s %.1f,%.1f dir %s %s", e.name, e.position.x - c0.x, e.position.y - c0.y,
              tostring(e.direction), e.type == "loader-1x1" and e.loader_type or ""))
          end
        end
        -- A guard, not a report: every piece placed, every machine dosed.
        if #(built.failed or {}) > 0 or (built.dosed or 0) == 0 then error("augmentation incomplete: " .. serpent.line(built)) end
      end
    end
  end
  if not AUGMENT then survey() end
end)
-- Augmented, the scene runs as the menu plays it, then is surveyed.
if AUGMENT then
  -- As the menu plays it: ten seconds' warm-up, then ten seconds shown (the save starts at its own tick).
  -- A machine is alive if it made something since the scene was built (or is backed up behind its output);
  -- what it made in the ten seconds shown is reported.
  local calls = 0
  script.on_nth_tick(5, function()
    calls = calls + 1
    if calls == 120 then
      SHOWN = {}
      for _, s in pairs(game.surfaces) do
        for _, e in pairs(s.find_entities_filtered{type = {"assembling-machine", "furnace"}}) do
          SHOWN[e.unit_number] = e.products_finished
        end
      end
    end
    if calls == 240 then survey() end
  end)
end
