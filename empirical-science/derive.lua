-- The derivation rule for other mods' targets (data stage only): a
-- process mix from a recipe, and its leave-one-out guard against the hand-written mixes. The rule was
-- written before its guard was first run; its categories and depth are not tuned to the guard.
local shared = require("shared")

local derive = {}
derive.DEPTH = 3

-- A recipe category's class, by name (the "-or-" variants with their first named class): metalwork
-- before chemistry before electronics; anything else has none.
local CATEGORY = {
  {class = "metalwork", words = {"smelting", "metallurgy", "pressing"}},
  {class = "chemistry", words = {"chemistry", "oil%-processing", "cryogenic", "organic"}},
  {class = "electronics", words = {"electronics", "electromagnetic"}},
}
local function category_class(category)
  for _, c in ipairs(CATEGORY) do
    for _, w in ipairs(c.words) do
      if category:find(w) then return c.class end
    end
  end
end

-- Built-in (hand-written) targets by product.
local function hand_mixes()
  local out = {}
  for _, t in ipairs(shared.targets) do
    if not t.registered then out[t.result] = t end
  end
  return out
end

local function normalised(v)
  local sum = 0
  for _, c in ipairs(shared.process_classes) do sum = sum + (v[c] or 0) end
  if sum <= 0 then return nil end
  local out = {}
  for _, c in ipairs(shared.process_classes) do out[c] = (v[c] or 0) / sum end
  return out
end

local mix_of_item
-- A recipe's mix: its category's class (weight 1) plus the mean of its ingredients' mixes, each
-- ingredient counted once; nil when neither says anything.
local function mix_of_recipe(r, depth, hand, withheld)
  local acc, n = {}, 0
  for _, ing in ipairs(r.ingredients or {}) do
    local m
    if ing.type == "fluid" then m = {chemistry = 1} else m = mix_of_item(ing.name, depth - 1, hand, withheld) end
    if m then
      local norm = normalised(m)
      for _, c in ipairs(shared.process_classes) do acc[c] = (acc[c] or 0) + norm[c] end
      n = n + 1
    end
  end
  local cat = category_class(r.category or "crafting")
  if n == 0 and not cat then return nil end
  local v = {}
  for _, c in ipairs(shared.process_classes) do v[c] = (n > 0 and acc[c] / n or 0) + (cat == c and 1 or 0) end
  return normalised(v)
end
-- An item's mix: a built-in target's hand-written one (unless withheld), else its recipe's (the recipe
-- named after it), while depth lasts.
mix_of_item = function(name, depth, hand, withheld)
  local t = hand[name]
  if t and t.key ~= withheld then return t.process end
  if depth <= 0 then return nil end
  local r = data.raw.recipe[name]
  if not r then return nil end
  return mix_of_recipe(r, depth, hand, withheld)
end

function derive.mix(recipe)
  return mix_of_recipe(recipe, derive.DEPTH, hand_mixes(), nil)
end

-- The classes holding a mix's largest weight (ties: all of them).
local function top_classes(m)
  local best, out = -1, {}
  for _, c in ipairs(shared.process_classes) do best = math.max(best, m[c] or 0) end
  for _, c in ipairs(shared.process_classes) do
    if (m[c] or 0) >= best - 1e-9 then out[c] = true end
  end
  return out
end
local function cosine(a, b)
  local ab, aa, bb = 0, 0, 0
  for _, c in ipairs(shared.process_classes) do
    ab, aa, bb = ab + (a[c] or 0) * (b[c] or 0), aa + (a[c] or 0) ^ 2, bb + (b[c] or 0) ^ 2
  end
  return ab / math.sqrt(aa * bb)
end

-- The guard: each built-in target's mix derived with its own withheld, against the hand-written one.
-- Holds when derivable on 90% of them, the derived top class among the hand-written top classes on 75%
-- of them, and the median cosine (over the derivable) at least 0.9.
function derive.leave_one_out()
  local hand = hand_mixes()
  local n, defined, same, cosines, misses = 0, 0, 0, {}, {}
  for _, t in ipairs(shared.targets) do
    if not t.registered then
      n = n + 1
      local r = data.raw.recipe[shared.target_recipe(t)]
      local m = r and mix_of_recipe(r, derive.DEPTH, hand, t.key)
      if m then
        defined = defined + 1
        local mine, theirs, hit = top_classes(m), top_classes(normalised(t.process)), false
        for c in pairs(mine) do if theirs[c] then hit = true end end
        if hit then same = same + 1 else table.insert(misses, t.key) end
        table.insert(cosines, cosine(m, t.process))
      else
        table.insert(misses, t.key .. " (underived)")
      end
    end
  end
  table.sort(cosines)
  local median = #cosines > 0 and (cosines[math.floor((#cosines + 1) / 2)] + cosines[math.ceil((#cosines + 1) / 2)]) / 2 or 0
  local pass = defined >= 0.9 * n and same >= 0.75 * n and median >= 0.9
  return {pass = pass, text = string.format("derivable %d/%d, same top class %d/%d, median cosine %.3f: %s%s",
    defined, n, same, n, median, pass and "pass" or "FAIL",
    #misses > 0 and ("; missed " .. table.concat(misses, ", ")) or "")}
end

-- With the setting on: every science pack a lab takes that is not yet a target (nor registered), with a
-- recipe named after it, as an entry for the registry.
function derive.packs(registered)
  local taken = {}
  for _, t in ipairs(shared.targets) do taken[t.result] = true end
  for _, e in pairs(registered) do taken[e.result] = true end
  local packs = {}
  for _, lab in pairs(data.raw.lab) do
    for _, name in ipairs(lab.inputs or {}) do packs[name] = true end
  end
  local out = {}
  for name in pairs(packs) do
    local r = data.raw.recipe[name]
    if not taken[name] and not registered[name] and not name:find("^es%-") and data.raw.tool[name] and r then
      local m = derive.mix(r)
      local per_craft, made = 0, 0
      for _, ing in ipairs(r.ingredients or {}) do
        if ing.type ~= "fluid" then per_craft = per_craft + ing.amount end
      end
      for _, res in ipairs(r.results or {}) do
        if res.name == name and res.amount then made = res.amount end
      end
      if m and made > 0 then
        local crafts = math.max(1, math.ceil(shared.batch_ore / math.max(per_craft, 1)))
        out[name] = {result = name, batch = crafts * made, process = m, derived = true}
      end
    end
  end
  return out
end

return derive
