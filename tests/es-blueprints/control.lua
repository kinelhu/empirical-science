-- Builds the example setups the mod ships as blueprints (circuit
-- teaching), exports them with the mod's own blueprint tagging (remote blueprint_of), and writes
-- script-output/es-blueprints.lua. scripts/make_blueprints.sh copies it into the mod. Never hand-edited.
local es = function(fn, ...) return remote.call("empirical-science", fn, ...) end
local N = defines.direction.north
local WC = defines.wire_connector_id
local s

local function place(name, x, y, dir)
  local e = s.create_entity{name = name, position = {x, y}, force = "player", raise_built = true, direction = dir}
  if not e then error("could not place " .. name .. " at " .. x .. "," .. y) end
  return e
end
local function wire(a, a_id, b, b_id)
  if not a.get_wire_connector(a_id, true).connect_to(b.get_wire_connector(b_id, true)) then
    error("wire failed: " .. a.name .. " -> " .. b.name)
  end
end
local function constant(x, y, signals)
  local c = place("constant-combinator", x, y)
  local filters = {}
  for i, sg in ipairs(signals) do
    filters[i] = {value = {type = sg[1], name = sg[2], quality = "normal"}, min = sg[3]}
  end
  c.get_or_create_control_behavior().get_section(1).filters = filters
  return c
end
-- A gear bench in circuit mode with a hopper on its right.
local function circuit_bench(x, y)
  local b = place("es-test-bench", x, y)
  b.set_recipe("es-trial-gear-control")
  place("es-hopper", x + 2, y)
  es("set_dose", b.unit_number, {rows = {}, circuit = true})
  return b
end

script.on_init(function()
  s = game.surfaces.nauvis
  storage.examples = {}
  local EXAMPLES = storage.examples  -- (saved: the export runs after the save is reloaded)
  for _, t in pairs(game.forces.player.technologies) do t.researched = true end
  s.request_to_generate_chunks({0, 0}, 4); s.force_generate_chunk_requests()
  for _, e in pairs(s.find_entities_filtered{area = {{-60, -30}, {60, 30}}}) do
    if e.type ~= "character" then e.destroy() end
  end
  local tiles = {}
  for x = -60, 59 do for y = -30, 29 do table.insert(tiles, {name = "lab-dark-1", position = {x, y}}) end end
  s.set_tiles(tiles)

  -- 1. Dose by signal: a constant combinator sets the bench's coal dose.
  do
    local b = circuit_bench(-40.5, 0.5)
    local c = constant(-43.5, 3.5, {{"item", "coal", 5}})
    wire(c, WC.circuit_red, b, WC.circuit_red)
    table.insert(EXAMPLES, {key = "dose_signal", area = {{-45, -3}, {-36, 5}}, label = "Dose by signal"})
  end
  -- 2. Dose sweep: a clock counts T to 5400 ticks and restarts; T / 600 steps the coal dose 0 to 8.
  do
    local b = circuit_bench(-10.5, 0.5)
    local one = constant(-17.5, -3.5, {{"virtual", "signal-T", 1}})
    local clock = place("decider-combinator", -15.5, -3.5, defines.direction.east)
    clock.get_or_create_control_behavior().parameters = {
      conditions = {{first_signal = {type = "virtual", name = "signal-T"}, comparator = "<", constant = 5400}},
      outputs = {{signal = {type = "virtual", name = "signal-T"}, copy_count_from_input = true}}}
    local step = place("arithmetic-combinator", -13.5, -3.5, defines.direction.east)
    step.get_or_create_control_behavior().parameters = {first_signal = {type = "virtual", name = "signal-T"},
      second_constant = 600, operation = "/", output_signal = {type = "item", name = "coal"}}
    wire(one, WC.circuit_red, clock, WC.combinator_input_red)
    wire(clock, WC.combinator_output_red, clock, WC.combinator_input_red)
    wire(clock, WC.combinator_output_red, step, WC.combinator_input_red)
    wire(step, WC.combinator_output_red, b, WC.circuit_red)
    table.insert(EXAMPLES, {key = "dose_sweep", area = {{-19, -5}, {-6, 3}}, label = "Dose sweep"})
  end
  -- 3. Best composition to a machine: the station asked for page 3 on gears; its port doses a gear
  --    assembler in circuit mode.
  do
    local st = place("es-analysis-station", 20.5, 0.5)
    local c = constant(17.5, 3.5, {{"recipe", "iron-gear-wheel", 1}, {"virtual", "es-page", 3}})
    wire(c, WC.circuit_red, st, WC.circuit_red)
    local port = s.find_entities_filtered{name = "es-station-port", area = {{18, -2}, {23, 3}}}[1]
    if not port then error("no station port") end
    local m = place("assembling-machine-2", 26.5, 0.5)
    m.set_recipe("iron-gear-wheel")
    place("es-hopper", 28.5, 0.5)
    es("set_dose", m.unit_number, {rows = {}, circuit = true})
    wire(port, WC.circuit_green, m, WC.circuit_green)
    table.insert(EXAMPLES, {key = "adopt_best", area = {{16, -2}, {30, 5}}, label = "Best composition to a machine"})
  end
end)

script.on_nth_tick(60, function(event)
  if event.tick == 0 or storage.done then return end
  storage.done = true
  -- (0.72) No slot filters in a station's blueprint: they number slots, and the station's size depends on the
  -- mods loaded (a tip's scene loads none but this one: 18 filters did not fit its station, which then failed
  -- to import). A built station sets its own.
  for _, st in pairs(game.surfaces.nauvis.find_entities_filtered{name = "es-analysis-station"}) do
    local inv = st.get_inventory(defines.inventory.chest)
    for i = 1, #inv do inv.set_filter(i, nil) end
  end
  local lines = {"-- Generated by tests/es-blueprints (scripts/make_blueprints.sh): do not edit.",
    "-- The example builds the mod hands out (shortcut) and shows in its tips. Imported by a test on every version.",
    "local blueprints = {"}
  for _, ex in ipairs(storage.examples) do
    local text = es("blueprint_of", "nauvis", ex.area, ex.label)
    table.insert(lines, string.format("  %s = %q,", ex.key, text))
  end
  table.insert(lines, "}")
  table.insert(lines, "return blueprints")
  helpers.write_file("es-blueprints.lua", table.concat(lines, "\n") .. "\n")
end)
