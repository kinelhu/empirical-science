-- Hopper reports (0.49): an opt-in hidden combinator on a hopper that
-- tells the circuit network about the machines it supplies. es-fed / es-starved: machines on its edges
-- whose last craft was dosed / ran plain for want of an additive (or of a hopper); each additive's
-- signal: units short of one batch for every dosed machine it supplies, after what the hopper holds
-- (for requesters and trains); es-spent: machines it supplies whose dose waits for room for their residues. Written once a second,
-- only when a value changed. Vanilla "read contents" on the hopper itself still shows what it holds.
local shared = require("shared")
local dosing = require("scripts.dosing")

local report = {}
report.NAME = "es-hopper-reporter"

local MACHINE_TTL = 600  -- ticks a hopper's machine list is kept before it is searched again

local function sig(type, name, value)
  return {value = {type = type, name = name, quality = "normal"}, min = value}
end

-- Turn a hopper's report on (creating its combinator and a small mark) or off.
function report.set(unit, on)
  local rec = storage.hoppers[unit]
  if not (rec and rec.entity.valid) then return end
  if on and not (rec.reporter and rec.reporter.valid) then
    local h = rec.entity
    local c = h.surface.create_entity{name = report.NAME, position = h.position, force = h.force}
    if not c then return end
    c.destructible = false
    rec.reporter, rec.report_last = c, nil
    storage.report_buckets = storage.report_buckets or {}
    local b = unit % 60
    storage.report_buckets[b] = storage.report_buckets[b] or {}
    storage.report_buckets[b][unit] = true
    rec.report_mark = rendering.draw_sprite{sprite = "item/constant-combinator", target = {entity = h, offset = {0.25, 0.25}},
      surface = h.surface, x_scale = 0.3, y_scale = 0.3, render_layer = "entity-info-icon"}
  elseif not on then
    if rec.reporter and rec.reporter.valid then rec.reporter.destroy() end
    if rec.report_mark and rec.report_mark.valid then rec.report_mark.destroy() end
    rec.reporter, rec.report_mark, rec.report_last, rec.report_machines = nil, nil, nil, nil
    local b = storage.report_buckets and storage.report_buckets[unit % 60]
    if b then b[unit] = nil end
  end
end

function report.is_on(unit)
  local rec = storage.hoppers[unit]
  return rec and rec.reporter and rec.reporter.valid or false
end

function report.hopper_of(reporter)
  for _, rec in pairs(storage.hoppers) do if rec.reporter == reporter then return rec.entity end end
end

-- What a hopper holds of an additive (items in a hopper, fluid in a fluid hopper).
local function held(rec, name, enough)
  if shared.additive(name).fluid or rec.fluid then
    if not (shared.additive(name).fluid and rec.port and rec.port.valid) then return 0 end
    local twin = shared.chilled_twin(name)  -- (a chilled twin counts as its fluid, as dosing.take counts it)
    return rec.port.get_fluid_count(name) + (twin and rec.port.get_fluid_count(twin) or 0)
  end
  return dosing.count_any(rec.entity.get_inventory(defines.inventory.chest), name, enough)
end

local function machines(rec, tick)
  if not rec.report_machines or tick - rec.report_machines.tick > MACHINE_TTL then
    rec.report_machines = {tick = tick, list = dosing.machines_of(rec.entity)}
  end
  return rec.report_machines.list
end

-- The signals one hopper reports now.
function report.signals(rec, tick)
  local fed, starved, paused, need = 0, 0, 0, {}
  for unit, m in pairs(machines(rec, tick)) do
    local d = m.valid and storage.doses[unit]
    local mix = d and dosing.mix(unit)
    if mix then
      local key = d.status and d.status[1]
      if key == "es.dose-ok" or key == "es.dose-capped" then fed = fed + 1
      elseif key == "es.dose-missing" or key == "es.dose-no-hopper" then starved = starved + 1
      elseif key == "es.dose-spent-full" then paused = paused + 1 end  -- (0.65: its residues have no room)
      for name, dose in pairs(mix) do need[name] = (need[name] or 0) + dose end
    end
  end
  local out = {}
  if fed > 0 then table.insert(out, sig("virtual", "es-fed", fed)) end
  if starved > 0 then table.insert(out, sig("virtual", "es-starved", starved)) end
  for name, n in pairs(need) do
    local short = math.ceil(n - held(rec, name, n))  -- counting stops once the need is met
    if short > 0 then table.insert(out, sig(shared.signal_type(name), name, short)) end
  end
  if paused > 0 then table.insert(out, sig("virtual", "es-spent", paused)) end
  return out
end

-- A cheap fingerprint of a report, to write only on change (serpent cost too much at 400 hoppers).
local function fingerprint(out)
  local parts = {}
  for i, f in ipairs(out) do parts[i] = f.value.name .. "=" .. f.min end
  table.sort(parts)
  return table.concat(parts, ",")
end

-- Each tick, the reporting hoppers whose unit number falls on it: each once a second, spread over the
-- second (all on one tick cost a 6 ms spike at 400 hoppers). Written only when the signals changed.
function report.update(tick)
  local bucket = storage.report_buckets and storage.report_buckets[tick % 60]
  if not bucket then return end
  for unit in pairs(bucket) do
    local rec = storage.hoppers[unit]
    if not (rec and rec.reporter and rec.reporter.valid and rec.entity.valid) then
      bucket[unit] = nil  -- the hopper is gone
    else
      local out = report.signals(rec, tick)
      local key = fingerprint(out)
      if key ~= rec.report_last then
        rec.report_last = key
        local cb = rec.reporter.get_or_create_control_behavior()
        local section = cb.get_section(1) or cb.add_section()
        section.filters = out
      end
    end
  end
end

function report.on_destroyed(rec)
  if rec.reporter and rec.reporter.valid then rec.reporter.destroy() end
  if rec.report_mark and rec.report_mark.valid then rec.report_mark.destroy() end
end

-- Beside a hopper's window: for a fluid hopper the fluid it holds, at what temperature; the report checkbox
-- (with Circuit instrumentation 1).
function report.open_gui(player, hopper)
  report.close_gui(player)
  local circuit = shared.stage_ok(player.force, shared.circuit_tech)
  local rec = storage.hoppers[hopper.unit_number]
  local is_fluid = rec and rec.fluid
  local fluid = is_fluid and rec.port.valid and rec.port.fluidbox[1]
  if not (circuit or is_fluid) then return end
  local frame = player.gui.relative.add{type = "frame", name = "es_hopper", direction = "vertical",
    caption = {"es.hopper-title"},
    anchor = {gui = is_fluid and defines.relative_gui_type.storage_tank_gui or defines.relative_gui_type.container_gui,
      position = defines.relative_gui_position.right, name = hopper.name}}
  if is_fluid then
    frame.add{type = "label", name = "fluid", caption = fluid and {"es.hopper-fluid", "[fluid=" .. fluid.name .. "]",
      prototypes.fluid[fluid.name].localised_name, tostring(math.floor(fluid.amount + 0.5)),
      tostring(math.floor(fluid.temperature + 0.5))} or {"es.hopper-no-fluid"}}
  end
  if circuit then
    frame.add{type = "checkbox", name = "report", caption = {"es.hopper-report"}, tooltip = {"es.hopper-report-tooltip"},
      state = report.is_on(hopper.unit_number), tags = {es_action = "hopper-report", unit = hopper.unit_number}}
  end
end

function report.close_gui(player)
  if player and player.gui.relative.es_hopper then player.gui.relative.es_hopper.destroy() end
end

return report
