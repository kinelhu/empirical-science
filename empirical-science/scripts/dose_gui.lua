-- Dose panel, attached to the right of an assembler's (or furnace's, or test bench's) own window:
-- what the machine makes or tests, a preset, its composition (a slot per additive, like a filter
-- slot, a dose field and the dose's maximum), circuit mode, and whether the last crafts were dosed.
-- Built once on open; refresh only rewrites what changed.
local shared = require("shared")
local dosing = require("scripts.dosing")

local dose_gui = {}

local ANCHORS = {["assembling-machine"] = defines.relative_gui_type.assembling_machine_gui,
                 furnace = defines.relative_gui_type.furnace_gui}

local function sprite_of(name)
  return (shared.additive(name).fluid and "fluid/" or "item/") .. name
end

local function localised(name)
  return shared.additive(name).fluid and prototypes.fluid[name].localised_name or prototypes.item[name].localised_name
end

-- The machine's rows as a fixed array of shared.hopper.rows entries ({} when empty).
local function rows_of(entity)
  local rows = {}
  local stored = dosing.rows(entity.unit_number)
  for i = 1, shared.hopper.rows do
    local r = stored[i]
    rows[i] = r and {name = r.name, dose = r.dose} or {}
  end
  return rows
end

-- Show one row: the slot's icon and tooltip, the dose, and the maximum.
local function show_row(panel, i, row, locked)
  local slot, field, limit = panel.rows["slot_" .. i], panel.rows["amount_" .. i], panel.rows["limit_" .. i]
  slot.sprite = row.name and sprite_of(row.name) or nil
  slot.tooltip = row.name and {"", localised(row.name), "\n", {"es.dose-slot-tooltip"}} or {"es.dose-slot-tooltip"}
  local text = row.dose and row.dose > 0 and tostring(row.dose) or ""
  if field.text ~= text then field.text = text end
  limit.caption = row.name and {"es.dose-max", shared.additive(row.name).max_dose} or ""
  slot.enabled, field.enabled = not locked, not locked and row.name ~= nil
end

function dose_gui.open(player, entity, visible)
  dose_gui.close(player)
  local anchor = ANCHORS[entity.type]
  if not anchor then return end
  local frame = player.gui.relative.add{type = "frame", name = "es_dose", direction = "vertical",
    caption = {"es.dose-title"}, anchor = {gui = anchor, position = defines.relative_gui_position.right}}
  local panel = frame.add{type = "frame", name = "panel", style = "inside_shallow_frame_with_padding",
    direction = "vertical"}
  local making = panel.add{type = "label", name = "making"}
  panel.add{type = "label", name = "residue"}  -- (0.68) what the dose leaves on the output, before any craft
  making.style.single_line = false
  making.style.maximal_width = 320
  local pflow = panel.add{type = "flow", name = "presetrow", direction = "horizontal"}
  pflow.style.vertical_align = "center"
  pflow.add{type = "label", caption = {"es.dose-preset"}, style = "caption_label"}
  pflow.add{type = "drop-down", name = "preset", items = {}, tags = {es_action = "dose-preset"}}
  local t = panel.add{type = "table", name = "rows", column_count = 3}
  t.style.horizontal_spacing = 8
  t.style.vertical_align = "center"
  for i = 1, shared.hopper.rows do
    t.add{type = "sprite-button", name = "slot_" .. i, style = "slot_button", tags = {es_action = "dose-slot", row = i}}
    local field = t.add{type = "textfield", name = "amount_" .. i, numeric = true, allow_decimal = false,
      allow_negative = false, tags = {es_action = "dose-amount", row = i}, tooltip = {"es.dose-amount-tooltip"}}
    field.style.width = 60
    t.add{type = "label", name = "limit_" .. i}
  end
  -- The additive picker: a grid of icons, shown under the rows while a slot is being chosen.
  local picker = panel.add{type = "frame", name = "picker", style = "inside_deep_frame", direction = "vertical"}
  picker.visible = false
  local grid = picker.add{type = "table", name = "grid", column_count = 8}
  for _, a in ipairs(visible) do
    grid.add{type = "sprite-button", sprite = sprite_of(a.name), style = "slot_button", tooltip = localised(a.name),
      tags = {es_action = "dose-pick", additive = a.name}}
  end
  grid.add{type = "sprite-button", sprite = "utility/close", style = "slot_button", tooltip = {"es.dose-clear"},
    tags = {es_action = "dose-pick", additive = ""}}
  local d = storage.doses[entity.unit_number]
  panel.add{type = "checkbox", name = "from_circuit", caption = {"es.dose-circuit"}, tooltip = {"es.dose-circuit-tooltip"},
    state = d and d.circuit or false, tags = {es_action = "dose-circuit"}}
  local status = panel.add{type = "label", name = "status"}
  status.style.single_line = false
  status.style.maximal_width = 320
  storage.dose_open[player.index] = {entity = entity, preset_signature = nil}
  local rows = rows_of(entity)
  local live = d and d.circuit and shared.stage_ok(entity.force, shared.circuit_tech)
  for i = 1, shared.hopper.rows do show_row(panel, i, rows[i], live) end
  dose_gui.refresh_player(player)
end

function dose_gui.close(player)
  if not player then return end
  local frame = player.gui.relative.es_dose
  if frame then frame.destroy() end
  storage.dose_open[player.index] = nil
end

function dose_gui.refresh_player(player, targets_by_recipe)
  local open = storage.dose_open[player.index]
  local frame = player.gui.relative.es_dose
  if not (open and frame and open.entity.valid) then return end
  local entity, panel = open.entity, frame.panel
  if targets_by_recipe then
    local recipe = entity.get_recipe()
    open.info = recipe and targets_by_recipe[recipe.name]
  end
  local info = open.info
  local testing = entity.name == "es-test-bench"
  local batch = info and (info.batch or (info.parent and info.parent.batch))
  panel.making.caption = info and {testing and "es.dose-testing" or "es.dose-making", shared.target_caption(info),
    tostring(batch or "?")} or (testing and not entity.get_recipe() and {"es.dose-no-recipe"}) or {"es.dose-not-target"}
  panel.making.tooltip = ""  -- (0.68: the line says it: "one dose per 10 products", "batches of 20")
  -- What the dose will leave on the output (shared.residues_of), so the sort can be built first.
  local leaves, seen = {""}, {}
  for _, row in ipairs(dosing.rows(entity.unit_number)) do
    if row.name and (row.dose or 0) > 0 then
      for _, r in ipairs(shared.residues_of(row.name)) do
        if not seen[r] then
          seen[r] = true
          table.insert(leaves, {"", #leaves > 1 and ", " or "", "[item=" .. r .. "] ", prototypes.item[r].localised_name})
        end
      end
    end
  end
  local settings = dosing.settings(entity.unit_number)
  panel.residue.visible = settings ~= nil and not settings.circuit
  panel.residue.caption = #leaves > 1 and {"es.dose-residue", leaves} or {"es.dose-residue-none"}
  -- Preset list: rebuilt only when the force's presets change (rebuilding an open drop-down closes it).
  local presets = dosing.presets(entity.force)
  if open.preset_signature ~= (storage.presets_version or 0) then
    local items = {{"es.dose-preset-choose"}}
    for _, p in ipairs(presets) do
      local parts = {""}
      for name, dose in pairs(p.mix) do table.insert(parts, "[img=" .. sprite_of(name) .. "]×" .. dose .. " ") end
      table.insert(items, {"", shared.target_caption(shared.target(p.target)), ":  ", parts})
    end
    panel.presetrow.preset.items = items
    panel.presetrow.preset.selected_index = 1
    open.preset_signature = storage.presets_version or 0
  end
  -- Staged reveal: rows past the first wait for Mixtures, circuit mode for Circuit instrumentation. A
  -- setting that arrived anyway (blueprint, paste) stays visible, and the status says why it waits.
  local d = storage.doses[entity.unit_number]
  local mixes_ok = shared.stage_ok(entity.force, shared.stages.mixtures.tech)
  local circuit_ok = shared.stage_ok(entity.force, shared.circuit_tech)
  local stored, named = rows_of(entity), 0
  for i = 1, shared.hopper.rows do
    if stored[i].name then named = named + 1 end
    -- One empty slot at a time: the next row shows once the one before is set.
    local show = i == 1 or stored[i].name ~= nil or (mixes_ok and stored[i - 1].name ~= nil)
    for _, part in ipairs({"slot_", "amount_", "limit_"}) do panel.rows[part .. i].visible = show end
  end
  panel.from_circuit.visible = circuit_ok or (d and d.circuit) or false
  -- A quality agent among the rows: products may come out a tier up (no promise how often: that is
  -- what experiments find), so the line downstream needs to sort them.
  local agent_dosed = false
  for i = 1, shared.hopper.rows do if stored[i].name and shared.is_agent(stored[i].name) then agent_dosed = true end end
  local waits = (d and d.circuit and not circuit_ok) and {"es.dose-needs-circuit", shared.tech_caption(shared.circuit_tech)}
    or (named > 1 and not mixes_ok) and {"es.dose-needs-mixtures", shared.tech_caption(shared.stages.mixtures.tech)} or nil
  -- In circuit mode the rows show the doses the wire sends now, and cannot be edited.
  if d and d.circuit and circuit_ok then
    local rows = dosing.rows_of(dosing.mix(entity.unit_number) or {})
    for i = 1, shared.hopper.rows do show_row(panel, i, rows[i] or {}, true) end
    panel.picker.visible = false
  end
  local n = 0
  for _ in pairs(dosing.hoppers_of(entity)) do n = n + 1 end
  local state = {"es.dose-state", n, dosing.mix(entity.unit_number) and (d.status or {"es.dose-waiting"}) or {"es.dose-off"}}
  -- (0.72) What this machine made with its dose, and how many of those the dose added (fewer, where it hurts).
  local c = storage.crafters and storage.crafters[entity.unit_number]
  if c and c.dose_made and c.dose_made > 0 and dosing.mix(entity.unit_number) then
    state = {"", state, "\n", {"es.dose-made", tostring(c.dose_made + (c.dose_extra or 0)),
      string.format("%+d", c.dose_extra or 0)}}
  end
  local caption = waits and {"", state, "\n", waits} or state
  panel.status.caption = agent_dosed and {"", caption, "\n", {"es.dose-agent"}} or caption
end

function dose_gui.refresh_all(targets_by_recipe)
  for player_index in pairs(storage.dose_open) do
    local player = game.get_player(player_index)
    if player then dose_gui.refresh_player(player, targets_by_recipe) else storage.dose_open[player_index] = nil end
  end
end

local function current(player)
  local open = storage.dose_open[player.index]
  local frame = player.gui.relative.es_dose
  if open and frame and open.entity.valid then return open, frame.panel end
end

-- Clear one row; the rows below move up, so no empty row is left between set ones.
local function clear_row(open, panel, row)
  local rows, kept = rows_of(open.entity), {}
  for i, r in ipairs(rows) do if i ~= row and r.name then table.insert(kept, r) end end
  for i = 1, shared.hopper.rows do rows[i] = kept[i] or {} end
  dosing.set_rows(open.entity, rows)
  for i = 1, shared.hopper.rows do show_row(panel, i, rows[i], false) end
end

-- A slot clicked: open (or close) the picker for that row. Right-click clears the row (the slots are
-- disabled while the circuit sets them, so this only happens when the rows are the player's).
function dose_gui.on_slot(player, row, button)
  local open, panel = current(player)
  if not open then return end
  if button == defines.mouse_button_type.right then
    clear_row(open, panel, row)
    panel.picker.visible, open.picking = false, nil
    dose_gui.refresh_player(player)
    return
  end
  local same = panel.picker.visible and open.picking == row
  panel.picker.visible = not same
  open.picking = not same and row or nil
end

-- An additive picked (or "" to clear the row): the row takes it, keeping its dose (1 if it had none).
function dose_gui.on_pick(player, name)
  local open, panel = current(player)
  if not (open and open.picking) then return end
  local rows = rows_of(open.entity)
  local row = rows[open.picking]
  if name == "" then
    clear_row(open, panel, open.picking)
  else
    row.name = name
    row.dose = math.min(row.dose and row.dose > 0 and row.dose or 1, shared.additive(name).max_dose)
    dosing.set_rows(open.entity, rows)
    show_row(panel, open.picking, rows[open.picking], false)
  end
  panel.picker.visible, open.picking = false, nil
  dose_gui.refresh_player(player)
end

-- A dose typed: clamped to the additive's maximum (shown beside the field).
function dose_gui.on_amount(player, row)
  local open, panel = current(player)
  if not open then return end
  local rows = rows_of(open.entity)
  local r = rows[row]
  if not r.name then return end
  local v = tonumber(panel.rows["amount_" .. row].text)
  r.dose = v and v > 0 and math.min(math.floor(v), shared.additive(r.name).max_dose) or 0
  dosing.set_rows(open.entity, rows)
  if v and v > r.dose then panel.rows["amount_" .. row].text = tostring(r.dose) end
  dose_gui.refresh_player(player)
end

-- A preset chosen: its composition becomes the machine's rows.
function dose_gui.on_preset(player, index)
  local open, panel = current(player)
  if not open then return end
  local p = dosing.presets(open.entity.force)[index - 1]
  if not p then return end
  local rows = dosing.rows_of(p.mix)
  dosing.set_rows(open.entity, rows)
  for i = 1, shared.hopper.rows do show_row(panel, i, rows[i] or {}, false) end
  panel.presetrow.preset.selected_index = 1
  dose_gui.refresh_player(player)
end

function dose_gui.on_circuit(player, state)
  local open, panel = current(player)
  if not open then return end
  dosing.set_circuit(open.entity, state)
  if not state then
    local rows = rows_of(open.entity)
    for i = 1, shared.hopper.rows do show_row(panel, i, rows[i], false) end
  end
  dose_gui.refresh_player(player)
end

return dose_gui
