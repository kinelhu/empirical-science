-- Data stage: a target's prototypes (trials) and the helpers they use. A module of its own so
-- data-final-fixes can build other mods' targets: the data stage
-- does not keep a module's state from one file to the next.
local shared = require("shared")

local dt = {}

local function icons_of(proto, tint)
  if proto.icons then return table.deepcopy(proto.icons) end
  return {{icon = proto.icon, icon_size = proto.icon_size or 64, tint = tint}}
end

-- Any item prototype by name, whatever its type (bioflux and eggs are capsules, packs are tools).
local function item_proto(name)
  for type_name in pairs(defines.prototypes.item) do
    if data.raw[type_name] and data.raw[type_name][name] then return data.raw[type_name][name] end
  end
end

local function with_badge(base_icons, badge_icons, shift)
  local icons = table.deepcopy(base_icons)
  for _, b in ipairs(badge_icons) do
    local small = table.deepcopy(b)
    small.scale = 0.25; small.shift = shift or {-8, -8}
    table.insert(icons, small)
  end
  return icons
end

-- A target's process mix, shown on its trials (decided 2026-10-02: static content, the Theory tab's
-- inputs; what each family does to each process stays hidden, per map).
local function process_text(process)
  if not process then return nil end
  local parts = {""}
  for _, class in ipairs(shared.process_classes) do
    local w = process[class]
    if w and w > 0 then
      if #parts > 1 then table.insert(parts, ", ") end
      table.insert(parts, {"es-process." .. class})
      table.insert(parts, " " .. math.floor(w * 100 + 0.5) .. "%")
    end
  end
  return {"recipe-description.es-trial-process", parts}
end

-- A target's batch in terms of its vanilla recipe: ingredients, crafting time, and the technology
-- that unlocks it. Fails the load on fluid ingredients or a batch that is not whole crafts.
local function vanilla(target)
  local r = data.raw.recipe[shared.target_recipe(target)]
  if not r then error("empirical-science: no vanilla recipe for target " .. shared.target_recipe(target)) end
  local out
  for _, res in ipairs(r.results) do if res.name == target.result then out = res.amount end end
  local crafts = target.batch / out
  if crafts ~= math.floor(crafts) then
    error("empirical-science: batch " .. target.batch .. " of " .. target.result .. " is not whole crafts of " .. out)
  end
  crafts = shared.trial_crafts(crafts, settings.startup["es-world-strength"].value)  -- (world strength)
  local ingredients = {}
  for _, ing in ipairs(r.ingredients) do
    table.insert(ingredients, {ing.name, ing.amount * crafts, ing.type or "item"})
  end
  local tech
  for name, t in pairs(data.raw.technology) do
    for _, e in ipairs(t.effects or {}) do
      if e.type == "unlock-recipe" and e.recipe == shared.target_recipe(target) then tech = name end
    end
  end
  return ingredients, (r.energy_required or 0.5) * crafts * shared.trial_time_factor, tech
end

-- Recipe ingredients, merging an additive that is also a normal ingredient (copper cable in circuits).
local function ingredients_for(target, additive, dose)
  local list, index = {}, {}
  for _, ing in ipairs(target.ingredients) do
    table.insert(list, {type = ing[3] or "item", name = ing[1], amount = ing[2]})
    index[ing[1]] = #list
  end
  if additive then
    if index[additive] then
      list[index[additive]].amount = list[index[additive]].amount + dose
    else
      table.insert(list, {type = "item", name = additive, amount = dose})
    end
  end
  return list
end

-- The sample a target's trials make (0.72, user: samples of every tier looked alike): one item per science
-- pack, the pack drawn on a report's blank cover. The pack is the one control.lua's pack_for reads back from
-- the trial: a planet's own, else the last pack of the technology unlocking the target (red when none).
local SAMPLE_COVER = "__empirical-science__/graphics/sample-cover.png"
local function sample_item(target, tech)
  local pack = target.pack and item_proto(target.pack) and target.pack
  if not pack and tech then
    local ings = data.raw.technology[tech].unit and data.raw.technology[tech].unit.ingredients or {}
    local last = ings[#ings]
    pack = last and (last[1] or last.name)
  end
  pack = pack or shared.pack
  local name = shared.sample_of(pack)
  if not data.raw["item-with-tags"][name] then
    local icons = {{icon = SAMPLE_COVER, icon_size = 64}}
    for _, layer in ipairs(icons_of(item_proto(pack))) do
      local small = table.deepcopy(layer)
      small.scale = 0.22 * 64 / (small.icon_size or 64)
      small.shift = {1, -3}
      table.insert(icons, small)
    end
    -- (Weighed like a science pack, 1,000 to a rocket: made by script, it had the default of 10,000.)
    data:extend({{type = "item-with-tags", name = name, icons = icons, stack_size = 1, weight = 1000,
      localised_name = {"item-name.es-sample-of", item_proto(pack).localised_name or {"item-name." .. pack}},
      localised_description = {"item-description.es-sample"},
      subgroup = "science-pack", order = "z[es-sample]-" .. (item_proto(pack).order or pack)}})
  end
  return name
end

-- One target's prototypes; data-final-fixes calls it again for other mods' targets.
local function build_target(ti, target, method_unlocks)
  local tech
  target.ingredients, target.trial_time, tech = vanilla(target)
  target.survivors = math.floor(shared.survivor_share * target.batch)
  -- A target's trials unlock with the technology that unlocks the target itself.
  local target_unlocks = tech and data.raw.technology[tech].effects or method_unlocks
  local result_icons = icons_of(item_proto(target.result))
  -- (0.72, user: an "Automation science pack trial" signal looked exactly like the pack in a circuit condition)
  -- A trial recipe carries the test bench in its corner.
  local bench_badge = {{icon = "__empirical-science__/graphics/test-bench-icon.png", icon_size = 64}}
  local trial_icons = with_badge(result_icons, bench_badge, {8, 8})
  data:extend({{type = "item-subgroup", name = "es-trial-" .. target.key, group = "es-experiments",
    order = string.format("%02d", ti)}})

  -- The trial: one batch in, survivors and a sample out; its dose comes from the bench's hoppers.
  local name = shared.trial_recipe(target.key)
  local sample = sample_item(target, tech)
  target.sample = sample
  local results = {{type = "item", name = sample, amount = 1}}
  if target.survivors > 0 then
    table.insert(results, 1, {type = "item", name = target.result, amount = target.survivors})
  end
  data:extend({{
    type = "recipe", name = name, category = "es-experiment",
    localised_name = {"recipe-name.es-trial-control",
      item_proto(target.result).localised_name  -- (other mods' items; a placeable item may be named by its entity)
        or {"?", {"item-name." .. target.result}, {"entity-name." .. target.result}}},
    subgroup = "es-trial-" .. target.key, order = "0",
    enabled = false, energy_required = target.trial_time,
    ingredients = ingredients_for(target, nil, 0), results = results,
    surface_conditions = table.deepcopy(data.raw.recipe[shared.target_recipe(target)].surface_conditions),
    main_product = sample, allow_productivity = false, allow_quality = false,
    allow_decomposition = false, icons = trial_icons,
    -- Pickable as a recipe signal (0.49): a circuit sets a bench's trial with vanilla "set recipe".
    hide_from_signal_gui = false,
    localised_description = target.derived and {"", process_text(target.process), "\n", {"es.derived-target"}}
      or process_text(target.process),
  }})
  table.insert(target_unlocks, {type = "unlock-recipe", recipe = name})

end

dt.icons_of, dt.item_proto, dt.with_badge, dt.process_text = icons_of, item_proto, with_badge, process_text
dt.vanilla, dt.ingredients_for, dt.build_target = vanilla, ingredients_for, build_target

return dt
