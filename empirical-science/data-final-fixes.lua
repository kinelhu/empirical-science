-- After every mod's data stage: things that must see prototypes other mods define (Space Age's biolab
-- and technologies load after this mod's data.lua).
local shared = require("shared")
local DATA = "es-research-data"

local function has(ingredients, name)
  for _, i in ipairs(ingredients) do if (i[1] or i.name) == name then return true end end
  return false
end

-- Every lab takes research data.
for _, lab in pairs(data.raw.lab) do
  if not has(lab.inputs, DATA) then table.insert(lab.inputs, DATA) end
end

-- Recipe productivity for recipes the mod has as targets (Space Age: steel, low-density structures):
-- research data joins the packs, target-specific.
for name, tech in pairs(data.raw.technology) do
  local units
  for _, e in ipairs(tech.effects or {}) do
    if e.type == "change-recipe-productivity" and shared.data.productivity_units[e.recipe] then
      units = shared.data.productivity_units[e.recipe]
    end
  end
  -- (0.72: endless, so under the endless setting too)
  if units and settings.startup["es-data-in-endless"].value and tech.unit and not name:find("^es%-")
      and not has(tech.unit.ingredients, DATA) then
    table.insert(tech.unit.ingredients, {DATA, units})
  end
end

-- Vanilla's endless technologies take research data too (0.72: the sink that
-- replaced Mastery), priced per unit by docs/balance.py (shared.data.infinite_units).
for name, tech in pairs(data.raw.technology) do
  local units = settings.startup["es-data-in-endless"].value and shared.data.infinite_units[name]
  if units and tech.max_level == "infinite" and tech.unit and not has(tech.unit.ingredients, DATA) then
    table.insert(tech.unit.ingredients, {DATA, units})
  end
end

-- Map setting: research data in mainline technologies from a chosen pack tier on.
local tier = settings.startup["es-data-in-mainline"].value
if tier ~= "off" then
  for name, tech in pairs(data.raw.technology) do
    if not name:find("^es%-") and tech.unit and tech.unit.ingredients and has(tech.unit.ingredients, tier)
        and not has(tech.unit.ingredients, DATA) then
      table.insert(tech.unit.ingredients, {DATA, 1})
    end
  end
end

-- Fulgora scrap samples: one more result of scrap recycling, and
-- the recycler's thirteenth output slot it needs (scrap recycling had twelve results for twelve slots).
do
  local r = data.raw.recipe["scrap-recycling"]
  if r and data.raw.item[shared.scrap.item] then
    table.insert(r.results, {type = "item", name = shared.scrap.item, amount = 1, probability = shared.scrap.rate})
    for _, machine in pairs(data.raw.furnace) do
      for _, cat in ipairs(machine.crafting_categories or {}) do
        if cat == r.category or cat == "recycling" then
          machine.result_inventory_size = math.max(machine.result_inventory_size or 0, #r.results)
        end
      end
    end
  end
end

-- Other mods' targets. The derivation rule's guard runs on every load
-- (scripts/check.sh reads its log line); with the setting on, a failing guard stops the load.
local derive = require("derive")
local registry = data.raw["mod-data"][shared.REGISTRY]
local guard = derive.leave_one_out()
log("es-derive check: " .. guard.text)
if settings.startup["es-derive-targets"].value then
  if not guard.pass then
    error("empirical-science: the target derivation rule disagrees with the hand-written mixes (" .. guard.text
      .. "); turn off the setting \"Derive targets\"")
  end
  for key, entry in pairs(derive.packs(registry.data)) do registry.data[key] = entry end
end
local added = shared.register_targets(registry.data)
for i, target in ipairs(added) do
  require("data_targets").build_target(#shared.targets - #added + i, target, data.raw.technology["es-empirical-method"].effects)
  registry.data[target.key].built = true
end

-- Chilled twins: the vanilla fluid additives, with Space Age. Liquid premixes
-- have none since 0.71: their minimum is the twins' cold, and the fluid chiller cools them in place.
if mods["space-age"] and data.raw.fluid["fluoroketone-cold"] and data.raw.technology[shared.chilled.unlock] then
  local dt = require("data_targets")
  local CH = shared.chilled
  local cold_badge = dt.icons_of(data.raw.fluid["fluoroketone-cold"])
  data:extend({{type = "item-subgroup", name = "es-chilling", group = "intermediate-products", order = "z-es-chilling"}})
  for _, a in ipairs(shared.additives) do
    local base = a.fluid and data.raw.fluid[a.name]
    if base and a.premix_of then
      base.default_temperature = CH.temperature
      -- Emptied from a barrel at the temperature it is made at, not its minimum (or a barrel would chill it).
      local empty = data.raw.recipe["empty-" .. a.name .. "-barrel"]
      for _, r in ipairs(empty and empty.results or {}) do
        if r.type == "fluid" and r.name == a.name then r.temperature = shared.premix.cold end
      end
    elseif base and not data.raw.fluid[shared.chilled_of(a.name)] then
      local twin = table.deepcopy(base)
      twin.name = shared.chilled_of(a.name)
      twin.default_temperature = CH.temperature
      twin.max_temperature = base.default_temperature or 15
      twin.auto_barrel = false
      twin.icons = dt.with_badge(dt.icons_of(base), cold_badge); twin.icon = nil
      local base_name = base.localised_name or {"fluid-name." .. a.name}
      twin.localised_name = {"fluid-name.es-chilled", base_name}
      twin.subgroup = "es-chilling"
      twin.order = (a.premix_of and "b-" or "a-") .. a.name
      data:extend({twin,
        {type = "recipe", name = "es-chill-" .. a.name, category = "cryogenics", enabled = false, energy_required = 2,
         icons = twin.icons, subgroup = "es-chilling", order = twin.order,
         localised_name = {"recipe-name.es-chill", base_name},
         ingredients = {{type = "fluid", name = a.name, amount = CH.amount},
                        {type = "fluid", name = "fluoroketone-cold", amount = CH.fluoroketone}},
         results = {{type = "fluid", name = twin.name, amount = CH.amount, temperature = CH.temperature},
                    {type = "fluid", name = "fluoroketone-hot", amount = CH.fluoroketone, temperature = 180}},
         main_product = twin.name, allow_productivity = false, allow_decomposition = false}})
      table.insert(data.raw.technology[CH.unlock].effects, {type = "unlock-recipe", recipe = "es-chill-" .. a.name})
    end
  end
end

-- Fluid additives can be heated (shared.heaters): their ceiling is raised to shared.fluid_max_temperature
-- (vanilla oils and acid have a single temperature; water already reaches 100).
for _, a in ipairs(shared.additives) do
  local f = a.fluid and data.raw.fluid[a.name]
  if f then
    f.max_temperature = math.max(f.max_temperature or f.default_temperature or 15, shared.fluid_max_temperature)
  end
end

-- Residues leave a dosed machine by its trash slots (0.65, scripts/dosing.lua): every crafting machine
-- gets at least shared.trash_slots (vanilla gives none unless a recipe spoils).
for _, kind in ipairs({"assembling-machine", "furnace"}) do
  for _, m in pairs(data.raw[kind]) do
    m.trash_inventory_size = math.max(m.trash_inventory_size or 0, shared.trash_slots)
  end
end

-- The analysis station's size (0.72, user: so many slots for empirical science packs): its layout and no more.
-- The samples waiting, scrap samples (with Space Age), the packs out, one slot per kind of science pack a
-- target's sample needs (control.lua, reserve_sample_slots). An existing station's items are packed into the
-- slots that remain (seen in the engine: 36 slots of plates fitted 20 with nothing lost).
do
  local kinds = 0
  for name in pairs(data.raw["item-with-tags"]) do
    if name:find("^es%-sample%-") then kinds = kinds + 1 end
  end
  local scrap = data.raw.item[shared.scrap.item] and shared.scrap.slots or 0
  data.raw.container["es-analysis-station"].inventory_size = shared.station_sample_slots + scrap
    + shared.station_data_slots + math.max(kinds, 1)
end

-- Tips and tricks titles carry an icon, as vanilla's do (0.72, user: the pages were dry). A tag whose
-- prototype is missing (a mod not loaded) is left out.
do
  local agent = shared.agents[1] and shared.agents[1].name
  local TAGS = {
    ["es-title"] = {"item", "es-test-bench"},
    ["es-first-experiment"] = {"item", "es-test-bench"},
    ["es-samples"] = {"item", "es-sample-automation-science-pack"},
    ["es-sample-kinds"] = {"item", "es-sample-logistic-science-pack"},
    ["es-screen"] = {"item", "es-analysis-station"},
    ["es-screening"] = {"item", "coal"},
    ["es-science-packs"] = {"item", "es-research-data"},
    ["es-production"] = {"item", "es-hopper"},
    ["es-stages"] = {"technology", "es-empirical-method"},
    ["es-families"] = {"technology", "es-theory"},
    ["es-fluid-hoppers"] = {"item", "es-fluid-hopper"},
    ["es-temperature"] = {"item", "es-fluid-heater"},
    ["es-findings"] = {"virtual-signal", "signal-check"},
    ["es-ripeness"] = {"item", "yumako-mash"},
    ["es-scrap-samples"] = {"item", "es-scrap-sample"},
    ["es-quality-additives"] = agent and {"item", agent} or nil,
    ["es-residues"] = {"item", "es-spent-coal"},
    ["es-alt"] = {"virtual-signal", "signal-info"},
    ["es-dose-signal"] = {"item", "constant-combinator"},
    ["es-sweep"] = {"item", "decider-combinator"},
    ["es-station-signals"] = {"entity", "es-station-port"},
    ["es-port"] = {"item", "arithmetic-combinator"},
  }
  local kinds = {item = {"item", "item-with-tags", "tool", "capsule"}, technology = {"technology"}, ["virtual-signal"] = {"virtual-signal"},
    entity = {"constant-combinator", "container", "assembling-machine"}}
  for name, tag in pairs(TAGS) do
    local tip = data.raw["tips-and-tricks-item"][name]
    local found = false
    for _, t in ipairs(kinds[tag[1]]) do if data.raw[t] and data.raw[t][tag[2]] then found = true end end
    if tip and found then tip.tag = "[" .. tag[1] .. "=" .. tag[2] .. "]" end
  end
end
