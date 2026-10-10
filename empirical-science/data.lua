local shared = require("shared")

-- Other mods' targets: the table they register into, in their data or
-- data-updates stage; data-final-fixes builds their prototypes.
data:extend({{type = "mod-data", name = shared.REGISTRY, data_type = "es-targets", data = {}}})

-- Recursively tint every sprite layer of a copied prototype.
local function tint_sprites(t, tint)
  if type(t) ~= "table" then return end
  if t.filename or t.filenames then t.tint = tint end
  for k, v in pairs(t) do
    if k ~= "tint" then tint_sprites(v, tint) end
  end
end

local dt = require("data_targets")
local icons_of, item_proto, with_badge, process_text = dt.icons_of, dt.item_proto, dt.with_badge, dt.process_text

-- Test bench: an assembling-machine-1 restricted to trial recipes.
local bench = table.deepcopy(data.raw["assembling-machine"]["assembling-machine-1"])
bench.name = "es-test-bench"
bench.minable.result = "es-test-bench"
bench.crafting_categories = {"es-experiment"}
bench.next_upgrade = nil
bench.fast_replaceable_group = nil
bench.localised_description = {"entity-description.es-test-bench", tostring(math.floor(shared.survivor_share * 100 + 0.5))}
-- Recoloured sprites (scripts/make_sprites.py): only the paint changes, not the steel.
local GFX = "__empirical-science__/graphics/"
local function own_icon(file) return {{icon = GFX .. file, icon_size = 64}} end
local function swap_file(t, old, new)
  if type(t) ~= "table" then return end
  if t.filename == old then t.filename = new end
  for _, v in pairs(t) do swap_file(v, old, new) end
end
bench.icons = own_icon("test-bench-icon.png"); bench.icon = nil
-- Speed modules and beacons scale a research wing; productivity would bypass the measurement.
bench.module_slots = 2
bench.allowed_effects = {"speed", "consumption", "pollution"}
-- (0.72: assembling machine 1, its base, ignores modules and beacons; with only slots added, modules sat in
-- them doing nothing. User, playtest: "I don't get samples faster".)
bench.effect_receiver = {uses_module_effects = true, uses_beacon_effects = true, uses_surface_effects = true}
-- A fluid input for trials of recipes that take one (processing units, plastic, batteries...), off when
-- the trial has none. In the middle of the top edge, as assembling machine 2 takes fluid, with its stub and
-- covers (0.72, user: at the top-left corner, chosen to leave the middle to hoppers, the stub hung past the
-- bench's edge). Hoppers dose from the bench's other edge tiles.
local fluid_in = table.deepcopy(data.raw["assembling-machine"]["assembling-machine-2"].fluid_boxes[1])
fluid_in.pipe_connections = {{flow_direction = "input", direction = defines.direction.north, position = {0, -1}}}
bench.fluid_boxes = {fluid_in}
bench.fluid_boxes_off_when_no_fluid_recipe = true
swap_file(bench.graphics_set, "__base__/graphics/entity/assembling-machine-1/assembling-machine-1.png",
  GFX .. "test-bench.png")

-- Analysis station: a 3x3 container with lab graphics. The script consumes samples and packs.
local lab = data.raw.lab.lab
local function frame_of(layer)
  return {filename = layer.filename, width = layer.width, height = layer.height, shift = layer.shift,
    scale = layer.scale, draw_as_shadow = layer.draw_as_shadow}
end
local station_picture = {layers = {}}
for _, layer in ipairs(lab.off_animation.layers) do table.insert(station_picture.layers, frame_of(layer)) end
-- Its own paint (0.70, scripts/make_sprites.py): the lab's struts and base ring in the test bench's teal.
station_picture.layers[1].filename = GFX .. "station.png"
-- Its working animation (0.72, user: no animation was a lost chance to give it character): the lab's, in
-- the station's paint (scripts/make_sprites.py); the script draws it while the station analyses.
local working = {type = "animation", name = "es-station-working", layers = {}}
for _, layer in ipairs(lab.on_animation.layers) do
  if not layer.draw_as_shadow then table.insert(working.layers, table.deepcopy(layer)) end
end
working.layers[1].filename = GFX .. "station-working.png"
data:extend({working})
local station = {
  type = "container", name = "es-analysis-station",
  localised_description = {"entity-description.es-analysis-station", "",
    tostring(shared.station_sample_slots),
    -- (World strength: the setting's; a map made under another keeps its own, shown on each sample.)
    tostring(shared.world_strength[settings.startup["es-world-strength"].value].samples_per_pack),
    tostring(shared.analysis_ticks / 60)},
  icons = own_icon("station-icon.png"), flags = {"placeable-neutral", "placeable-player", "player-creation"},
  minable = {mining_time = 0.2, result = "es-analysis-station"},
  max_health = 150, corpse = "lab-remnants", dying_explosion = "lab-explosion",
  collision_box = lab.collision_box, selection_box = lab.selection_box,
  inventory_size = shared.station_slots, inventory_type = "with_filters_and_bar", picture = station_picture,
  open_sound = lab.open_sound, close_sound = lab.close_sound,
  -- Circuit input (0.49): the port's target, page and cell by signal; also vanilla "read contents".
  circuit_connector = table.deepcopy(data.raw.container["steel-chest"].circuit_connector),
  circuit_wire_max_distance = data.raw.container["steel-chest"].circuit_wire_max_distance,
}

-- Circuit output port: a constant combinator overlaid on the station's corner, managed by script.
local port = table.deepcopy(data.raw["constant-combinator"]["constant-combinator"])
port.name = "es-station-port"
port.collision_mask = {layers = {}}
port.selection_priority = 60
port.selection_box = {{-0.2, -0.2}, {0.2, 0.2}}  -- (0.70, user: a smaller corner; the station selects around it)
port.minable = nil
port.fast_replaceable_group = nil
port.flags = {"placeable-off-grid", "not-blueprintable", "not-deconstructable", "not-on-map", "hide-alt-info"}
port.hidden = true
tint_sprites(port.sprites, {r = 1.0, g = 0.75, b = 0.35})
-- The port as a sprite (0.72, user: while a station works, its script-drawn animation covered the port, an
-- entity below it in the same layer): drawn over the animation for as long as it runs.
do
  local north = port.sprites.north or port.sprites
  local front = {type = "sprite", name = "es-station-port-front", layers = {}}
  for _, l in ipairs(north.layers or {north}) do
    if not l.draw_as_shadow then
      table.insert(front.layers, {filename = l.filename, width = l.width, height = l.height, x = l.x, y = l.y,
        shift = l.shift, scale = l.scale, tint = l.tint})
    end
  end
  data:extend({front})
end

-- Hopper reporter (0.49): a constant combinator on a hopper that reports to the circuit, selectable in
-- the hopper's bottom-right corner; drawn by script as a small mark (its own sprite would cover the hopper).
local reporter = table.deepcopy(port)
reporter.name = "es-hopper-reporter"
reporter.selection_box = {{0.1, 0.1}, {0.45, 0.45}}
reporter.sprites = {filename = "__core__/graphics/empty.png", size = 1}
reporter.activity_led_sprites = {filename = "__core__/graphics/empty.png", size = 1}
reporter.activity_led_light = nil
reporter.flags = {"placeable-off-grid", "not-blueprintable", "not-deconstructable", "not-on-map", "hide-alt-info"}

-- A report (0.70, user: the tinted flask read as a science pack): scripts/make_sprites.py.
local sample_icons = own_icon("sample-icon.png")

-- Fulgora scrap samples: with Space Age. Scrap with a sample badge;
-- spoils to nothing; Scrap forensics 1 and 2 widen what a station draws from them.
if data.raw.item["scrap"] and data.raw.tool["electromagnetic-science-pack"] then
  local SC = shared.scrap
  data:extend({
    {type = "item", name = SC.item, icons = dt.with_badge(icons_of(data.raw.item["scrap"]), sample_icons), weight = 1000,
     subgroup = "science-pack", order = "z[es-sample]-b", stack_size = 10, spoil_ticks = SC.spoil_minutes * 3600,
     localised_description = {"item-description." .. SC.item, tostring(SC.cap), tostring(SC.spoil_minutes)}},
  })
  local packs = {"automation-science-pack", "logistic-science-pack", "chemical-science-pack", "electromagnetic-science-pack"}
  for level, count in ipairs({300, 600}) do
    local ingredients = {}
    for _, p in ipairs(packs) do table.insert(ingredients, {p, 1}) end
    table.insert(ingredients, {"es-research-data", 1})
    data:extend({{type = "technology", name = SC.forensics[level],
      icons = dt.with_badge(icons_of(data.raw.item["scrap"]), icons_of(data.raw.tool["electromagnetic-science-pack"])),
      prerequisites = level == 1 and {"es-empirical-method", "electromagnetic-science-pack"} or {SC.forensics[1]},
      effects = {{type = "nothing", effect_description = {"es-tech-effect." .. SC.forensics[level]}}},
      unit = {count = count, time = 30, ingredients = ingredients}}})
  end
end

data:extend({
  {type = "recipe-category", name = "es-experiment"},
  {type = "item-subgroup", name = "es-catalysed", group = "intermediate-products", order = "z"},
  {type = "item-subgroup", name = "es-spent", group = "intermediate-products", order = "z-spent"},
  bench, station, port, reporter,

  {type = "item", name = "es-test-bench", icons = own_icon("test-bench-icon.png"),
   subgroup = "production-machine", order = "z[es-test-bench]",
   place_result = "es-test-bench", stack_size = 50},
  {type = "item", name = "es-analysis-station", icons = own_icon("station-icon.png"),
   subgroup = "production-machine", order = "z[es-analysis-station]",
   place_result = "es-analysis-station", stack_size = 10},
  -- (Before 0.72, one sample for every tier; the trials now make one per science pack, data_targets.lua. Kept
  -- for saves that hold some: control.lua migrates them.)
  {type = "item-with-tags", name = "es-sample", icons = sample_icons, hidden = true,
   subgroup = "science-pack", order = "z[es-sample]", stack_size = 1},

  {type = "recipe", name = "es-test-bench", enabled = false, energy_required = 2,
   ingredients = {{type = "item", name = "assembling-machine-1", amount = 1},
                  {type = "item", name = "electronic-circuit", amount = 5}},
   results = {{type = "item", name = "es-test-bench", amount = 1}}},
  {type = "recipe", name = "es-analysis-station", enabled = false, energy_required = 2,
   ingredients = {{type = "item", name = "lab", amount = 1},
                  {type = "item", name = "electronic-circuit", amount = 10}},
   results = {{type = "item", name = "es-analysis-station", amount = 1}}},
})

local unlocks = {
  {type = "unlock-recipe", recipe = "es-test-bench"},
  {type = "unlock-recipe", recipe = "es-analysis-station"},
}

-- Residues by family: one unit per unit of a solid additive dosed. A vanilla icon of the
-- family, darkened. Made by dosing, or from the family's first member once activation is researched;
-- never reclaimed.
local RESIDUE_ICON = {carbon = "coal", organic = "wood", mineral = "stone", metal = "copper-ore", sulfur = "sulfur",
                      polymer = "plastic-bar"}
for i, a in ipairs(shared.additives) do
  if a.residue_of then
    local icons = icons_of(data.raw.item[RESIDUE_ICON[a.residue_of]])
    for _, icon in ipairs(icons) do icon.tint = {r = 0.45, g = 0.4, b = 0.35} end
    -- Its recipe from the family's first member, one for one (decided 2026-10-02: scaling a catalyst
    -- should not mean dosing machines for the residue alone). Named after the residue (so models cost
    -- it); made in an assembler. Unlocked with the family's activation (control.lua, check_discovery).
    -- Never smelting (0.51): a furnace picks its recipe from what it is fed, so coal to ash in a furnace
    -- turned every furnace fed from a coal-and-ore belt into an ash maker once carbon's activation was
    -- found (the showcase factory stalled; a test now checks every residue recipe of a fuel).
    data:extend({{type = "item", name = a.name, icons = icons, localised_description = {"item-description.es-residue"},
      subgroup = "es-spent", order = tostring(i), stack_size = 100},
      {type = "recipe", name = a.name, category = "crafting", enabled = false,
       energy_required = 1, ingredients = {{type = "item", name = a.spent_of, amount = 1}},
       results = {{type = "item", name = a.name, amount = 1}}, allow_productivity = false, allow_decomposition = false,
       -- Never reclaimed (0.39): no recycler reversal back to the family member (0.68: Space Age's
       -- generated recycling gave 25% of it back, a sink the balance model did not know).
       auto_recycle = false}})
  end
end


-- Trials: one recipe per target (and per route); the dose comes from the bench's hoppers, set in its
-- panel (scripts/dosing.lua). One tab, a row per target.
data:extend({{type = "item-group", name = "es-experiments", order = "z-es",
  -- (0.72, user: a plain gear said nothing) The test bench, where every recipe in the tab runs.
  icons = {{icon = GFX .. "test-bench-icon.png", icon_size = 64}}, localised_name = {"item-group-name.es-experiments-all"}}})
for ti, target in ipairs(shared.targets) do dt.build_target(ti, target, unlocks) end

data:extend({{
  type = "technology", name = "es-empirical-method",
  icons = icons_of(lab),
  prerequisites = {"electronics"},
  effects = unlocks,
  unit = {count = 50, time = 10, ingredients = {{shared.pack, 1}}},
}})

-- Staged reveal (shared.stages): the stage technologies, right after the method (the heaters below are
-- unlocked by Thermal studies). Their effects are descriptions; control.lua enforces them.
do
  local PACKS = {"automation-science-pack", "logistic-science-pack", "chemical-science-pack"}
  -- Each stage: the lab with a vanilla badge for what it opens (three lab icons alone read alike).
  local STAGE_BADGE = {routes = data.raw.item["iron-gear-wheel"], mixtures = data.raw.item["chemical-plant"],
                       thermal = data.raw.item["boiler"], quality = data.raw.module and data.raw.module["quality-module"],
                       theory = data.raw.item["decider-combinator"]}
  for key, st in pairs(shared.stages) do
    local icons = icons_of(lab)
    for _, b in ipairs(icons_of(STAGE_BADGE[key])) do
      b.scale = 0.5; b.shift = {12, 12}
      table.insert(icons, b)
    end
    local ingredients = {}
    for i = 1, st.packs do table.insert(ingredients, {PACKS[i], 1}) end
    table.insert(ingredients, {"es-research-data", 1})
    local prereq = {"es-empirical-method"}
    for _, p in ipairs(st.prerequisites) do table.insert(prereq, p) end
    data:extend({{type = "technology", name = st.tech, icons = icons, prerequisites = prereq,
      effects = {{type = "nothing", effect_description = {"es-tech-effect." .. st.tech}}},
      unit = {count = st.units, time = 30, ingredients = ingredients},
      localised_name = {"technology-name." .. st.tech}, localised_description = {"technology-description." .. st.tech}}})
  end
end

---------------------------------------------------------------------------
-- Hoppers (scripts/dosing.lua): hold additives for the dosed machines they touch, beacon-like. The hopper
-- takes items by inserter; the fluid hopper (0.71, user: one entity a chest, the other a fluid input) takes a
-- fluid by pipe. (Residues leave by the dosed machine's trash slots, 0.65.)
---------------------------------------------------------------------------
local overlay_flags = {"placeable-off-grid", "not-blueprintable", "not-deconstructable", "not-on-map", "hide-alt-info"}
local hopper = table.deepcopy(data.raw.container["steel-chest"])
hopper.name = "es-hopper"
hopper.minable.result = "es-hopper"
hopper.inventory_size = shared.hopper.slots
-- A limit bar like any chest, and slot filters like a cargo wagon (0.70, user: one hopper fed two additives
-- clogged with one of them; filtered slots keep room for each).
hopper.inventory_type = "with_filters_and_bar"
hopper.icons = own_icon("hopper-icon.png")
hopper.icon = nil
-- Its own sprite (0.71, scripts/make_sprites.py): vanilla's requester chest with its hatch open, in the test
-- bench's teal (user: the steel chest felt low-tech), drawn as the requester chest is, with its shadow.
do
  local req = data.raw["logistic-container"]["requester-chest"].animation.layers
  local body, shadow = table.deepcopy(req[1]), table.deepcopy(req[2])
  body.filename, body.frame_count, body.line_length, body.animation_speed = GFX .. "hopper.png", nil, nil, nil
  shadow.repeat_count = nil
  hopper.picture = {layers = {body, shadow}}
end
hopper.fast_replaceable_group = nil
hopper.next_upgrade = nil

-- The fluid port overlaid on a hopper before 0.71: kept, hidden, so old saves load with it and the migration can
-- read what it holds (control.lua, split_hoppers). Nothing builds one any more.
local hopper_port = table.deepcopy(data.raw["storage-tank"]["storage-tank"])
hopper_port.name = "es-hopper-fluid-port"
hopper_port.collision_mask = {layers = {}}
hopper_port.collision_box = {{-0.4, -0.4}, {0.4, 0.4}}
-- No selection box (0.70, user: in the map editor, which ignores "not-selectable-in-game", the port took the
-- cursor from its hopper and could not be deconstructed): it is never selected, anywhere.
hopper_port.selection_box = nil
hopper_port.selection_priority = nil
hopper_port.minable = nil
hopper_port.fast_replaceable_group = nil
hopper_port.next_upgrade = nil
-- Not selectable (0.70, user: it covered most of the hopper, which was hard to mine): pipes still connect;
-- the hopper's window shows its fluid.
hopper_port.flags = {"placeable-off-grid", "not-blueprintable", "not-deconstructable", "not-on-map", "hide-alt-info",
  "not-selectable-in-game"}
hopper_port.hidden = true
hopper_port.circuit_connector = nil
hopper_port.circuit_wire_max_distance = 0
local empty_sprite = {filename = "__core__/graphics/empty.png", size = 1}
-- (0.63: vanilla's flanged pipe joints where a pipe connects, as assemblers draw them, in place of the caps on
-- every unconnected side, which read as a stray gear on a hopper fed by inserters.)
local asm2_pipes = data.raw["assembling-machine"]["assembling-machine-2"].fluid_boxes[1].pipe_picture
-- Under the hopper (0.64): drawn over it, the south joint (built to tuck under an assembler's front) buried the
-- hopper's face; below, the hopper covers its own part and only the reach toward the pipe shows, as the chute does.
hopper_port.fluid_box = {volume = 200, pipe_picture = table.deepcopy(asm2_pipes), render_layer = "lower-object-above-shadow",
  pipe_connections = {
  {direction = defines.direction.north, position = {0, 0}}, {direction = defines.direction.east, position = {0, 0}},
  {direction = defines.direction.south, position = {0, 0}}, {direction = defines.direction.west, position = {0, 0}}}}
hopper_port.pictures = {picture = {sheet = empty_sprite}, window_background = empty_sprite,
  fluid_background = empty_sprite, flow_sprite = empty_sprite, gas_flow = {filename = empty_sprite.filename,
  size = 1, frame_count = 1}}
hopper_port.window_bounding_box = {{0, 0}, {0, 0}}

-- The fluid hopper (0.71, user: the chest looked poor for fluids; vanilla's pump instead): a 1x2 storage tank
-- drawn as the pump (its casing in the bench's teal, scripts/make_sprites.py), joined by pipe at both ends so a
-- line can run through several, dosing the machines along its long sides. Two directions, as a pump's body.
local pump = data.raw.pump["pump"]
local fluid_hopper = table.deepcopy(data.raw["storage-tank"]["storage-tank"])
fluid_hopper.name = "es-fluid-hopper"
fluid_hopper.icons = own_icon("fluid-hopper-icon.png")
fluid_hopper.icon = nil
fluid_hopper.minable = {mining_time = pump.minable.mining_time, result = "es-fluid-hopper"}
fluid_hopper.collision_box = table.deepcopy(pump.collision_box)
fluid_hopper.selection_box = table.deepcopy(pump.selection_box)
fluid_hopper.drawing_box_vertical_extension = nil
fluid_hopper.two_direction_only = true
fluid_hopper.fast_replaceable_group = nil
fluid_hopper.next_upgrade = nil
fluid_hopper.max_health = pump.max_health
fluid_hopper.corpse, fluid_hopper.dying_explosion = pump.corpse, pump.dying_explosion
fluid_hopper.fluid_box = {volume = 200, pipe_covers = table.deepcopy(pump.fluid_box.pipe_covers),
  pipe_connections = {{direction = defines.direction.north, position = {0, -0.5}},
                      {direction = defines.direction.south, position = {0, 0.5}}}}
local function pump_frame(d)
  local v = pump.animations[d]
  return {layers = {{filename = GFX .. "fluid-hopper-" .. d .. ".png", width = v.width, height = v.height,
    shift = v.shift, scale = v.scale}}}
end
fluid_hopper.pictures = {picture = {north = pump_frame("north"), east = pump_frame("east"), south = pump_frame("south"),
  west = pump_frame("west")}, window_background = empty_sprite, fluid_background = empty_sprite,
  flow_sprite = empty_sprite, gas_flow = {filename = empty_sprite.filename, size = 1, frame_count = 1}}
fluid_hopper.window_bounding_box = {{0, 0}, {0, 0}}
fluid_hopper.circuit_connector = table.deepcopy(pump.circuit_connector)
fluid_hopper.circuit_wire_max_distance = pump.circuit_wire_max_distance

-- The hoppers' animations, drawn by script over the still picture (scripts/dosing.lua, animate): the iris
-- closes and opens again as a hopper hands out a dose, and the fluid hopper's pump turns while it supplies.
-- Each sheet holds only the part of the frame that moves (graphics_frames.lua), shifted to sit where it was.
do
  local frames = require("graphics_frames")
  local function part(key, filename, src, line_length, frame_count, sequence)
    local f = frames[key]
    local px = {f.x + f.width / 2 - f.frame_width / 2, f.y + f.height / 2 - f.frame_height / 2}
    local shift = src.shift or {0, 0}
    shift = {(shift[1] or shift.x) + px[1] * src.scale / 32, (shift[2] or shift.y) + px[2] * src.scale / 32}
    return {filename = GFX .. filename, width = f.width, height = f.height, scale = src.scale, shift = shift,
      line_length = line_length, frame_count = frame_count, frame_sequence = sequence}
  end
  local req = data.raw["logistic-container"]["requester-chest"].animation.layers[1]
  local iris = part("iris", "hopper-iris.png", req, 7, 7, {7, 6, 5, 4, 3, 2, 1, 1, 2, 3, 4, 5, 6, 7})
  iris.type, iris.name = "animation", "es-hopper-iris"
  data:extend({iris})
  for _, d in ipairs({"north", "east", "south", "west"}) do
    local a = part(d, "fluid-hopper-" .. d .. "-anim.png", pump.animations[d], 8, 32)
    a.type, a.name = "animation", "es-fluid-hopper-" .. d
    data:extend({a})
  end
end

data:extend({
  hopper, hopper_port, fluid_hopper,
  {type = "item", name = "es-hopper", icons = hopper.icons, subgroup = "production-machine",
   order = "z[es-hopper]", place_result = "es-hopper", stack_size = 50},
  {type = "recipe", name = "es-hopper", enabled = false, energy_required = 1,
   ingredients = {{type = "item", name = "iron-chest", amount = 1}, {type = "item", name = "pipe", amount = 2},
                  {type = "item", name = "electronic-circuit", amount = 1}},
   results = {{type = "item", name = "es-hopper", amount = 1}}},
  {type = "item", name = "es-fluid-hopper", icons = fluid_hopper.icons, subgroup = "production-machine",
   order = "z[es-hopper]-a[fluid]", place_result = "es-fluid-hopper", stack_size = 50},
  -- The hopper's price, one pipe more.
  {type = "recipe", name = "es-fluid-hopper", enabled = false, energy_required = 1,
   ingredients = {{type = "item", name = "iron-chest", amount = 1}, {type = "item", name = "pipe", amount = 3},
                  {type = "item", name = "electronic-circuit", amount = 1}},
   results = {{type = "item", name = "es-fluid-hopper", amount = 1}}},
})
table.insert(data.raw.technology["es-empirical-method"].effects, {type = "unlock-recipe", recipe = "es-hopper"})
table.insert(data.raw.technology["es-empirical-method"].effects, {type = "unlock-recipe", recipe = "es-fluid-hopper"})

-- Additive power (0.44): a hidden consumer on each dosed machine whose efficiency effect is not zero. It
-- draws the extra power while the machine works, or feeds back the saving (at most half the machine's
-- draw), on the machine's own network; it shows in the power statistics under its own name. No
-- collision, selection or picture (spike, 2026-10-02: 1,000 cost 0.04 ms per tick).
local power_draw = table.deepcopy(data.raw["electric-energy-interface"]["electric-energy-interface"])
power_draw.name = "es-power-draw"
power_draw.collision_mask = {layers = {}}
power_draw.selection_box = nil
power_draw.flags = overlay_flags
power_draw.minable = nil
power_draw.hidden = true
power_draw.picture = {filename = "__core__/graphics/empty.png", size = 1}
power_draw.animation = nil
-- Draws at a machine's priority (secondary-input). "tertiary" took nothing from tertiary sources (an
-- electric-energy-interface, accumulators at night) and showed a no-power icon (playtest, 2026-10-02).
power_draw.energy_source = {type = "electric", usage_priority = "secondary-input", buffer_capacity = "1MJ",
  -- Hidden: never an icon of its own (a feeding-back one reads an empty buffer, which drew a flashing
  -- no-power icon on working machines; playtest, 2026-10-02).
  render_no_power_icon = false, render_no_network_icon = false}
power_draw.energy_production, power_draw.energy_usage = "0W", "0W"
power_draw.gui_mode = "none"
-- Feeds back what a positive efficiency saves, ahead of the network's generators (primary-output).
local power_give = table.deepcopy(power_draw)
power_give.name = "es-power-give"
power_give.energy_source = {type = "electric", usage_priority = "primary-output", buffer_capacity = "1MJ",
  render_no_power_icon = false, render_no_network_icon = false}
data:extend({power_draw, power_give})


---------------------------------------------------------------------------
-- Research data: made by stations from what samples teach, consumed by labs.
-- The mod's branch: instruments, never results.
---------------------------------------------------------------------------
local data_icon = own_icon("research-data-icon.png")  -- scripts/make_sprites.py
data:extend({{type = "tool", name = "es-research-data", icons = data_icon, subgroup = "science-pack",
  -- (0.72) As heavy as a science pack: 1,000 to a rocket. Made by script, it had the engine's default weight,
  -- for an item with no recipe: ten times as many.
  order = "z[es-research-data]", stack_size = 200, durability = 1, weight = 1000,
  durability_description_key = "description.science-pack-remaining-amount-key",
  durability_description_value = "description.science-pack-remaining-amount-value"}})
-- Labs take it: data-final-fixes.lua (labs from later mods too, the biolab included).
local units = shared.data.branch_units
local tiers = {
  {"red", {{"automation-science-pack", 1}, {"es-research-data", 1}}, {}},
  {"green", {{"automation-science-pack", 1}, {"logistic-science-pack", 1}, {"es-research-data", 1}}, {"logistic-science-pack"}},
  {"blue", {{"automation-science-pack", 1}, {"logistic-science-pack", 1}, {"chemical-science-pack", 1},
    {"es-research-data", 1}}, {"chemical-science-pack"}},
  {"purple", {{"automation-science-pack", 1}, {"logistic-science-pack", 1}, {"chemical-science-pack", 1},
    {"production-science-pack", 1}, {"es-research-data", 1}}, {"production-science-pack"}},
}
local function branch(name, level, tier, prereqs, icons)
  local t = tiers[tier]
  local p = {level == 1 and "es-empirical-method" or (name .. "-" .. (level - 1))}
  for _, x in ipairs(t[3]) do table.insert(p, x) end
  for _, x in ipairs(prereqs or {}) do table.insert(p, x) end
  return {type = "technology", name = name .. "-" .. level, icons = icons, prerequisites = p,
    effects = {{type = "nothing", effect_description = {"es-tech-effect." .. name, tostring(level), tostring(shared.station_throughput_step),
      tostring(math.floor((1 - shared.data.precision_step) * 100 + 0.5))}}},
    unit = {count = units[t[1]], time = 30, ingredients = table.deepcopy(t[2])},
    localised_name = {"technology-name." .. name, tostring(level)}, localised_description = {"technology-description." .. name},
    upgrade = level > 1}
end
-- The lab with a badge: a magnifier for precision (as on research data), a red pack for productivity.
local function lab_with(badge)
  local icons = icons_of(lab)
  for _, b in ipairs(badge) do b.scale = 0.5; b.shift = {12, 12}; table.insert(icons, b) end
  return icons
end
local precision_icons = lab_with({{icon = "__core__/graphics/icons/search.png", icon_size = 32}})
local throughput_icons = lab_with(icons_of(data.raw.tool["automation-science-pack"]))
data:extend({
  (function()  -- level 1 also measures speed and pollution (staged reveal)
    local t = branch("es-precision-instruments", 1, 1, nil, precision_icons)
    table.insert(t.effects, {type = "nothing", effect_description = {"es-tech-effect.es-side-effects"}})
    t.unit.count = math.floor(units.red * shared.data.first_stage_share + 0.5)  -- (the first stage, 0.72)
    return t
  end)(),
  branch("es-precision-instruments", 2, 2, nil, precision_icons),
  branch("es-precision-instruments", 3, 3, nil, precision_icons),
  branch("es-station-throughput", 1, 1, nil, throughput_icons),
  branch("es-station-throughput", 2, 2, nil, throughput_icons),
  (function()  -- also circuit mode on benches and machines (staged reveal), the station input, hopper reports
    local t = branch("es-circuit-instrumentation", 1, 2, {"circuit-network"}, icons_of(data.raw["constant-combinator"]["constant-combinator"]))
    t.effects = {}  -- (0.72: the port's page 0 needs no technology, and O and L are gone)
    table.insert(t.effects, {type = "nothing", effect_description = {"es-tech-effect.es-circuit-mode"}})
    table.insert(t.effects, {type = "nothing", effect_description = {"es-tech-effect.es-circuit-input"}})
    table.insert(t.effects, {type = "nothing", effect_description = {"es-tech-effect.es-hopper-report"}})
    return t
  end)(),
  -- Circuit interface (0.49): level 2 the port's measurement pages, level 3 the composition.
  (function()
    local t = branch("es-circuit-instrumentation", 2, 3, nil, icons_of(data.raw["constant-combinator"]["constant-combinator"]))
    t.effects = {{type = "nothing", effect_description = {"es-tech-effect.es-port-pages"}}}
    return t
  end)(),
  (function()
    local t = branch("es-circuit-instrumentation", 3, 4, nil, icons_of(data.raw["constant-combinator"]["constant-combinator"]))
    t.effects = {{type = "nothing", effect_description = {"es-tech-effect.es-port-composition"}}}
    return t
  end)(),
})

-- The mod's circuit signals (0.49): the research data flask with a vanilla letter.
data:extend({{type = "item-subgroup", name = "es-signals", group = "signals", order = "z-es"}})
for i, sig in ipairs({{"es-page", "P"}, {"es-dose", "D"}, {"es-n", "N"}, {"es-mean", "M"}, {"es-half", "H"},
                      {"es-lo", "L"}, {"es-fed", "F"}, {"es-starved", "S"}, {"es-spent", "R"}}) do
  local letter = data.raw["virtual-signal"]["signal-" .. sig[2]]
  local icons = table.deepcopy(data_icon)
  table.insert(icons, {icon = letter.icon, icon_size = letter.icon_size or 64, scale = 0.25, shift = {8, 8}})
  data:extend({{type = "virtual-signal", name = sig[1], icons = icons, subgroup = "es-signals",
    order = string.format("%02d", i)}})
end
-- (0.72, the four-page port) What a cell does besides yield, and the best upgrade rate: the flask with a vanilla
-- icon where one says it (speed, power, the quality module), a letter where none does (cleanliness).
for i, sig in ipairs({
    {"es-speed", "__base__/graphics/icons/signal/signal-speed.png"},
    {"es-cleanliness", data.raw["virtual-signal"]["signal-C"].icon},
    {"es-efficiency", "__base__/graphics/icons/signal/signal-lightning.png"},
    {"es-quality", mods["quality"] and "__quality__/graphics/icons/quality-module.png" or data.raw["virtual-signal"]["signal-Q"].icon}}) do
  local icons = table.deepcopy(data_icon)
  table.insert(icons, {icon = sig[2], icon_size = 64, scale = 0.25, shift = {8, 8}})
  data:extend({{type = "virtual-signal", name = sig[1], icons = icons, subgroup = "es-signals",
    order = string.format("%02d", 20 + i)}})
end

-- Fluid heaters (shared.heaters): a boiler that heats any fluid to its temperature and passes the same
-- fluid on (output-to-separate-pipe without filters). Burner one early; heat-pipe one with the heat
-- exchanger. Unlocked with the technology that unlocks their vanilla original.
-- The temperature axis (0.61), with Space Age: Pressure
-- heating (the pressure heater, Vulcanus) and Chilling (chilled twins of the fluid additives, Aquilo).
if mods["space-age"] and data.raw.fluid["fluoroketone-cold"] then
  local CH = shared.chilled
  local function axis_tech(name, prereq, packs, count, badge)
    local ingredients = {}
    for _, p in ipairs(packs) do table.insert(ingredients, {p, 1}) end
    table.insert(ingredients, {"es-research-data", 1})
    data:extend({{type = "technology", name = name, icons = dt.with_badge(icons_of(lab), icons_of(badge)),
      prerequisites = {"es-thermal-studies", prereq}, effects = {}, unit = {count = count, time = 30, ingredients = ingredients}}})
  end
  axis_tech("es-pressure-heating", "metallurgic-science-pack",
    {"automation-science-pack", "logistic-science-pack", "chemical-science-pack", "metallurgic-science-pack"}, 300,
    data.raw.tool["metallurgic-science-pack"])
  axis_tech(CH.unlock, "cryogenic-science-pack",
    {"automation-science-pack", "logistic-science-pack", "chemical-science-pack", "cryogenic-science-pack"}, 300,
    data.raw.tool["cryogenic-science-pack"])
  -- Chilled twins: in data-final-fixes, once the liquid premixes exist too.
  -- (0.72) Their temperatures from the mod's values, not typed in the descriptions.
  local hot
  for _, h in ipairs(shared.heaters) do if h.name == "es-pressure-heater" then hot = h.temperature end end
  data.raw.technology["es-pressure-heating"].localised_description = {"technology-description.es-pressure-heating", tostring(hot)}
  data.raw.technology[CH.unlock].localised_description = {"technology-description." .. CH.unlock, tostring(shared.chilled.temperature)}
end

-- The pressure charge (0.70, shared.pressure_charge): the pressure heater's only fuel. Its icon is tungsten
-- carbide with vanilla's fuel signal.
if mods["space-age"] then
  local PC = shared.pressure_charge
  local icons = icons_of(data.raw.item["tungsten-carbide"])
  table.insert(icons, {icon = "__base__/graphics/icons/signal/signal-fuel.png", icon_size = 64, scale = 0.25, shift = {8, -8}})
  data:extend({
    {type = "fuel-category", name = "es-pressure"},
    {type = "item", name = PC.item, icons = icons, subgroup = "energy", order = "b[steam-power]-z[es-pressure-charge]",
     fuel_category = "es-pressure", fuel_value = PC.fuel_mj .. "MJ", stack_size = 50},
    {type = "recipe", name = PC.item, enabled = false, energy_required = PC.seconds,
     ingredients = {{type = "item", name = "tungsten-carbide", amount = PC.carbide},
                    {type = "item", name = "solid-fuel", amount = PC.solid_fuel}},
     results = {{type = "item", name = PC.item, amount = 1}}},
  })
  local tech = data.raw.technology["es-pressure-heating"]
  if tech then table.insert(tech.effects, {type = "unlock-recipe", recipe = PC.item}) end
  -- The cold charge (0.71, shared.cold_charge): the chiller's only fuel, made in a cryogenic plant from cold
  -- fluoroketone, which comes back hot. Its icon is the cold fluoroketone barrel with vanilla's fuel signal.
  local CC = shared.cold_charge
  local cold_icons = icons_of(data.raw.item["fluoroketone-cold-barrel"] or data.raw.fluid["fluoroketone-cold"])
  table.insert(cold_icons, {icon = "__base__/graphics/icons/signal/signal-fuel.png", icon_size = 64, scale = 0.25, shift = {8, -8}})
  data:extend({
    {type = "fuel-category", name = "es-cold"},
    {type = "item", name = CC.item, icons = cold_icons, subgroup = "energy", order = "b[steam-power]-z[es-cold-charge]",
     fuel_category = "es-cold", fuel_value = CC.fuel_mj .. "MJ", stack_size = 50},
    {type = "recipe", name = CC.item, category = "cryogenics", enabled = false, energy_required = CC.seconds,
     ingredients = {{type = "fluid", name = "fluoroketone-cold", amount = CC.fluoroketone}},
     results = {{type = "item", name = CC.item, amount = 1},
                {type = "fluid", name = "fluoroketone-hot", amount = CC.fluoroketone, temperature = 180}},
     main_product = CC.item, allow_productivity = false},
  })
  local chill_tech = data.raw.technology[shared.chilled.unlock]
  if chill_tech then table.insert(chill_tech.effects, {type = "unlock-recipe", recipe = CC.item}) end
end
for _, h in ipairs(shared.heaters) do
  if h.requires and not mods[h.requires] then goto next_heater end
  local e = table.deepcopy(data.raw.boiler[h.from])
  e.name = h.name
  e.mode = "output-to-separate-pipe"
  e.target_temperature = h.temperature
  e.fluid_box.filter = nil
  e.output_fluid_box.filter = nil
  e.minable = {mining_time = 0.2, result = h.name}
  e.fast_replaceable_group, e.next_upgrade = nil, nil
  e.localised_name = {"entity-name." .. h.name}
  e.localised_description = h.chill and {"entity-description.es-fluid-chiller", tostring(shared.chilled.temperature),
    tostring(shared.premix.cold)} or {"entity-description.es-fluid-heater", tostring(h.temperature)}
  e.surface_conditions = h.surface_conditions
  if h.fuel_category then e.energy_source.fuel_categories = {h.fuel_category} end
  local icons = icons_of(data.raw.item[h.from])
  -- A badge: steam for a heater, cold fluoroketone for the chiller, its own for the pressure heater (0.72:
  -- tungsten carbide, which its charges burn).
  local badge = h.badge and data.raw.item[h.badge] or h.chill and data.raw.fluid["fluoroketone-cold"] or data.raw.fluid["steam"]
  if h.tower then icons = {{icon = GFX .. "chiller-icon.png", icon_size = 64}} end
  table.insert(icons, {icon = badge.icon, icon_size = badge.icon_size or 64, scale = 0.25, shift = {8, -8}})
  e.icons, e.icon = icons, nil
  -- Its own look: the body in the test bench's teal, the chiller's in water's blue, the pressure heater's in
  -- crimson (scripts/make_sprites.py),
  -- fire and light vanilla.
  local function own(t)
    if type(t) ~= "table" then return end
    if type(t.filename) == "string" then
      local f = t.filename:match("^__base__/graphics/entity/[%w%-]+/(boiler%-[NESW]%-idle%.png)$")
        or t.filename:match("^__base__/graphics/entity/[%w%-]+/(heatex%-[NESW]%-%a+%.png)$")
      if f and (f:find("idle") or f:find("heated")) then t.filename = GFX .. (h.sprites or "heater") .. "/" .. f end
    end
    for _, v in pairs(t) do own(v) end
  end
  own(e.pictures)
  if h.chill then
    -- No fire, glow or smoke: it burns charges of cold.
    for _, pic in pairs(e.pictures or {}) do pic.fire, pic.fire_glow = nil, nil end
    e.energy_source.smoke = nil
    e.energy_source.light_flicker = nil
  end
  if h.tower then
    -- (0.72, user: the blue boiler read as a reskinned heater) Space Age's heating tower (3x3), recoloured
    -- (scripts/make_sprites.py): the same in every direction, its fire a cold glow while it burns a charge.
    -- Fluid passes west to east through its middle and leaves north, as the boiler's did.
    e.collision_box, e.selection_box = {{-1.29, -1.29}, {1.29, 1.29}}, {{-1.5, -1.5}, {1.5, 1.5}}
    e.fluid_box.pipe_connections = {
      {flow_direction = "input-output", direction = defines.direction.west, position = {-1, 0}},
      {flow_direction = "input-output", direction = defines.direction.east, position = {1, 0}}}
    e.output_fluid_box.pipe_connections = {{flow_direction = "output", direction = defines.direction.north, position = {0, -1}}}
    local px = 1 / 32
    local structure = {layers = {
      {filename = GFX .. "chiller/tower-main.png", width = 214, height = 320, shift = {-1 * px, -22.5 * px}, scale = 0.5},
      {filename = "__space-age__/graphics/entity/heating-tower/heating-tower-shadow.png", width = 312, height = 130,
       shift = {29 * px, 19 * px}, scale = 0.5, draw_as_shadow = true}}}
    local fire = {filename = GFX .. "chiller/tower-working-fire.png", width = 160, height = 184, line_length = 6,
      frame_count = 24, shift = {-1 * px, -74.5 * px}, scale = 0.5, blend_mode = "additive", draw_as_glow = true,
      animation_speed = 0.333}
    local glow = {filename = GFX .. "chiller/tower-working-light.png", width = 472, height = 242, frame_count = 1,
      shift = {-2.5 * px, 35.5 * px}, scale = 0.5, blend_mode = "additive", draw_as_glow = true}
    e.pictures = {}
    for _, dir in ipairs({"north", "east", "south", "west"}) do
      e.pictures[dir] = {structure = table.deepcopy(structure), fire = table.deepcopy(fire), fire_glow = table.deepcopy(glow)}
    end
    e.corpse = "heating-tower-remnants"
    e.drawing_box_vertical_extension = 1
  end
  local vanilla = data.raw.recipe[h.from]
  data:extend({e,
    {type = "item", name = h.name, icons = icons, subgroup = "energy", order = "b[steam-power]-z[" .. h.name .. "]",
     place_result = h.name, stack_size = 50, localised_name = {"entity-name." .. h.name}},
    {type = "recipe", name = h.name, enabled = false, energy_required = vanilla.energy_required,
     ingredients = h.ingredients or table.deepcopy(vanilla.ingredients), results = {{type = "item", name = h.name, amount = 1}}}})
  if h.unlock and data.raw.technology[h.unlock] then
    table.insert(data.raw.technology[h.unlock].effects, {type = "unlock-recipe", recipe = h.name})
  else
    for _, tech in pairs(data.raw.technology) do
      for _, eff in ipairs(tech.effects or {}) do
        if eff.type == "unlock-recipe" and eff.recipe == h.from then
          table.insert(tech.effects, {type = "unlock-recipe", recipe = h.name}); break
        end
      end
    end
  end
  ::next_heater::
end

-- Onboarding: tips that unlock as the player goes (research, first bench, first station, a third bench).
data:extend({
  {type = "tips-and-tricks-item-category", name = "empirical-science", order = "z-es"},
  {type = "tips-and-tricks-item", name = "es-title", category = "empirical-science", order = "a", is_title = true,
   starting_status = "locked", trigger = {type = "research", technology = "es-empirical-method"}},
  {type = "tips-and-tricks-item", name = "es-first-experiment", category = "empirical-science", order = "b",
   indent = 1, dependencies = {"es-title"}, trigger = {type = "research", technology = "es-empirical-method"}},
  {type = "tips-and-tricks-item", name = "es-samples", category = "empirical-science", order = "c",
   indent = 1, dependencies = {"es-first-experiment"}, trigger = {type = "build-entity", entity = "es-test-bench"}},
  {type = "tips-and-tricks-item", name = "es-screen", category = "empirical-science", order = "d",
   indent = 1, dependencies = {"es-samples"}, trigger = {type = "build-entity", entity = "es-analysis-station"}},
  {type = "tips-and-tricks-item", name = "es-screening", category = "empirical-science", order = "e",
   indent = 1, dependencies = {"es-screen"}, trigger = {type = "sequence", triggers = {
     {type = "build-entity", entity = "es-test-bench"}, {type = "build-entity", entity = "es-test-bench"},
     {type = "build-entity", entity = "es-test-bench"}}}},
  {type = "tips-and-tricks-item", name = "es-production", category = "empirical-science", order = "f",
   indent = 1, dependencies = {"es-screening"}, trigger = {type = "build-entity", entity = "es-hopper"}},
  {type = "tips-and-tricks-item", name = "es-stages", category = "empirical-science", order = "f2",
   indent = 1, dependencies = {"es-first-experiment"}, trigger = {type = "research", technology = "es-empirical-method"}},
  -- The family law (0.59): stated for free.
  {type = "tips-and-tricks-item", name = "es-families", category = "empirical-science", order = "f3",
   indent = 1, dependencies = {"es-screening"}, trigger = {type = "research", technology = "es-theory"}},
  -- (0.72, user: think of what else needs documenting) Mechanics a player meets and cannot see.
  {type = "tips-and-tricks-item", name = "es-sample-kinds", category = "empirical-science", order = "c2",
   indent = 1, dependencies = {"es-samples"}, trigger = {type = "build-entity", entity = "es-analysis-station"},
   localised_description = {"tips-and-tricks-item-description.es-sample-kinds", tostring(shared.station_sample_slots)}},
  {type = "tips-and-tricks-item", name = "es-science-packs", category = "empirical-science", order = "d2",
   indent = 1, dependencies = {"es-screen"}, trigger = {type = "research", technology = "es-empirical-method"}},
  {type = "tips-and-tricks-item", name = "es-fluid-hoppers", category = "empirical-science", order = "f5",
   indent = 1, dependencies = {"es-production"}, trigger = {type = "build-entity", entity = "es-fluid-hopper"}},
  {type = "tips-and-tricks-item", name = "es-temperature", category = "empirical-science", order = "f6",
   indent = 1, dependencies = {"es-production"}, trigger = {type = "research", technology = "es-thermal-studies"},
   localised_description = {mods["space-age"] and "tips-and-tricks-item-description.es-temperature-space-age"
     or "tips-and-tricks-item-description.es-temperature"}},
  {type = "tips-and-tricks-item", name = "es-findings", category = "empirical-science", order = "g2",
   indent = 1, dependencies = {"es-screen"}, trigger = {type = "research", technology = "es-empirical-method"}},
})
if mods["space-age"] then
  data:extend({
    {type = "tips-and-tricks-item", name = "es-ripeness", category = "empirical-science", order = "f7",
     indent = 1, dependencies = {"es-production"}, trigger = {type = "research", technology = "agriculture"}},
    {type = "tips-and-tricks-item", name = "es-scrap-samples", category = "empirical-science", order = "f8",
     indent = 1, dependencies = {"es-samples"}, trigger = {type = "research", technology = "recycling"}},
  })
end
if mods["quality"] then
  data:extend({
    {type = "tips-and-tricks-item", name = "es-quality-additives", category = "empirical-science", order = "f9",
     indent = 1, dependencies = {"es-production"}, trigger = {type = "research", technology = "es-quality-additives"}},
  })
end

-- Circuit teaching (0.67): a tip for alt mode and three
-- with scenes built from the shipped example blueprints (scripts/blueprints.lua), so the scene and the book
-- are the same build. A scene registers what it builds with the mod (script_raised_built), as a robot would.
do
  -- The scene's build is the mod's own remote (control.lua build_scene), so the headless test runs it too.
  local function scene(key, update)
    return {
      mods = {"empirical-science", "factorio-charts"},
      init = string.format([[
        for _, t in pairs(game.forces.player.technologies) do t.researched = true end
        local s = game.surfaces[1]
        local eei = s.create_entity{name = "electric-energy-interface", position = {-12, -8}, force = "player"}
        eei.power_production, eei.electric_buffer_size = 1e8, 1e8
        s.create_entity{name = "substation", position = {-6, -6}, force = "player"}
        s.create_entity{name = "substation", position = {6, -6}, force = "player"}
        game.simulation.camera_position = remote.call("empirical-science-scenes", "build_scene", %q, s.name)
        game.simulation.camera_alt_info = true
        game.simulation.camera_zoom = 1.4
      ]], key),
      update = update,
    }
  end
  data:extend({
    {type = "tips-and-tricks-item", name = "es-residues", category = "empirical-science", order = "f4",
     indent = 1, dependencies = {"es-production"}, trigger = {type = "build-entity", entity = "es-hopper"}},
    {type = "tips-and-tricks-item", name = "es-alt", category = "empirical-science", order = "h",
     indent = 1, dependencies = {"es-production"}, trigger = {type = "build-entity", entity = "es-hopper"}},
    {type = "tips-and-tricks-item", name = "es-dose-signal", category = "empirical-science", order = "i",
     indent = 1, dependencies = {"es-production"},
     trigger = {type = "research", technology = "es-circuit-instrumentation-1"},
     simulation = scene("dose_signal", [[remote.call("empirical-science-scenes", "scene_tick", game.surfaces[1].name, game.tick)]])},
    {type = "tips-and-tricks-item", name = "es-sweep", category = "empirical-science", order = "j",
     indent = 1, dependencies = {"es-dose-signal"},
     trigger = {type = "research", technology = "es-circuit-instrumentation-1"},
     simulation = scene("dose_sweep")},
    -- The port's signals, for reference (0.72, user: the table in the station window was unreadable).
    {type = "tips-and-tricks-item", name = "es-station-signals", category = "empirical-science", order = "j2",
     indent = 1, dependencies = {"es-first-experiment"}, trigger = {type = "research", technology = "circuit-network"}},
    {type = "tips-and-tricks-item", name = "es-port", category = "empirical-science", order = "k",
     indent = 1, dependencies = {"es-dose-signal"},
     trigger = {type = "research", technology = "es-circuit-instrumentation-3"},
     simulation = scene("adopt_best")},
  })
  -- The core tips' scenes (0.72, user: the pages were dry): built by script (control.lua, SCRIPTED).
  for tip, key in pairs({["es-first-experiment"] = "first_experiment", ["es-samples"] = "samples",
      ["es-production"] = "production", ["es-residues"] = "residues", ["es-fluid-hoppers"] = "fluid_hoppers"}) do
    local t = data.raw["tips-and-tricks-item"][tip]
    if t then t.simulation = scene(key) end
  end
end

-- The Empirical Science screen (the force's evidence): a shortcut and its hotkey, available once the
-- method is researched.
data:extend({
  {type = "custom-input", name = "es-open-science", key_sequence = "CONTROL + SHIFT + E", action = "lua"},
  {type = "shortcut", name = "es-open-science", action = "lua", order = "e[empirical-science]",
   associated_control_input = "es-open-science", technology_to_unlock = "es-empirical-method",
   unavailable_until_unlocked = true,
   icon = "__base__/graphics/icons/lab.png", icon_size = 64,
   small_icon = "__base__/graphics/icons/lab.png", small_icon_size = 64},
})
-- The example blueprint book (0.67): a shortcut hands
-- out the builds in scripts/blueprints.lua, as vanilla's shortcuts hand out wires.
data:extend({
  {type = "shortcut", name = "es-lab-blueprints", action = "lua", order = "e[empirical-science]-b",
   technology_to_unlock = "es-circuit-instrumentation-1", unavailable_until_unlocked = true,
   icon = "__base__/graphics/icons/shortcut-toolbar/mip/new-blueprint-book-x56.png", icon_size = 56,
   small_icon = "__base__/graphics/icons/shortcut-toolbar/mip/new-blueprint-book-x24.png", small_icon_size = 24},
})
-- Chutes drawn by script from a hopper into each machine it serves (scripts/dosing.lua).
data:extend({
  -- The bridge from a hopper into the machine it feeds (0.63): vanilla's flanged joint, as an assembler draws
  -- one on a connected pipe (scripts/dosing.lua redraw).
  {type = "sprite", name = "es-bridge-north", layers = {table.deepcopy(asm2_pipes.north)}},
  {type = "sprite", name = "es-bridge-east", layers = {table.deepcopy(asm2_pipes.east)}},
  {type = "sprite", name = "es-bridge-south", layers = {table.deepcopy(asm2_pipes.south)}},
  {type = "sprite", name = "es-bridge-west", layers = {table.deepcopy(asm2_pipes.west)}},
  -- The hopper's top rim alone (its sprite's top 10 rows, where the hopper draws them), drawn over the
  -- bridge from a machine to its north (0.70, user: the joint lay over the rim, which looked sliced off).
  {type = "sprite", name = "es-hopper-rim", filename = GFX .. "hopper.png", x = 0, y = 0, width = 66, height = 10,
   scale = 0.5, shift = {0, -2 / 32 - 74 / 128 + 10 / 128}},
  {type = "sprite", name = "es-chute-h", filename = "__base__/graphics/entity/pipe/pipe-straight-horizontal.png",
   size = 128, scale = 0.5},
  {type = "sprite", name = "es-chute-v", filename = "__base__/graphics/entity/pipe/pipe-straight-vertical.png",
   size = 128, scale = 0.5},
})

---------------------------------------------------------------------------
-- Discovery chains: activated catalysts (prototype names say "refined"), made in a chemical plant from a
-- residue. The recipe unlocks when a station shows a clear gain from the residue on some target
-- (control.lua, check_discovery).
---------------------------------------------------------------------------
for i, a in ipairs(shared.additives) do
  if a.refined_from then
    local residue = shared.additive(a.refined_from)
    local parent = residue.spent_of
    local icons = icons_of(data.raw.item[RESIDUE_ICON[residue.residue_of]])
    for _, icon in ipairs(icons) do icon.tint = {r = 1.0, g = 0.85, b = 0.45} end
    table.insert(icons, {icon = "__base__/graphics/icons/fluid/sulfuric-acid.png", icon_size = 64, scale = 0.25,
      shift = {8, -8}})
    data:extend({
      {type = "item", name = a.name, icons = icons, subgroup = "es-spent", order = "r-" .. i, stack_size = 50},
      {type = "recipe", name = shared.refine_recipe(parent), category = "chemistry", enabled = false,
       energy_required = shared.refine.seconds,
       ingredients = {{type = "item", name = a.refined_from, amount = shared.refine.spent},
                      {type = "fluid", name = "sulfuric-acid", amount = shared.refine.acid}},
       results = {{type = "item", name = a.name, amount = 1}}, allow_decomposition = false,
       localised_name = {"recipe-name.es-refine", {"item-name." .. a.name}}},
    })
  end
end

---------------------------------------------------------------------------
-- Premixes (slice 3; control.lua unlocks one when a station shows its pair's synergy). One per pair of
-- base additives from different families, by phase: a blend (two solids, an assembler), a slurry (a
-- solid and a fluid, with water, a chemical plant), an emulsion (two fluids, with sulfur, a chemical
-- plant). Stable and volatile items (volatile only where spoiling exists). Kept out of Factoriopedia:
-- which pairs exist is for the player to find.
---------------------------------------------------------------------------
local spoiling = feature_flags and feature_flags.spoiling
data:extend({{type = "item-subgroup", name = "es-premixes", group = "intermediate-products", order = "z-premixes"}})
local PHASE_TINT = {blend = {r = 0.75, g = 0.75, b = 0.75}, slurry = {r = 0.7, g = 0.55, b = 0.4},
  emulsion = {r = 0.95, g = 0.85, b = 0.45}}
local function additive_proto(name)
  return shared.additive(name).fluid and data.raw.fluid[name] or data.raw.item[name]
end
local function additive_name(name)
  return shared.additive(name).fluid and {"fluid-name." .. name} or {"item-name." .. name}
end
for i, a in ipairs(shared.additives) do
  if a.premix_of and (not a.volatile or spoiling) then
    local tint = a.volatile and {r = 1, g = 0.55, b = 0.25} or PHASE_TINT[a.phase]
    local icons = {{icon = "__base__/graphics/icons/fluid/barreling/empty-barrel.png", icon_size = 64, tint = tint}}
    for k, member in ipairs(a.premix_of) do
      for _, ic in ipairs(icons_of(additive_proto(member))) do
        local small = table.deepcopy(ic)
        small.scale, small.shift = 0.25, {k == 1 and -8 or 8, -8}
        table.insert(icons, small)
      end
    end
    local name = {"item-name.es-" .. a.phase .. (a.volatile and "-volatile" or ""), additive_name(a.premix_of[1]),
      additive_name(a.premix_of[2])}
    local ingredients, category = {}, "chemistry"
    local fluids = 0
    -- A premix with an activated catalyst is not concentrated again: its catalyst already is.
    local with_catalyst = shared.additive(a.premix_of[1]).refined_from or shared.additive(a.premix_of[2]).refined_from
    local k = with_catalyst and shared.premix.concentrate_catalyst or shared.premix.concentrate
    for _, member in ipairs(a.premix_of) do
      local fluid = shared.additive(member).fluid
      if fluid then fluids = fluids + 1 end
      table.insert(ingredients, fluid and {type = "fluid", name = member, amount = math.ceil(shared.premix.fluid * k)}
        or {type = "item", name = member, amount = math.ceil(shared.premix.item * k)})
    end
    if a.phase == "blend" then
      category = "crafting"
    elseif a.phase == "slurry" and a.premix_of[1] ~= "water" and a.premix_of[2] ~= "water" then
      table.insert(ingredients, {type = "fluid", name = "water", amount = math.ceil(shared.premix.water * k)})
    elseif a.phase == "emulsion" then
      table.insert(ingredients, {type = "item", name = "sulfur", amount = math.ceil(shared.premix.sulfur * k)})
    end
    local recipe = {type = "recipe", name = shared.premix_recipe(a.premix_of[1], a.premix_of[2], a.volatile),
      category = category, enabled = false, energy_required = shared.premix.seconds, ingredients = ingredients,
      results = {{type = "item", name = a.name, amount = shared.premix.out}}, allow_decomposition = false,
      hide_from_player_crafting = true, hidden_in_factoriopedia = true,
      localised_name = name, icons = icons, subgroup = "es-premixes", order = string.format("%04d", i)}
    if a.fluid then
      -- A liquid premix: a fluid made cold (heaters warm it: see the fluid heaters).
      local c = tint
      recipe.results = {{type = "fluid", name = a.name, amount = shared.premix.fluid_out, temperature = shared.premix.cold}}
      data:extend({
        {type = "fluid", name = a.name, icons = icons, localised_name = name,
         localised_description = {"fluid-description.es-premix-liquid", tostring(shared.premix.cold)},
         default_temperature = shared.premix.cold, max_temperature = shared.fluid_max_temperature,
         base_color = {r = c.r * 0.6, g = c.g * 0.6, b = c.b * 0.6}, flow_color = c, subgroup = "es-premixes",
         order = string.format("%04d", i), hidden_in_factoriopedia = true},
        recipe,
      })
    else
      data:extend({
        {type = "item", name = a.name, icons = icons, localised_name = name,
         localised_description = {"item-description.es-premix" .. (a.volatile and "-volatile" or "")},
         subgroup = "es-premixes", order = string.format("%04d", i), stack_size = 50, hidden_in_factoriopedia = true,
         spoil_ticks = a.volatile and shared.premix.spoil_ticks or nil},
        recipe,
      })
    end
  end
end


-- The ending: unlocked by script when a force completes its dossiers.
data:extend({{type = "achievement", name = "es-dossiers-complete", order = "z[es]-a",
  icon = "__base__/graphics/achievement/you-are-doing-it-right.png", icon_size = 128}})
-- (0.72, user: more achievements, Factorio in flavour) Unlocked by script (control.lua, achieve). Those that
-- need Space Age or Quality exist only with them.
do
  local list = {
    {"lab-rat", "b"}, {"statistically-significant", "c"}, {"sum-of-parts", "d"}, {"waste-not", "e"},
    {"publish-or-perish", "f", tostring(shared.achievement_settled)}, {"large-numbers", "g", tostring(shared.achievement_samples)},
    {"reviewer-2", "h"}, {"brute-force", "i"}, {"replication-crisis", "j"},
    {"fieldwork", "k", nil, "space-age"}, {"cold-case", "l", nil, "space-age"}, {"gold-standard", "m", nil, "quality"},
  }
  for _, a in ipairs(list) do
    if not a[4] or mods[a[4]] then
      data:extend({{type = "achievement", name = "es-" .. a[1], order = "z[es]-" .. a[2],
        icon = GFX .. "achievement/" .. a[1] .. ".png", icon_size = 128,
        localised_description = a[3] and {"achievement-description.es-" .. a[1], a[3]} or nil}})
    end
  end
end

---------------------------------------------------------------------------
-- The main menu's scene (0.70, user; scripts/showcase.lua): vanilla's lab menu save with a dosed district pasted
-- in (built by hand, scenes/lab.lua). (0.71: the three scenes built from nothing retired, user.)
---------------------------------------------------------------------------
do
  -- Vanilla's own scene, the mod's machines added in (augment_showcase).
  local function augmented(key, save, daytime)
    return {
      checkboard = false,
      save = "__base__/menu-simulations/menu-simulation-" .. save .. ".zip",
      mods = {"empirical-science", "factorio-charts"},
      length = 60 * 10,
      -- (Built at load, it runs ten seconds before it shows: belts partly filled. User: thirty cost the menu
      -- half a second's pause when it reached the scene.)
      init_update_count = 600,
      init = string.format([[
        local s = game.surfaces.nauvis
        local logo = s.find_entities_filtered{name = "factorio-logo-11tiles", limit = 1}[1]
        local c = {logo.position.x, logo.position.y + 9.75}
        game.simulation.camera_position = c
        game.simulation.camera_zoom = 1
        game.tick_paused = false
        s.daytime = %s
        remote.call("empirical-science-scenes", "augment_showcase", %q, s.name, c)
      ]], tostring(daytime), key),
      update = "",
    }
  end
  local sims = data.raw["utility-constants"]["default"].main_menu_simulations
  sims.es_lab = augmented("lab", "lab", 0.5)
end
