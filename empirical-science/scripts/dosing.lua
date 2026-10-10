-- Dosing in production: every additive, raw or premixed, is dosed at the machine that makes the item.
-- A machine's composition is set in a panel on its own window (up to shared.hopper.rows additives);
-- hoppers touching the machine supply it, beacon-like (one hopper can serve several machines).
-- After crafts, the dose for the products made is taken from the hoppers (all or nothing); the
-- caller applies the composition's hidden effect only when it was supplied.
--   storage.hoppers[unit] = {entity, port, fluid}: a fluid hopper (0.71) is its own port; a hopper has none.
--   storage.doses[unit] = {entity, rows = {{name, dose}...}, acc = {name = owed fraction}, status}
local shared = require("shared")

local dosing = {}

-- table.deepcopy exists only in the data stage.
local function copy(t)
  if type(t) ~= "table" then return t end
  local out = {}
  for k, v in pairs(t) do out[k] = copy(v) end
  return out
end

dosing.HOPPER, dosing.FLUID_HOPPER = "es-hopper", "es-fluid-hopper"
dosing.HOPPERS = {dosing.HOPPER, dosing.FLUID_HOPPER}
dosing.IS_HOPPER = {[dosing.HOPPER] = true, [dosing.FLUID_HOPPER] = true}
dosing.PORT = "es-hopper-fluid-port"  -- (before 0.71, on every hopper; control.lua split_hoppers retires them)
local CRAFTING_TYPES = {["assembling-machine"] = true, furnace = true}

function dosing.init()
  storage.hoppers = storage.hoppers or {}
  storage.doses = storage.doses or {}
  storage.dose_open = storage.dose_open or {}
  storage.hopper_links = storage.hopper_links or {}
end

function dosing.is_machine(entity)
  -- Test benches too: a trial takes its dose the same way (supply_trial).
  return entity and entity.valid and CRAFTING_TYPES[entity.type]
end

---------------------------------------------------------------------------
-- Hoppers
---------------------------------------------------------------------------

function dosing.on_hopper_built(entity)
  local fluid = entity.name == dosing.FLUID_HOPPER
  storage.hoppers[entity.unit_number] = {entity = entity, port = fluid and entity or nil, fluid = fluid or nil}
  for unit in pairs(dosing.machines_of(entity)) do storage.hopper_links[unit] = nil end
  script.register_on_object_destroyed(entity)
  dosing.redraw(entity.unit_number)
end

-- Returns true when the unit was a hopper or a dosed machine (its record is removed).
function dosing.on_destroyed(unit)
  storage.hopper_links[unit] = nil
  local h = storage.hoppers[unit]
  if h then
    if h.port and h.port.valid and not h.fluid then h.port.destroy() end  -- (an old hopper's overlaid port)
    if h.reporter and h.reporter.valid then h.reporter.destroy() end  -- its circuit report (0.49)
    if h.report_mark and h.report_mark.valid then h.report_mark.destroy() end
    storage.hoppers[unit] = nil
    return true
  end
  if storage.badges then storage.badges[unit] = nil end  -- (drawings on the entity go with it)
  if storage.trash_full then storage.trash_full[unit] = nil end
  if storage.residue_acc then storage.residue_acc[unit] = nil end
  if storage.doses[unit] then
    storage.doses[unit] = nil
    return false  -- the machine is also a crafter: let the caller clean that up too
  end
  return false
end

-- Crafting machines sharing an edge with a hopper (not diagonal); a fluid hopper is 1x2 (0.71).
function dosing.machines_of(hopper)
  local box = hopper.bounding_box
  local l, t = math.floor(box.left_top.x + 0.5), math.floor(box.left_top.y + 0.5)
  local r, b = math.ceil(box.right_bottom.x - 0.5), math.ceil(box.right_bottom.y - 0.5)
  local found = {}
  for _, area in ipairs({{{l - 0.6, t + 0.1}, {r + 0.6, b - 0.1}}, {{l + 0.1, t - 0.6}, {r - 0.1, b + 0.6}}}) do
    for _, m in pairs(hopper.surface.find_entities_filtered{type = {"assembling-machine", "furnace"}, area = area,
        force = hopper.force}) do
      found[m.unit_number] = m
    end
  end
  return found
end

-- Draw a short chute from a hopper into each machine it serves, like connected pieces (redrawn when
-- either side is built or removed; the drawings go with the hopper).
function dosing.redraw(unit)
  local h = storage.hoppers[unit]
  if not (h and h.entity.valid) then return end
  for _, obj in ipairs(h.chutes or {}) do if obj.valid then obj.destroy() end end
  for _, obj in ipairs(h.bridges or {}) do if obj.valid then obj.destroy() end end
  h.chutes, h.bridges = {}, {}
  local p = h.entity.position
  -- The hopper's tiles (a fluid hopper has two): each machine's joint is drawn from the one nearest its middle.
  local box = h.entity.bounding_box
  local tiles = {}
  for x = math.floor(box.left_top.x + 0.5), math.ceil(box.right_bottom.x - 0.5) - 1 do
    for y = math.floor(box.left_top.y + 0.5), math.ceil(box.right_bottom.y - 0.5) - 1 do
      table.insert(tiles, {x = x + 0.5 - p.x, y = y + 0.5 - p.y})
    end
  end
  for _, m in pairs(dosing.machines_of(h.entity)) do
    local mb = m.bounding_box
    local tile = tiles[1]
    for _, t in ipairs(tiles) do
      local function far(u) return (p.x + u.x - m.position.x) ^ 2 + (p.y + u.y - m.position.y) ^ 2 end
      if far(t) < far(tile) then tile = t end
    end
    local tx, ty = p.x + tile.x, p.y + tile.y
    local horizontal = tx < mb.left_top.x or tx > mb.right_bottom.x   -- (the machine beside, not above or below)
    local dx, dy = m.position.x - tx, m.position.y - ty
    local offset = horizontal and {tile.x + (dx > 0 and 0.5 or -0.5), tile.y} or {tile.x, tile.y + (dy > 0 and 0.5 or -0.5)}
    table.insert(h.chutes, rendering.draw_sprite{sprite = horizontal and "es-chute-h" or "es-chute-v",
      target = {entity = h.entity, offset = offset}, surface = h.entity.surface,
      -- Under both buildings (below the entity layer, above shadows): only the part in the gap between
      -- them shows, so it reads as a pipe running from one into the other.
      -- Untinted: only a sliver shows, where a tint reads as dirt, not as a signal (tried, 2026-09-30).
      render_layer = "lower-object-above-shadow"})
    -- And over the seam (0.63, user: the hopper read as a separate box): vanilla's flanged joint, drawn as an
    -- assembler draws one for a pipe connected on that side: the machine's side facing the hopper, anchored on
    -- the outside tile (the hopper's), its own offset pulling it onto the machine's edge (0.64: anchored on
    -- the machine's tile with the hopper's side, it sat on the hopper's face; seen in a sprite collage).
    local side = horizontal and (dx > 0 and "west" or "east") or (dy > 0 and "north" or "south")
    -- Above objects (0.71, user: hoppers looked disconnected): on the object layer the game sorts by depth, and
    -- a machine whose middle is lower on screen than the hopper was drawn over its own joint.
    table.insert(h.bridges, rendering.draw_sprite{sprite = "es-bridge-" .. side,
      target = {entity = h.entity, offset = {tile.x, tile.y}}, surface = h.entity.surface,
      render_layer = "higher-object-under"})
    -- A machine to the north: its joint reaches over the hopper's top rim; the rim is drawn again on top, so
    -- the hopper's ridge hides the joint's end as a chest's lid would (0.70, user).
    if side == "south" and not h.fluid then
      table.insert(h.bridges, rendering.draw_sprite{sprite = "es-hopper-rim",
        target = {entity = h.entity},
        surface = h.entity.surface, render_layer = "higher-object-under"})
    end
  end
end

-- Hoppers to redraw once a machine next to them has gone (its removal completes after the event).
-- Also drops the machine's cached hoppers (on build there is none yet; on removal it goes).
function dosing.mark_neighbours(machine)
  storage.chute_dirty = storage.chute_dirty or {}
  for unit in pairs(dosing.hoppers_of(machine)) do storage.chute_dirty[unit] = true end
  storage.hopper_links[machine.unit_number] = nil
end

function dosing.redraw_dirty()
  if not (storage.chute_dirty and next(storage.chute_dirty)) then return end
  for unit in pairs(storage.chute_dirty) do dosing.redraw(unit) end
  storage.chute_dirty = {}
end

-- Hoppers sharing an edge with a machine (not diagonal), keyed by unit number. Cached per machine
-- (storage.hopper_links): a new hopper clears its neighbours' entries, a removed machine its own, and
-- an entry holding a hopper that is gone is searched again.
local function search_hoppers(machine)
  local box = machine.bounding_box
  local l, t, r, b = box.left_top.x, box.left_top.y, box.right_bottom.x, box.right_bottom.y
  local found = {}
  for _, area in ipairs({{{l - 0.9, t + 0.1}, {r + 0.9, b - 0.1}}, {{l + 0.1, t - 0.9}, {r - 0.1, b + 0.9}}}) do
    for _, h in pairs(machine.surface.find_entities_filtered{name = dosing.HOPPERS, area = area,
        force = machine.force}) do
      found[h.unit_number] = h
    end
  end
  return found
end

-- The machine's hoppers, from a cached search.
function dosing.hoppers_of(machine)
  local unit = machine.unit_number
  local cached = storage.hopper_links[unit]
  if cached and cached.supply then
    local ok = true
    for _, h in pairs(cached.supply) do if not h.valid then ok = false end end
    if ok then return cached.supply end
  end
  local supply = search_hoppers(machine)
  storage.hopper_links[unit] = {supply = supply}
  return supply
end

local function icon(name)
  return (shared.additive(name).fluid and "[fluid=" or "[item=") .. name .. "]"
end

-- Take amounts {name = n} from the machine's hoppers, all or nothing (items at normal quality).
-- `require` {name = n} is what must be present for the dose to count (at least what is taken; more
-- when a fraction is owed, so an additive that is absent never doses). Returns true, or false and
-- the reason ("none" or the missing additive).
-- Residues leave by the machine's trash slots (0.65, as spoilage does), taken out by its
-- output inserter with the products. Full: the dose waits (nothing taken, nothing lost), the machine runs
-- plain, shows vanilla's warning icon and its panel names the residue. storage.trash_full: unit -> residue.
local function mark_trash_full(machine, residue)
  storage.trash_full = storage.trash_full or {}
  local rec = storage.trash_full[machine.unit_number]
  if rec and rec.warn and rec.warn.valid then rec.residue = residue return end
  storage.trash_full[machine.unit_number] = {residue = residue, warn = rendering.draw_sprite{
    sprite = "utility/warning_icon", target = machine, surface = machine.surface, x_scale = 0.8, y_scale = 0.8,
    render_layer = "entity-info-icon"}}
end
local function clear_trash_full(machine)
  local rec = storage.trash_full and storage.trash_full[machine.unit_number]
  if not rec then return end
  if rec.warn and rec.warn.valid then rec.warn.destroy() end
  storage.trash_full[machine.unit_number] = nil
end

-- An additive counts at any quality (decided: ingredient quality does not change an additive's effect;
-- a bare name means normal quality only, which left uncommon uranium unused, outside review 2026-10-02).
-- Normal first, then by level.
local qualities
local function quality_names()
  if not qualities then
    qualities = {}
    for name, q in pairs(prototypes.quality) do
      if name ~= "quality-unknown" then table.insert(qualities, {name = name, level = q.level}) end
    end
    table.sort(qualities, function(a, b) return a.level < b.level end)
    for i, q in ipairs(qualities) do qualities[i] = q.name end
  end
  return qualities
end
-- With `enough`, stops counting once that many are found (normal quality usually is: one call, not five;
-- counting every quality on every check cost 0.03 ms/tick in the perf scenario).
function dosing.count_any(inv, name, enough)
  local n = 0
  for _, q in ipairs(quality_names()) do
    n = n + inv.get_item_count({name = name, quality = q})
    if enough and n >= enough then return n end
  end
  return n
end
local function remove_any(inv, name, count)
  local got = 0
  for _, q in ipairs(quality_names()) do
    if got >= count then break end
    got = got + inv.remove{name = name, count = count - got, quality = q}
  end
  return got
end

local take
-- (Exposed for tests: a dose taken from a machine's hoppers, 0.61.)
-- A hopper that hands out a dose shows it (0.72): the iris of an item hopper closes and opens again, a fluid
-- hopper's pump turns. One run at a time, drawn over its still picture (data.lua: the hoppers' animations);
-- the drawing lives a cycle and goes with the hopper.
local DIRECTION_NAMES = {[defines.direction.north] = "north", [defines.direction.east] = "east",
  [defines.direction.south] = "south", [defines.direction.west] = "west"}
local function animate(unit)
  local rec = storage.hoppers[unit]
  if not (rec and rec.entity.valid) or (rec.anim and rec.anim.valid) then return end
  local e = rec.entity
  -- (The iris on the hatch layer: on the chest's own layer, the chest's picture drew over it.)
  local name, speed, frames, layer = "es-hopper-iris", 0.25, 14, "cargo-hatch"
  if rec.fluid then
    name, speed, frames, layer = "es-fluid-hopper-" .. (DIRECTION_NAMES[e.direction] or "north"), 0.5, 32, "object"
  end
  rec.anim = rendering.draw_animation{animation = name, target = e, surface = e.surface, render_layer = layer,
    animation_speed = speed, animation_offset = -(game.tick * speed) % frames, time_to_live = math.ceil(frames / speed)}
end

function dosing.take(...) return take(...) end
take = function(machine, needs, require)
  local hoppers = dosing.hoppers_of(machine)
  if not next(hoppers) then clear_trash_full(machine); return false, "none" end
  -- Room for the residues first, all of them together (they share the trash slots; review 0.68: checked one
  -- by one, a third kind or two additives of one family could pass and then be lost): a dose whose residues
  -- cannot leave is not taken.
  local trash = machine.get_inventory(defines.inventory.crafter_trash)
  -- Whole residues only; a slurry's share carries over to the next dose (storage.residue_acc).
  storage.residue_acc = storage.residue_acc or {}
  local acc = storage.residue_acc[machine.unit_number] or {}
  local want, owed = {}, {}
  for name, amount in pairs(needs) do
    if amount > 0 then
      for residue, share in pairs(shared.residue_shares(name)) do owed[residue] = (owed[residue] or 0) + amount * share end
    end
  end
  for residue, x in pairs(owed) do
    local total = (acc[residue] or 0) + x
    local whole = math.floor(total + 1e-9)
    owed[residue] = total - whole
    if whole > 0 then want[residue] = whole end
  end
  if next(want) then
    local empty = trash and trash.count_empty_stacks() or 0
    local free = empty
    for residue, amount in pairs(want) do
      local size = prototypes.item[residue].stack_size
      local partial = trash and (trash.get_insertable_count(residue) - empty * size) or 0  -- room in its own stacks
      local left = amount - math.max(0, partial)
      if left > 0 then free = free - math.ceil(left / size) end
      if free < 0 then
        mark_trash_full(machine, residue)
        return false, "spent:" .. residue
      end
    end
  end
  clear_trash_full(machine)
  for name, amount in pairs(require or needs) do
    if amount > 0 then
      local fluid, have = shared.additive(name).fluid, 0
      for unit, h in pairs(hoppers) do
        local rec = storage.hoppers[unit]
        if fluid then
          -- (A chilled twin counts as its fluid, 0.61.)
          local twin = shared.chilled_twin(name)
          have = have + (rec and rec.port and rec.port.valid and (rec.port.get_fluid_count(name)
            + (twin and rec.port.get_fluid_count(twin) or 0)) or 0)
        elseif not (rec and rec.fluid) then
          have = have + dosing.count_any(h.get_inventory(defines.inventory.chest), name, amount - have)
        end
      end
      if have < amount then return false, name end
    end
  end
  -- Fluids carry a temperature (liquid premixes care): the amount-weighted temperature of what is taken.
  local temps = {}
  for name, amount in pairs(needs) do
    local left, fluid = amount, shared.additive(name).fluid
    local heat, taken = 0, 0
    for unit, h in pairs(hoppers) do
      if left <= 0 then break end
      if fluid then
        local rec = storage.hoppers[unit]
        if rec and rec.port and rec.port.valid then
          for _, n in ipairs({name, shared.chilled_twin(name)}) do  -- (nil ends the list without a twin)
            local f = rec.port.fluidbox[1]
            local got = left > 0 and rec.port.remove_fluid{name = n, amount = left} or 0
            if got > 0 and f and f.name == n then heat, taken = heat + f.temperature * got, taken + got end
            left = left - got
            if got > 0 then animate(unit) end
          end
        end
      elseif storage.hoppers[unit] and storage.hoppers[unit].fluid then
        -- (A fluid hopper holds no items.)
      elseif shared.additive(name).living then
        -- Ripeness (0.62): the units' mean spoil fraction, read from the stacks they leave.
        local inv = h.get_inventory(defines.inventory.chest)
        for i = 1, #inv do
          if left <= 0 then break end
          local s = inv[i]
          if s.valid_for_read and s.name == name then
            local k = math.min(s.count, left)
            heat, taken = heat + (s.spoil_percent or 0) * k, taken + k
            s.count = s.count - k
            left = left - k
            animate(unit)
          end
        end
      else
        local got = remove_any(h.get_inventory(defines.inventory.chest), name, left)
        left = left - got
        if got > 0 then animate(unit) end
      end
    end
    if taken > 0 then temps[name] = heat / taken end
  end
  -- Residues (one per solid member per unit dosed, shared.residues_of) into the machine's trash slots (room
  -- checked above). Made by script, so recorded: a byproduct belongs in the production graph (and the dose
  -- picker offers a residue once some has been made).
  for residue, amount in pairs(want) do
    local put = trash.insert{name = residue, count = amount}
    if put > 0 then machine.force.get_item_production_statistics(machine.surface).on_flow(residue, put) end
  end
  for residue, rest in pairs(owed) do acc[residue] = rest end
  storage.residue_acc[machine.unit_number] = next(acc) and acc or nil
  return true, nil, temps
end

-- Doses from circuit signals on the machine (its circuit mode): value = dose, clamped to the maximum.
local function circuit_mix(entity)
  local ids = {}
  for _, id in ipairs({defines.wire_connector_id.circuit_red, defines.wire_connector_id.circuit_green}) do
    if entity.get_circuit_network(id) then table.insert(ids, id) end
  end
  if #ids == 0 then return nil end
  local mix
  local agents_ok = shared.stages.quality and shared.stage_ok(entity.force, shared.stages.quality.tech)
  -- Every signal in one call (0.49; was one get_signal per additive). The optional second connector
  -- must be omitted, not passed as nil.
  local signals = #ids == 2 and entity.get_signals(ids[1], ids[2]) or entity.get_signals(ids[1])
  for _, sg in ipairs(signals or {}) do
    -- Normal-quality signals only, as the per-additive read saw them.
    local q = sg.signal.quality
    local a = sg.count > 0 and (q == nil or q == "normal") and shared.additive(sg.signal.name)
    if a and (sg.signal.type or "item") == shared.signal_type(a.name) and (agents_ok or not a.agent)
        and shared.unlocked(entity.force, a) then
      mix = mix or {}; mix[a.name] = math.min(sg.count, a.max_dose)
    end
  end
  return mix
end

-- A machine's composition {name = dose}: from circuit signals in circuit mode, else merged from its
-- rows (nil when empty).
-- Staged reveal: circuit mode needs Circuit instrumentation; more than one additive needs Mixtures (a
-- blueprint or pasted settings may carry them: they wait, the panel says why).
function dosing.mix(unit)
  local d = storage.doses[unit]
  if not d then return nil end
  local force = d.entity.valid and d.entity.force
  if d.circuit then
    return force and shared.stage_ok(force, shared.circuit_tech) and circuit_mix(d.entity) or nil
  end
  local one = not (force and shared.stage_ok(force, shared.stages.mixtures.tech))
  local agents_ok = shared.stages.quality and force and shared.stage_ok(force, shared.stages.quality.tech)
  local mix, any = {}, false
  for _, row in ipairs(d.rows or {}) do
    if row.name and row.dose and row.dose > 0 and not (one and any)
        and (agents_ok or not shared.is_agent(row.name))
        and (not force or shared.unlocked(force, shared.additive(row.name))) then
      mix[row.name] = (mix[row.name] or 0) + row.dose; any = true
    end
  end
  return any and mix or nil
end

-- Supply the dose for `products` made: a dose is units per batch of products (the target's trial
-- batch), the same on a line as on a bench. Returns the composition when it was supplied, else nil
-- (the craft had no additive).
-- Alt mode (0.67): a dosed machine or bench shows
-- its dose (each additive's icon and units) along its bottom-left, greyed while the dose is not supplied.
-- Redrawn only when the dose or its supply changes. storage.badges: unit -> {sig, ids}.
local GREYED = {r = 0.45, g = 0.45, b = 0.45, a = 0.8}
function dosing.badges(machine, mix, starved)
  storage.badges = storage.badges or {}
  local unit = machine.unit_number
  if not mix and not storage.badges[unit] then return end  -- (every second for every undosed target machine)
  local names = {}
  for name, dose in pairs(mix or {}) do if dose > 0 then table.insert(names, name) end end
  table.sort(names)
  local parts = {}
  for _, name in ipairs(names) do table.insert(parts, name .. ":" .. mix[name]) end
  local sig = table.concat(parts, "+") .. (starved and "!" or "")
  local old = storage.badges[unit]
  if old and old.sig == sig then return end
  for _, obj in ipairs(old and old.ids or {}) do if obj.valid then obj.destroy() end end
  if #names == 0 then storage.badges[unit] = nil; return end
  local ids = {}
  local box = machine.prototype.selection_box
  local x0, y = box.left_top.x + 0.35, box.right_bottom.y - 0.4
  for i, name in ipairs(names) do
    local fluid = shared.additive(name) and shared.additive(name).fluid
    local x = x0 + (i - 1) * 0.75
    table.insert(ids, rendering.draw_sprite{sprite = (fluid and "fluid/" or "item/") .. name, target = {entity = machine,
      offset = {x, y}}, surface = machine.surface, x_scale = 0.4, y_scale = 0.4, only_in_alt_mode = true,
      tint = starved and GREYED or nil, render_layer = "entity-info-icon"})
    table.insert(ids, rendering.draw_text{text = tostring(mix[name]), target = {entity = machine, offset = {x + 0.18, y - 0.05}},
      surface = machine.surface, color = starved and GREYED or {1, 1, 1}, scale = 0.7, only_in_alt_mode = true,
      alignment = "left", vertical_alignment = "middle", render_layer = "entity-info-icon"})
  end
  storage.badges[unit] = {sig = sig, ids = ids}
end

function dosing.supply(machine, products, batch)
  local d = storage.doses[machine.unit_number]
  local mix = dosing.mix(machine.unit_number)
  if not mix then dosing.badges(machine, nil); clear_trash_full(machine); return nil end
  d.acc = d.acc or {}
  local needs, want, present = {}, {}, {}
  for name, dose in pairs(mix) do
    want[name] = (d.acc[name] or 0) + dose * products / batch
    needs[name] = math.floor(want[name])
    present[name] = math.max(1, math.ceil(want[name]))
  end
  local ok, why, temps = take(machine, needs, present)
  if not ok then
    d.status = why == "none" and {"es.dose-no-hopper"}
      or why:find("^spent:") and {"es.dose-spent-full", "[item=" .. why:sub(7) .. "]"} or {"es.dose-missing", icon(why)}
    dosing.badges(machine, mix, true)
    return nil
  end
  dosing.badges(machine, mix, false)
  for name in pairs(mix) do d.acc[name] = want[name] - needs[name] end
  d.status = {"es.dose-ok"}
  -- A craft that drew no whole unit this time runs at the temperature last taken.
  d.temps = d.temps or {}
  for name, t in pairs(temps or {}) do d.temps[name] = t end
  return mix, d.temps
end

-- A trial takes its whole dose at once (units per trial batch). Returns the composition supplied, or
-- nil: the trial ran without it (a control), and the status says why.
function dosing.supply_trial(machine)
  local d = storage.doses[machine.unit_number]
  local mix = dosing.mix(machine.unit_number)
  if not mix then dosing.badges(machine, nil); clear_trash_full(machine); return nil end
  local needs = {}
  for name, dose in pairs(mix) do needs[name] = dose end
  local ok, why, temps = take(machine, needs)
  if not ok then
    d.status = why == "none" and {"es.dose-no-hopper"}
      or why:find("^spent:") and {"es.dose-spent-full", "[item=" .. why:sub(7) .. "]"} or {"es.dose-missing", icon(why)}
    dosing.badges(machine, mix, true)
    return nil
  end
  dosing.badges(machine, mix, false)
  d.status = {"es.dose-ok"}
  return mix, temps
end

-- Rows naming an additive this version does not have (a removed premix, from an old save, blueprint
-- or copied settings) become empty rows, in place.
local function known(rows)
  local out = {}
  for i, r in ipairs(rows) do out[i] = r.name and not shared.additive(r.name) and {} or copy(r) end
  return out
end

-- Settings: rows {{name, dose}...} and circuit mode. Empty settings remove the record.
function dosing.set(entity, settings)
  if not dosing.is_machine(entity) then return end
  local unit = entity.unit_number
  local rows, circuit = known(settings and settings.rows or {}), settings and settings.circuit or nil
  local any = false
  for _, r in ipairs(rows) do any = any or r.name ~= nil end
  if not any and not circuit then storage.doses[unit] = nil; dosing.badges(entity, nil); return end
  local d = storage.doses[unit] or {entity = entity, acc = {}}
  d.rows, d.circuit = rows, circuit
  storage.doses[unit] = d
  dosing.badges(entity, dosing.mix(unit), false)
end

function dosing.set_rows(entity, rows)
  local d = storage.doses[entity.unit_number]
  dosing.set(entity, {rows = rows, circuit = d and d.circuit})
end

function dosing.set_circuit(entity, on)
  dosing.set(entity, {rows = dosing.rows(entity.unit_number), circuit = on or nil})
end

function dosing.settings(unit)
  local d = storage.doses[unit]
  return d and {rows = copy(d.rows or {}), circuit = d.circuit}
end

function dosing.rows(unit) return storage.doses[unit] and storage.doses[unit].rows or {} end

---------------------------------------------------------------------------
-- Presets: compositions saved at a station ("save composition"), offered by every dose panel of the
-- force. Nothing is gated by them: they are how a finding becomes an intention.
--   storage.presets[force_index] = {{target = key, mix = {name = dose}}...}
---------------------------------------------------------------------------

local function same_mix(a, b)
  for k, v in pairs(a) do if b[k] ~= v then return false end end
  for k, v in pairs(b) do if a[k] ~= v then return false end end
  return true
end

function dosing.presets(force)
  storage.presets = storage.presets or {}
  storage.presets[force.index] = storage.presets[force.index] or {}
  return storage.presets[force.index]
end

-- Returns true when added, false when the same composition for the same target was already saved.
function dosing.add_preset(force, target_key, mix)
  local list = dosing.presets(force)
  for _, p in ipairs(list) do if p.target == target_key and same_mix(p.mix, mix) then return false end end
  table.insert(list, {target = target_key, mix = copy(mix)})
  storage.presets_version = (storage.presets_version or 0) + 1
  return true
end

-- On load: settings and presets naming additives this version does not have (premixes were per family
-- pair before 0.19) lose those rows; a preset with any unknown additive is dropped.
function dosing.prune()
  for unit, d in pairs(storage.doses) do
    if d.entity.valid then dosing.set(d.entity, {rows = d.rows or {}, circuit = d.circuit}) else storage.doses[unit] = nil end
  end
  for _, list in pairs(storage.presets or {}) do
    for i = #list, 1, -1 do
      for name in pairs(list[i].mix) do
        if not shared.additive(name) then table.remove(list, i); break end
      end
    end
  end
  storage.presets_version = (storage.presets_version or 0) + 1
end

function dosing.remove_preset(force, index)
  table.remove(dosing.presets(force), index)
  storage.presets_version = (storage.presets_version or 0) + 1
end

-- Rows for a preset's composition (at most shared.hopper.rows additives, the strongest doses first).
function dosing.rows_of(mix)
  local rows = {}
  for name, dose in pairs(mix) do table.insert(rows, {name = name, dose = dose}) end
  table.sort(rows, function(x, y) return x.dose > y.dose or (x.dose == y.dose and x.name < y.name) end)
  while #rows > shared.hopper.rows do table.remove(rows) end
  return rows
end

---------------------------------------------------------------------------
-- Copy-paste and blueprints: a machine's rows travel like a vanilla setting.
---------------------------------------------------------------------------

function dosing.on_settings_pasted(event)
  local src, dst = event.source, event.destination
  if not (dosing.is_machine(src) and dosing.is_machine(dst)) then return end
  dosing.set(dst, dosing.settings(src.unit_number))
end

function dosing.on_built_with_tags(entity, tags)
  if tags and tags.es_dose then dosing.set(entity, tags.es_dose) end
end

return dosing
