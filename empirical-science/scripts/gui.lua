-- Analysis panel, attached to the right of the station's inventory window.
-- Controls are built once in gui.open; gui.refresh only rewrites data, because rebuilding a
-- drop-down while a player has it open closes it under their cursor.
local shared = require("shared")
local stats = require("scripts.stats")
local theory = require("scripts.theory")
local regress = require("scripts.regress")
local truth = require("scripts.truth")
local chart = require("scripts.chart")
local research = require("scripts.research")
local dosing = require("scripts.dosing")
local dossiers = require("scripts.dossiers")

local gui = {}

local STATION = "es-analysis-station"
local axis_min, axis_max, bar_px = -500, 1000, 140  -- CI bar axis in per mille
-- Screening grid cells: direction of a significant effect (Okabe-Ito bluish green and vermillion).
local effect_colour = {
  gain = {r = 0.0, g = 0.62, b = 0.45}, gain_faint = {r = 0.45, g = 0.75, b = 0.62},
  loss = {r = 0.84, g = 0.37, b = 0.0}, loss_faint = {r = 0.9, g = 0.6, b = 0.4},
}

local function pct(permille) return string.format("%+.1f%%", permille / 10) end


-- Icon and the game's own name (composed names such as "Spent stone" come from the prototype).
local function item_caption(name)
  local a = shared.additive(name)
  if a and a.fluid then return {"", "[fluid=" .. name .. "] ", prototypes.fluid[name].localised_name} end
  return {"", "[item=" .. name .. "] ", prototypes.item[name].localised_name}
end
gui.item_caption = item_caption

-- Additives a force can see: refined catalysts only once discovered (their refine recipe unlocked); the
-- rest once the force can make them or has evidence on them (0.72, user: holmium plates listed on Nauvis).
function gui.visible_additives(force)
  local seen = storage.additives_seen and storage.additives_seen[force.index] or {}
  local list = {}
  for _, a in ipairs(shared.all_additives) do
    local visible
    if a.agent then  -- quality agents once Quality additives is researched
      visible = shared.stage_ok(force, shared.stages.quality.tech)
    -- Premixes and activated residues once unlocked, or once there is evidence on them (0.72: a premix piped in
    -- without its recipe, in the playtest kit, had results the screen did not list), as every other additive.
    elseif a.premix_of then  -- (its recipe: the variant this map uses)
      local r = force.recipes[a.name]
      visible = (r ~= nil and r.enabled) or seen[a.name] == true
    elseif a.tier == 3 then
      visible = force.recipes[shared.refine_recipe(shared.additive(a.refined_from).spent_of)].enabled or seen[a.name] == true
    else
      visible = shared.unlocked(force, a) and (seen[a.name] or gui.can_make(force, a))
    end
    if visible then table.insert(list, a) end
  end
  return list
end

-- Rebuild an additive drop-down when the visible list has changed (a catalyst was discovered while
-- the panel was open): otherwise positions would point at the wrong additive or past the end.
local function refresh_items(el, visible)
  if #el.items ~= #visible then
    local items = {}
    for i, a in ipairs(visible) do items[i] = item_caption(a.name) end
    el.items = items
  end
end

local function index_of(list, name)
  for i, a in ipairs(list) do if a.name == name then return i end end
  return 1
end

-- Selections are stored by name (older versions stored positions: converted here).
local function stored_name(value, default)
  if type(value) == "number" then return shared.additives[value] and shared.additives[value].name or default end
  return value or default
end

-- Doses tested for one additive in a target's data (single-additive keys only), sorted.
local function tested_doses(obs, additive)
  -- (0.72: from the index; a copy, as callers may keep it)
  local doses = {}
  for i, d in ipairs(research.index(obs).doses[additive] or {}) do doses[i] = d end
  return doses
end

-- Doses to list for an additive: every dose for items, the tested ones for fluids.
local function listed_doses(obs, additive)
  local a = shared.additive(shared.split_band(additive))
  if a.fluid then return tested_doses(obs, additive) end
  local doses = {}
  for d = 1, a.max_dose do doses[d] = d end
  return doses
end

local function ci_bar(parent, s)
  local flow = parent.add{type = "flow", direction = "horizontal"}
  flow.style.width = bar_px
  flow.style.horizontal_spacing = 0
  if not (s and s.half) then return end
  local scale = bar_px / (axis_max - axis_min)
  local lo = math.max(axis_min, math.min(axis_max, s.lo))
  local hi = math.max(axis_min, math.min(axis_max, s.hi))
  local pad = flow.add{type = "empty-widget"}
  pad.style.width = math.floor((lo - axis_min) * scale)
  local bar = flow.add{type = "progressbar", value = 1}
  bar.style.width = math.max(3, math.floor((hi - lo) * scale))
  bar.style.color = {r = 0.35, g = 0.7, b = 1.0}
end

local function gain_caption(s)
  if s and s.half then return pct(s.mean) .. "  [" .. pct(s.lo) .. ", " .. pct(s.hi) .. "]" end
  if s then return pct(s.mean) end
  return "–"
end

-- One form for "how sure" (0.67): a result against its control, as the
-- bound it clears. Proven gain: its lower bound, green. Proven harm: its upper bound, vermillion. Not
-- clear yet: the average with "~", grey. The same Z as research data and findings.
local UNCLEAR = {r = 0.6, g = 0.6, b = 0.6}
function gui.bound_of(s, control)
  if not (s and control and s.var and control.var) then return nil end
  local diff = s.mean - control.mean
  local se = math.sqrt(s.var / s.n + control.var / control.n)
  return diff, diff - research.Z * se, diff + research.Z * se, stats.welch(s, control)
end
local function p_caption(p)
  if not p then return "–" end
  return p < 0.001 and "< 0.001" or string.format("%.3f", p)
end
-- The label (and its tooltip) for a result; `dose` adds "@dose"; `extra` adds a tooltip line.
local function bound_label(parent, s, control, dose, extra)
  local diff, lo, hi, p = gui.bound_of(s, control)
  local at = dose and ("  @" .. dose) or ""
  if not diff then
    local l = parent.add{type = "label", caption = s and s.mean and control and {"", "~", pct(s.mean - control.mean), at} or "–",
      tooltip = s and {"es.cell-few"} or nil}
    l.style.font_color = UNCLEAR
    return l
  end
  local caption, colour, head
  if lo > 0 then caption, colour, head = pct(lo), effect_colour.gain, {"es.cell-at-least", pct(lo)}
  elseif hi < 0 then caption, colour, head = pct(hi), effect_colour.loss, {"es.cell-at-most", pct(hi)}
  else caption, colour, head = "~" .. pct(diff), UNCLEAR, {"es.cell-between", pct(lo), pct(hi)} end
  local tip = {"", head, "\n", {"es.cell-detail", pct(diff), tostring(s.n), p_caption(p)}}
  if extra then tip = {"", tip, "\n", extra} end
  local l = parent.add{type = "label", caption = {"", caption, at}, tooltip = tip}
  l.style.font_color = colour
  return l
end

-- Effects measured on every sample (7d): yield, speed, pollution ("good is positive": faster, cleaner).
gui.effects = {"yield", "speed", "pollution", "efficiency", "freshness"}
-- Dose-response views: every effect, then the full cost.
gui.views = {"yield", "speed", "pollution", "efficiency", "freshness", "fullcost"}
-- A player's prices for the full cost: a preset (shared.prices) or their own, set with the sliders.
function gui.prices(player)
  storage.gui_prices = storage.gui_prices or {}
  local p = storage.gui_prices[player.index]
  if not p then
    p = shared.copy(shared.prices.early)
    p.preset = "early"
    storage.gui_prices[player.index] = p
  end
  return p
end
-- The prices the full cost uses on the planet the screen shows (research.price_on).
function gui.priced(player)
  return (research.price_on(gui.prices(player), gui.view_surface(player)))
end
gui.price_presets = {"early", "late", "custom"}
gui.price_sliders = {{key = "machine_second", max = 1, step = 0.005}, {key = "mj", max = 0.5, step = 0.01},
                     {key = "pollution", max = 1, step = 0.05}}
local EMPTY = {n = 0, sum = 0, sumsq = 0}

-- A target's data for one effect: keys "control", "additive:dose", mixtures.
function gui.obs_of(station, target_key, effect)
  if not effect or effect == "yield" then return station.obs[target_key] or {control = EMPTY} end
  local t = station.side and station.side[effect]
  return t and t[target_key] or {control = EMPTY}
end

-- The force's pool (control.lua): what the screen and the ports read. Empty until a first sample.
local EMPTY_POOL = {obs = {}, side = {}, analysed = 0, unreadable = 0}
function gui.pool(force, skey)
  local by = storage.pools and storage.pools[force.index]
  return by and by[skey or "nauvis"] or EMPTY_POOL
end

-- The planet a player's screen shows (per player; by default where they stand).
function gui.view_surface(player)
  local k = storage.gui_view_surface and storage.gui_view_surface[player.index]
  return k or shared.surface_key(player.surface)
end
-- Surfaces with evidence for a force, and the player's own: the screen's planet selector.
function gui.surfaces_for(player)
  local list, seen = {}, {}
  local function add(k) if not seen[k] then seen[k] = true; table.insert(list, k) end end
  add(gui.view_surface(player)); add(shared.surface_key(player.surface))
  for k, pool in pairs(storage.pools and storage.pools[player.force.index] or {}) do
    if pool.analysed > 0 then add(k) end
  end
  table.sort(list)
  return list
end

-- The target a player's screen shows (per player: the screen is not a building's).
function gui.view_target(player)
  local key = storage.gui_view_target and storage.gui_view_target[player.index]
  return key and shared.target(key) and key or shared.targets[1].key
end

-- The effect a player's Dose-response and Mixtures tabs show.
function gui.effect(player)
  if not shared.stage_ok(player.force, shared.side_effects_tech) then return "yield" end  -- staged reveal
  return storage.gui_effect and storage.gui_effect[player.index] or "yield"
end

-- The full cost view: each dose's yield summary moved to the full cost it saves (per mille of the vanilla
-- product's cost, research.full_saving), from the means of its four effects at the player's prices. The
-- spread stays the yield's (it dominates the composite's noise); an effect not measured counts as zero.
local function full_summaries(station, target_key, prices)
  local by = {}
  for _, e in ipairs(gui.effects) do by[e] = gui.summaries(station, target_key, e) end
  local function shift(s, saving)
    if not (s and saving) then return s end
    local d = saving * 1000 - s.mean
    return {n = s.n, mean = s.mean + d, var = s.var, half = s.half, lo = s.lo and s.lo + d, hi = s.hi and s.hi + d}
  end
  local function m(s) return s and s.mean and s.mean / 1000 or 0 end
  local function saving(mix, ys, ss, ps, es)
    return research.full_saving(target_key, mix, m(ys), m(ss), m(ps), m(es), prices)
  end
  local out = {additives = {}, bands = {}}
  local yc = by.yield.control
  out.control = shift(yc, yc and saving({}, yc, by.speed.control, by.pollution.control, by.efficiency.control))
  -- A row in full cost: each dose's yield shifted by the saving, its speed, cleanliness and efficiency read
  -- in the same band as the yield (review 0.68: banded rows plotted raw yield, and the side effects came
  -- from each effect's own best band).
  local function full_row(name, row, band)
    local nrow = {doses = {}, n = row.n, band = row.band}
    for d, ys in pairs(row.doses) do
      local function side(e)
        local r = band and by[e].bands[name] and by[e].bands[name][band] or by[e].additives[name]
        return r and r.doses[d]
      end
      nrow.doses[d] = shift(ys, saving({[shared.split_band(name)] = d}, ys, side("speed"), side("pollution"), side("efficiency")))
      local s = nrow.doses[d]
      if s and s.half and (not nrow.best or s.lo > nrow.doses[nrow.best].lo) then nrow.best = d end
    end
    return nrow
  end
  for name, row in pairs(by.yield.additives) do out.additives[name] = full_row(name, row, row.band) end
  for name, bands in pairs(by.yield.bands) do
    out.bands[name] = {}
    for b, row in pairs(bands) do out.bands[name][b] = full_row(name, row, b) end
  end
  return out
end

-- Summaries for one target and effect: control, and per additive per dose.
-- A fluid's rows are per temperature band: its usual band unsuffixed ("name"), others "name@b"; its
-- Screening row is its best band (kept in the row), every band's row in out.bands[name][b].
local function usual_band(name)
  local a = shared.additive(name)
  if a and a.living then return 0 end  -- (ripeness: the freshest band)
  return shared.temp_band(shared.usual_temp(name))
end
-- What an additive's evidence is banded by (0.62): temperature for fluids, ripeness for living additives.
local function band_kind(name)
  local a = shared.additive(name)
  return a and (a.living and "ripe" or a.fluid and "temp") or nil
end
gui.band_kind = band_kind
local function bands_of(kind) return kind == "ripe" and shared.ripe_bands() or shared.all_bands() end
local function suffix_of(kind) return kind == "ripe" and "~" or "@" end
gui.usual_band = usual_band
function gui.summaries(station, target_key, effect, prices)
  if effect == "fullcost" then return full_summaries(station, target_key, prices) end
  local obs = gui.obs_of(station, target_key, effect)
  local out = {control = stats.summary(obs.control), additives = {}, bands = {}}
  local function row_of(key_name)
    local doses, best, n = {}, nil, 0
    for _, d in ipairs(tested_doses(obs, key_name)) do
      doses[d] = stats.summary(obs[key_name .. ":" .. d])
      n = n + doses[d].n
      -- (0.72, advisory pass: the best mean moves as samples arrive, so the row's dose and its Net flipped)
      -- The best dose by lower bound, as research picks it.
      if doses[d].half and (not best or doses[d].lo > doses[best].lo) then best = d end
    end
    return {doses = doses, best = best, n = n}
  end
  for _, a in ipairs(shared.all_additives) do
    local row = row_of(a.name)
    local kind = band_kind(a.name)
    if kind then
      local ub = usual_band(a.name)
      row.band = ub
      out.bands[a.name] = {[ub] = row}
      local n = row.n
      local function top(x) return x.best and x.doses[x.best].lo or -math.huge end
      for _, b in ipairs(bands_of(kind)) do
        if b ~= ub then
          local r = row_of(a.name .. suffix_of(kind) .. b)
          r.band = b
          out.bands[a.name][b] = r
          n = n + r.n
          if r.best and (not row.best or top(r) > top(row)) then row = r end
        end
      end
      row = {doses = row.doses, best = row.best, n = n, band = row.band}  -- n: every band's samples
    end
    out.additives[a.name] = row
  end
  return out
end

-- Regression input for one additive: the control as dose 0, then each dose.
function gui.points(station, target_key, additive, effect, prices)
  if effect == "fullcost" then
    -- From the full cost summaries: one point per dose, its spread the yield's.
    local sums = full_summaries(station, target_key, prices)
    local out = {}
    local function add(dose, s)
      if s and s.n > 0 then table.insert(out, {dose = dose, n = s.n, mean = s.mean, ss = (s.var or 0) * (s.n - 1)}) end
    end
    add(0, sums.control)
    local row = sums.additives[additive]
    for d, s in pairs(row and row.doses or {}) do add(d, s) end
    table.sort(out, function(x, y) return x.dose < y.dose end)
    return out
  end
  local obs = gui.obs_of(station, target_key, effect)
  local points = {}
  local function add(dose, acc)
    if acc.n > 0 then
      local mean = acc.sum / acc.n
      table.insert(points, {dose = dose, n = acc.n, mean = mean, ss = acc.sumsq - acc.n * mean * mean})
    end
  end
  add(0, obs.control or EMPTY)
  for _, d in ipairs(tested_doses(obs, additive)) do add(d, obs[additive .. ":" .. d]) end
  return points
end

local function selected_additive(player)
  local visible = gui.visible_additives(player.force)
  return visible[index_of(visible, stored_name(storage.gui_selected[player.index], "coal"))].name
end

-- The dose picker offers what the force can make now: the mod's own additives once
-- unlocked (as above), a vanilla one once an enabled recipe makes it or the force has produced it
-- (mined, pumped or crafted) on some surface. Recipes that make an additive: prototype data, built once.
local makers = {}
local function makers_of(a)
  if not makers[a.name] then
    local list = {}
    local filter = {{filter = a.fluid and "has-product-fluid" or "has-product-item",
                     elem_filters = {{filter = "name", name = a.name}}}}
    for name in pairs(prototypes.get_recipe_filtered(filter)) do
      if not name:find("^es%-") then table.insert(list, name) end  -- the mod's own recipes are not makers
    end
    makers[a.name] = list
  end
  return makers[a.name]
end
function gui.can_make(force, a)
  -- A residue like a raw item: once some has been made or its own recipe is open (decided 2026-10-02).
  if a.residue_of then
    local r = force.recipes[a.name]
    if r and r.enabled then return true end
    for _, surface in pairs(game.surfaces) do
      if force.get_item_production_statistics(surface).get_input_count(a.name) > 0 then return true end
    end
    return false
  end
  if a.name:find("^es%-") then return true end
  for _, name in ipairs(makers_of(a)) do
    local r = force.recipes[name]
    if r and r.enabled and not r.hidden then return true end
  end
  for _, surface in pairs(game.surfaces) do
    local st = a.fluid and force.get_fluid_production_statistics(surface) or force.get_item_production_statistics(surface)
    if st.get_input_count(a.name) > 0 then return true end
  end
  return false
end
function gui.pickable_additives(force)
  local list = {}
  for _, a in ipairs(gui.visible_additives(force)) do
    if gui.can_make(force, a) then table.insert(list, a) end
  end
  return list
end

-- Samples on a target: every analysed sample lands in one cell of its yield table.
function gui.samples_on(pool, key)
  local n = 0
  for _, acc in pairs(pool.obs[key] or {}) do n = n + (acc.n or 0) end
  return n
end
-- Targets on offer: every target whose trial is unlocked or that has evidence, and the one shown. `sampled_only`
-- (0.70, user: scrap samples land on many targets, found only by trying each): the targets with samples, when
-- there are any, plus the one shown.
function gui.targets_for(pool, force, shown, sampled_only)
  local list, sampled = {}, {}
  for _, t in ipairs(shared.all_targets) do
    -- A target shows once its trial is unlocked, or when it has evidence.
    local open = force.recipes[shared.trial_recipe(t.key)] and force.recipes[shared.trial_recipe(t.key)].enabled
    local evidence = gui.samples_on(pool, t.key) > 0
    if open or evidence or t.key == shown then table.insert(list, t) end
    if evidence or t.key == shown then table.insert(sampled, t) end
  end
  local any = false
  for _, t in ipairs(sampled) do if gui.samples_on(pool, t.key) > 0 then any = true end end
  if sampled_only and any then return sampled end
  return list
end
function gui.all_targets_on(player)
  return storage.gui_all_targets and storage.gui_all_targets[player.index] or false
end

-- The model drop-down: Automatic first (the default), then each model.
gui.model_choices = {"auto"}
for _, m in ipairs(regress.models) do table.insert(gui.model_choices, m) end
local function selected_model(player)
  return gui.model_choices[storage.gui_model[player.index] or 1]
end

-- Footer: how many compositions are saved as presets for this target (dosed at the machines, scripts/dosing.lua).
local function foot_caption(player, target)
  local force = player.force
  local pieces = {}
  local presets = 0
  for _, p in ipairs(dosing.presets(force)) do if p.target == target.key then presets = presets + 1 end end
  table.insert(pieces, {"es.foot-presets", presets})
  local joined = {""}
  for i, piece in ipairs(pieces) do
    if i > 1 then table.insert(joined, ", ") end
    table.insert(joined, piece)
  end
  return {"es.foot", shared.target_caption(target), joined}
end



-- One effect's cell in the Screening grid: at the dose shown, the result against the control.
local function effect_cell(o, s, dose, control, own_best)
  if not s then o.add{type = "label", caption = "–"}; return end
  bound_label(o, s, control, dose, own_best and {"es.cell-own-best", tostring(own_best)})
end

local function about(n)
  if n == math.huge or n > 150 then return ">150" end
  if n <= 5 then return "~" .. math.max(n, 1) end
  local mag = 10 ^ math.floor(math.log(n, 10))
  return "~" .. math.floor(n / mag + 0.5) * mag
end
gui.about = about
local function data_cell(o, row)
  if not row then o.add{type = "label", caption = "–"}; return end
  -- Net (0.72, user: what did Pays? say that the columns beside it did not): the gain after the dose's
  -- own cost at the best dose, in the same form as every effect cell; the samples still needed on hover.
  local caption, colour, tip
  if row.quality then
    caption, colour = "–", UNCLEAR
    tip = row.state == "settled" and {"es.settle-agent-done"} or {"es.settle-agent"}
  elseif not row.net then
    caption, colour, tip = "–", UNCLEAR, {"es.settle-unknown"}
  else
    local lo, hi = row.net - row.half, row.net + row.half
    local k = "es.net-"
    if lo > 0 then caption, colour, tip = pct(lo), effect_colour.gain, {k .. "at-least", pct(lo)}
    elseif hi < 0 then caption, colour, tip = pct(hi), effect_colour.loss, {k .. "at-most", pct(hi)}
    else caption, colour, tip = "~" .. pct(row.net), UNCLEAR, {k .. "between", pct(lo), pct(hi)} end
    if row.state ~= "settled" and row.left then tip = {"", tip, "\n", {"es.net-more", about(row.left)}} end
  end
  local l = o.add{type = "label", caption = caption, tooltip = tip}
  l.style.font_color = colour
end
-- Packs per sample (0.72, user: a screening target of its own, for players after empirical science packs).
local function rate_cell(o, rate)
  o.add{type = "label", caption = rate and string.format("%.2f", rate) or "–"}
end

-- Quality (with the quality mod): an agent's best dose by upgrade rate. Counts until 50 units are
-- rolled ("3 of 40"), then the rate, with its Wilson interval on hover. Other additives: "–", the rule
-- on hover (only agents change quality).
local QUALITY_MIN = shared.quality_min_units
local function quality_cell(o, qual, name)
  if not shared.is_agent(name) then
    o.add{type = "label", caption = "–", tooltip = {"es.quality-not-agent"}}
    return
  end
  local best, best_d, total = nil, nil, 0
  for key, q in pairs(qual or {}) do
    local a, d = key:match("^([^+:]+):(%d+)$")
    if a == name then
      total = total + q.b
      if q.b > 0 and (not best or q.k / q.b > best.k / best.b) then best, best_d = q, tonumber(d) end
    end
  end
  if not best then o.add{type = "label", caption = "–"}; return end
  if total < QUALITY_MIN then
    o.add{type = "label", caption = {"es.quality-count", best.k, best.b, tostring(best_d)},
      tooltip = {"es.quality-count-tooltip", tostring(QUALITY_MIN)}}
    return
  end
  local p, lo, hi = stats.wilson(best.k, best.b)
  local function rate(x) return string.format("%.1f%%", x * 100) end
  o.add{type = "label", caption = {"es.quality-at-dose", rate(p), tostring(best_d)},
    tooltip = {"es.quality-tooltip", rate(lo), rate(hi), best.k, best.b}}
end

-- Staged reveal: speed and cleanliness before Precision instruments 1, grey with the reason on hover.
local function unmeasured(l)
  l.tooltip = {"es.side-unmeasured", shared.tech_caption(shared.side_effects_tech)}
  l.style.font_color = {0.5, 0.5, 0.5}
  return l
end
local function unmeasured_cell(o) return unmeasured(o.add{type = "label", caption = "–"}) end

-- The Screening grid's effect columns (0.59): yield; with Precision instruments 1 the other effects
-- (freshness only on targets that spoil); before it, one grey column.
local function shown_effects(force, target_key)
  local measured = shared.stage_ok(force, shared.side_effects_tech)
  local shown = {"yield"}
  if measured then
    for _, e in ipairs(gui.effects) do
      if e ~= "yield" and (e ~= "freshness" or truth.spoilable(target_key)) then table.insert(shown, e) end
    end
  end
  return shown, measured
end



-- Column headers that explain themselves on hover.
local HEADER_TIPS = {}
for _, key in ipairs({"col-n", "col-ci", "col-data", "col-rate", "col-best-dose", "col-family", "col-quality", "col-freshness",
                       "col-pollution"}) do
  HEADER_TIPS[key] = {"es." .. key .. "-tooltip"}
  if key == "col-freshness" then HEADER_TIPS[key] = {"es.col-freshness-tooltip", tostring(math.floor(shared.spoil_fail * 100))} end
end
-- The effect columns also say how to read their figures (one form for certainty, 0.67).
for _, key in ipairs({"col-yield", "col-speed", "col-efficiency", "col-pollution", "col-freshness", "col-bound"}) do
  HEADER_TIPS[key] = HEADER_TIPS[key] and {"", HEADER_TIPS[key], "\n\n", {"es.col-bound-tooltip"}} or {"es.col-bound-tooltip"}
end

-- The Theory tab: the family model fitted to the pool's evidence, and the untested pairs it predicts best.
local function pct1(x) return string.format("%+.1f%%", x / 10) end

-- Shapes by family and process class (0.59): for each family and class,
-- the family's most-sampled additive-target cell on a target of that class (its main class), fitted by
-- the automatic model; shown when the fit passes lack of fit. A measurement, never the world's law.
local function main_class(process)
  local best, bw = shared.process_classes[1], -1
  for _, c in ipairs(shared.process_classes) do
    if (process and process[c] or 0) > bw then best, bw = c, process and process[c] or 0 end
  end
  return best
end
function gui.family_shapes(pool)
  local best = {}  -- family -> class -> {n, additive, target}
  for _, t in ipairs(shared.targets) do
    local c = main_class(t.process)
    for _, a in ipairs(theory.raw_additives()) do
      local f = shared.mix_family(a.name)
      local pts = gui.points(pool, t.key, a.name)
      local n = 0
      for _, p in ipairs(pts) do n = n + p.n end
      best[f] = best[f] or {}
      if #pts >= 5 and (not best[f][c] or n > best[f][c].n) then best[f][c] = {n = n, additive = a, target = t.key, pts = pts} end
    end
  end
  local out = {}
  for f, by in pairs(best) do
    out[f] = {}
    for c, cell in pairs(by) do
      local fit = regress.auto(cell.pts, cell.additive.max_dose)
      if fit and fit.lof_p and fit.lof_p >= shared.fit_lof_p then out[f][c] = {model = fit.model, n = cell.n} end
    end
  end
  return out
end
-- Dossiers tab: each reached planet's quota and its targets, the exceptional set, and what finishes it.
local PLANET_ORDER = {"nauvis", "vulcanus", "fulgora", "gleba", "aquilo", "space"}
local function planet_caption(name)
  if name == "space" then return {"es.dossier-space"} end
  return {"", "[planet=" .. name .. "] ", {"space-location-name." .. name}}
end
local function pct_frac(x) return string.format("%+.1f%%", x * 100) end
-- The Progress tab (0.72): which graph, over which stretch of game time.
gui.PROGRESS_GRAPHS = {"samples", "packs", "efficiency", "settled", "findings", "dosed", "extra"}
gui.PROGRESS_RANGES = {{"hour", 216000}, {"ten-hours", 2160000}, {"all", nil}}
-- Colours for the samples graph, one per science pack (named for the pack each encodes; vanilla's tints).
local pack_colour = {
  ["automation-science-pack"] = {r = 0.85, g = 0.2, b = 0.2}, ["logistic-science-pack"] = {r = 0.3, g = 0.8, b = 0.3},
  ["chemical-science-pack"] = {r = 0.25, g = 0.6, b = 0.95}, ["production-science-pack"] = {r = 0.65, g = 0.35, b = 0.85},
  ["utility-science-pack"] = {r = 0.95, g = 0.85, b = 0.25}, ["space-science-pack"] = {r = 0.9, g = 0.9, b = 0.9},
  ["metallurgic-science-pack"] = {r = 0.95, g = 0.55, b = 0.2}, ["electromagnetic-science-pack"] = {r = 0.9, g = 0.3, b = 0.7},
  ["agricultural-science-pack"] = {r = 0.7, g = 0.85, b = 0.2}, ["cryogenic-science-pack"] = {r = 0.4, g = 0.75, b = 0.95},
  ["promethium-science-pack"] = {r = 0.35, g = 0.3, b = 0.55},
}
local line_colour = {r = 0.0, g = 0.447, b = 0.698}  -- the one series of the other graphs (Okabe-Ito blue)
function gui.fill_progress(page, player)
  storage.gui_progress = storage.gui_progress or {}
  local st = storage.gui_progress[player.index] or {graph = 1, range = #gui.PROGRESS_RANGES, marks = true}
  storage.gui_progress[player.index] = st
  page.head.graph.selected_index, page.head.range.selected_index, page.head.marks.state = st.graph, st.range, st.marks
  local force = player.force
  local P = storage.progress and storage.progress[force.index] or {t = {}, tiers = {}, data = {}, settled = {}, findings = {}}
  -- The record, then now as its last point.
  local now = gui.progress_now(force)
  local ticks = {}
  for i, t in ipairs(P.t) do ticks[i] = t end
  table.insert(ticks, game.tick)
  local last = #ticks
  local function at(list, i, current) if i == last then return current end return list and list[i] or 0 end
  local graph = gui.PROGRESS_GRAPHS[st.graph]
  local series, legend = {}, {""}
  if graph == "samples" then
    local packs = {}
    for pack in pairs(P.tiers) do packs[pack] = true end
    for pack in pairs(now.tiers) do packs[pack] = true end
    local order = {}
    for pack in pairs(packs) do if prototypes.item[pack] then table.insert(order, pack) end end
    table.sort(order, function(a, b) return prototypes.item[a].order < prototypes.item[b].order end)
    for _, pack in ipairs(order) do
      local pts = {}
      for i = 1, last do pts[i] = {ticks[i], at(P.tiers[pack], i, now.tiers[pack] or 0) or 0} end
      local c = pack_colour[pack] or line_colour
      table.insert(series, {colour = c, points = pts})
      table.insert(legend, string.format("[color=%.2f,%.2f,%.2f]■[/color][item=%s] ", c.r, c.g, c.b, pack))
    end
  elseif graph == "efficiency" then
    -- Packs earned per 100 samples, interval by interval.
    local function total(i)
      local n = 0
      for pack in pairs(P.tiers) do n = n + (at(P.tiers[pack], i, now.tiers[pack] or 0) or 0) end
      if i == last then n = 0; for _, c in pairs(now.tiers) do n = n + c end end
      return n
    end
    local pts = {}
    for i = 2, last do
      local ds = total(i) - total(i - 1)
      local dd = at(P.data, i, now.data) - at(P.data, i - 1, now.data)
      if ds > 0 then table.insert(pts, {ticks[i], shared.progress_per * dd / ds}) end
    end
    table.insert(series, {colour = line_colour, points = pts})
  else
    local key = graph == "packs" and "data" or graph  -- (dosed, extra: products made with a dose, extra products)
    local pts = {}
    for i = 1, last do pts[i] = {ticks[i], at(P[key], i, now[key]) or 0} end
    table.insert(series, {colour = line_colour, points = pts})
  end
  local marks = {}
  if st.marks then for _, t in pairs(storage.dossier_done_at and storage.dossier_done_at[force.index] or {}) do table.insert(marks, t) end end
  local span = gui.PROGRESS_RANGES[st.range][2]
  chart.draw_series(player.index, {series = series, stacked = graph == "samples", marks = marks,
    from = span and math.max(0, game.tick - span) or 0, to = game.tick,
    y_title = {"es.progress-y-" .. graph, tostring(shared.progress_per)}})
  page.legend.caption = #legend > 1 and legend or ""
  page.legend.visible = #legend > 1
end

-- Game time as hours and minutes (0.72: when a finding completed).
function gui.game_time(tick)
  local minutes = math.floor(tick / 3600)
  return {"es.time-hm", tostring(math.floor(minutes / 60)), string.format("%02d", minutes % 60)}
end
local ROW_FORCE  -- (the force whose findings are being drawn: fill_dossiers sets it)
local function dossier_row(tbl, first, b, dose_only)
  local e = b.entry
  tbl.add{type = "label", caption = first}
  if not e then
    tbl.add{type = "label", caption = {"es.dossier-none"}}
    tbl.add{type = "label", caption = ""}
    tbl.add{type = "label", caption = ""}
    tbl.add{type = "label", caption = ""}
    return
  end
  -- (In the major table the effect already leads the row: the dose alone.)
  tbl.add{type = "label", caption = dose_only and gui.mix_caption(gui.parse_key(e.key) or {})
    or {"", {"es.effect-" .. (e.readout == "cleanliness" and "pollution" or e.readout)}, " ", gui.mix_caption(gui.parse_key(e.key) or {})}}
  tbl.add{type = "label", caption = {"es.dossier-of", pct_frac(e.lb), pct_frac(e.threshold)},
    tooltip = {"es.dossier-lb-tooltip"}}
  tbl.add{type = "label", caption = {"es.dossier-of", tostring(math.floor(e.made)), tostring(e.volume)},
    tooltip = {"es.dossier-made-tooltip"}}
  local at = b.state == "done" and storage.dossier_done_at and ROW_FORCE and storage.dossier_done_at[ROW_FORCE]
  at = at and at[dose_only and ("x|" .. e.readout) or ("t|" .. e.target)]
  tbl.add{type = "label", caption = b.state ~= "done" and "" or at and {"", "[img=utility/check_mark_green] ", gui.game_time(at)}
    or "[img=utility/check_mark_green]", tooltip = at and {"es.dossier-done-at", gui.game_time(at)} or nil}
end
local function dossier_table(parent, name, first_header)
  local t = parent.add{type = "table", name = name, column_count = 5, draw_horizontal_line_after_headers = true}
  t.style.horizontal_spacing = 16
  for _, h in ipairs({first_header, "dossier-col-effect", "dossier-col-lb", "dossier-col-made", "dossier-col-done"}) do
    t.add{type = "label", caption = {"es." .. h}, style = "caption_label"}
  end
  return t
end
local function fill_report(flow, force)
  local finished = storage.dossier_finished and storage.dossier_finished[force.index]
  flow.visible = finished ~= nil
  flow.clear()
  if not finished or not dossiers.report_fn then return end
  local rep = dossiers.report_fn(force)
  flow.add{type = "label", caption = {"es.report-title"}, style = "caption_label"}
  local intro = flow.add{type = "label", caption = {"es.report-intro"}}
  intro.style.single_line = false
  intro.style.maximal_width = 640
  for _, name in ipairs(PLANET_ORDER) do
    for _, p in ipairs(rep.planets) do
      if p.planet == name then
        flow.add{type = "label", caption = p.more > 0 and {"es.report-planet", planet_caption(name), tostring(p.done), tostring(p.more)}
          or {"es.report-planet-clear", planet_caption(name), tostring(p.done)}}
      end
    end
  end
  local m = rep.majors
  flow.add{type = "label", caption = m.more > 0 and {"es.report-majors", tostring(m.done), tostring(m.needed), tostring(m.more)}
    or {"es.report-majors-clear", tostring(m.done), tostring(m.needed)}}
  if #rep.truth > 0 then
    flow.add{type = "label", caption = {"es.report-truth-head"}, style = "caption_label"}.style.top_margin = 6
    local t = flow.add{type = "table", column_count = 4, draw_horizontal_line_after_headers = true}
    t.style.horizontal_spacing = 16
    for _, h in ipairs({"dossier-col-target", "dossier-col-effect", "report-col-bound", "report-col-true"}) do
      t.add{type = "label", caption = {"es." .. h}, style = "caption_label"}
    end
    for _, row in ipairs(rep.truth) do
      t.add{type = "label", caption = shared.target_caption(shared.target(row.target))}
      t.add{type = "label", caption = {"", {"es.effect-" .. (row.readout == "cleanliness" and "pollution" or row.readout)}, " ",
        gui.mix_caption(gui.parse_key(row.key) or {})}}
      t.add{type = "label", caption = pct_frac(row.lb)}
      local tv = t.add{type = "label", caption = pct_frac(row.v), tooltip = row.v < row.lb and {"es.report-fluke", tostring(math.floor(1 / shared.bound_miss + 0.5))} or nil}
      if row.v < row.lb then tv.style.font_color = UNCLEAR end
    end
  end
  flow.add{type = "label", caption = {"es.report-look-head"}, style = "caption_label"}.style.top_margin = 6
  if #rep.look == 0 then flow.add{type = "label", caption = {"es.report-look-none"}} end
  for _, l in ipairs(rep.look) do
    local mix = gui.parse_key(l.key) or {}
    local icons = {""}
    for name in pairs(mix) do
      local a = shared.additive(name)
      table.insert(icons, ((a and a.fluid) and "[fluid=" or "[item=") .. name .. "]")
    end
    flow.add{type = "label", caption = {"es.report-look-row", icons, shared.target_caption(shared.target(l.target)), tostring(l.n)}}
  end
  flow.style.bottom_margin = 10
end

function gui.fill_dossiers(page, force)
  ROW_FORCE = force.index
  fill_report(page.report, force)
  local r = dossiers.state(force)
  local body = page.scroll.body
  body.clear()
  page.intro.caption = {"es.dossier-intro", tostring(r.exc_needed), tostring(#dossiers.EXCEPTIONAL)}
  page.status.caption = r.finished and {"es.dossier-finished"} or {"es.dossier-progress"}
  -- Each planet's finding bars on one line under its name (0.70: bars per planet; major bars show in their
  -- own rows below).
  local th = dossiers.thresholds()
  local function bars_of(planet)
    local std, bars = dossiers.standard_of(th, planet), {""}
    for i, readout in ipairs(dossiers.STANDARD) do
      table.insert(bars, {"", i > 1 and ", " or "", {"es.effect-" .. (readout == "cleanliness" and "pollution" or readout)},
        " ", pct_frac(std[readout])})
    end
    return {"es.dossier-bars", bars}
  end
  page.bars.visible = false
  local unreached = {""}
  for _, name in ipairs(PLANET_ORDER) do
    local p = r.planets[name]
    if p and p.reached then
      body.add{type = "label", caption = {"es.dossier-planet", planet_caption(name), tostring(p.done), tostring(p.quota)},
        style = "caption_label"}.style.top_margin = 8
      body.add{type = "label", caption = bars_of(name)}
      local t = dossier_table(body, "planet_" .. name, "dossier-col-target")
      for _, b in ipairs(p.targets) do dossier_row(t, shared.target_caption(b.target), b) end
    elseif p then
      table.insert(unreached, #unreached > 1 and ", " or "")
      table.insert(unreached, planet_caption(name))
    end
  end
  if #unreached > 1 then body.add{type = "label", caption = {"es.dossier-unreached", unreached}} end
  body.add{type = "label", caption = {"es.dossier-exceptional", tostring(r.exc_done), tostring(r.exc_needed)},
    style = "caption_label"}.style.top_margin = 8
  local t = dossier_table(body, "exceptional", "dossier-col-readout")
  for _, readout in ipairs(dossiers.EXCEPTIONAL) do
    local b = r.exceptional[readout]
    local first = {"es.effect-" .. (readout == "cleanliness" and "pollution" or readout)}
    if b.entry then first = {"", first, " ", shared.target_caption(shared.target(b.entry.target))} end
    dossier_row(t, first, b, true)
  end
end

-- The summary shown once, when a force completes its dossiers.
function gui.open_dossier_summary(player, r)
  local old = player.gui.screen.es_dossier_summary
  if old then old.destroy() end
  local f = player.gui.screen.add{type = "frame", name = "es_dossier_summary", caption = {"es.dossier-summary-title"},
    direction = "vertical"}
  f.auto_center = true
  local inner = f.add{type = "frame", style = "inside_shallow_frame_with_padding", direction = "vertical"}
  local intro = inner.add{type = "label", caption = {"es.dossier-summary"}}
  intro.style.single_line = false
  intro.style.maximal_width = 520
  local n = 0
  for _, p in pairs(r.planets) do n = n + p.done end
  inner.add{type = "label", caption = {"es.dossier-summary-count", tostring(n), tostring(r.exc_done)}}
  inner.add{type = "label", caption = {"es.dossier-summary-report"}}
  for _, readout in ipairs(dossiers.EXCEPTIONAL) do
    local b = r.exceptional[readout]
    if b.state == "done" then
      inner.add{type = "label", caption = {"", "[img=utility/check_mark_green] ",
        {"es.effect-" .. (readout == "cleanliness" and "pollution" or readout)}, ": ",
        shared.target_caption(shared.target(b.entry.target)), " ", gui.mix_caption(gui.parse_key(b.entry.key) or {}),
        " ", pct_frac(b.entry.lb)}}
    end
  end
  local foot = f.add{type = "flow", direction = "horizontal"}
  foot.add{type = "empty-widget"}.style.horizontally_stretchable = true
  foot.add{type = "button", name = "es_dossier_summary_close", caption = {"gui.close"}, style = "dialog_button"}
  player.opened = f
end

-- Coverage (0.70, user: where the evidence is, without trying every target): per target on the screen's
-- planet, samples, the single additives tested of those on offer, how many have settled either way, and a
-- strip of the families tried. Counts, no bars: most pairs do nothing, and choosing what to test is the game.
local COVERAGE_PLANETS = {"nauvis", "vulcanus", "fulgora", "gleba", "aquilo", "space"}
function gui.fill_coverage(page, pool, player)
  local force, skey = player.force, gui.view_surface(player)
  local body = page.scroll.body
  body.clear()
  local offer, fams, seen = {}, {}, {}
  for _, a in ipairs(gui.visible_additives(force)) do
    if not a.agent then
      offer[a.name] = true
      local f = a.premix_of and a.phase or shared.mix_family(a.name) or a.family
      if f and not seen[f] then seen[f] = true; table.insert(fams, f) end
    end
  end
  local n_offer = 0
  for _ in pairs(offer) do n_offer = n_offer + 1 end
  local th = dossiers.thresholds()
  local by_planet, tot = {}, {samples = 0, targets = 0, tested = 0, pays = 0}
  for _, t in ipairs(gui.targets_for(pool, force, nil, false)) do
    local obs = pool.obs[t.key]
    local tested, fam_tried, pays, loses, settled = {}, {}, 0, 0, false
    for key, acc in pairs(obs or {}) do
      local name = key:match("^([^+:@]+):%d+")
      if name and offer[name] and acc.n > 0 and not tested[name] then
        tested[name] = true
        local a = shared.additive(name)
        fam_tried[a.premix_of and a.phase or shared.mix_family(name) or a.family] = true
        local row = research.row(force.index, obs, t.key, name, skey)
        if row and row.state == "settled" then settled = true end
        if row and row.state == "settled" and row.net and row.half then
          if row.net - row.half > 0 then pays = pays + 1 elseif row.net + row.half < 0 then loses = loses + 1 end
        end
      end
    end
    local n_t = 0
    for _ in pairs(tested) do n_t = n_t + 1 end
    local planet = dossiers.planet_of(th, t.key)
    by_planet[planet] = by_planet[planet] or {}
    -- (0.72, the variety rules) What a settled question pays here, once one is settled: a measurement, never shown
    -- before (finding which products pay best when settled, and why, is the player's).
    table.insert(by_planet[planet], {t = t, n = gui.samples_on(pool, t.key), tested = n_t, pays = pays, loses = loses,
      fams = fam_tried, settled = settled and research.floor_of(t.key) or nil})
    tot.samples, tot.tested, tot.pays = tot.samples + gui.samples_on(pool, t.key), tot.tested + n_t, tot.pays + pays
    if gui.samples_on(pool, t.key) > 0 then tot.targets = tot.targets + 1 end
  end
  page.summary.caption = {"es.cov-summary", tostring(tot.samples), tostring(tot.targets), tostring(tot.tested),
    tostring(tot.pays)}
  local tbl = body.add{type = "table", name = "coverage", column_count = 7, draw_horizontal_line_after_headers = true}
  tbl.style.horizontal_spacing = 16
  for _, h in ipairs({"cov-target", "col-n", "cov-tested", "verdict-pays", "verdict-loses", "cov-settled", "cov-families"}) do
    tbl.add{type = "label", caption = {"es." .. h}, style = "caption_label",
      tooltip = (h == "cov-families" or h == "cov-settled") and {"es." .. h .. "-tooltip"} or nil}
  end
  for _, planet in ipairs(COVERAGE_PLANETS) do
    for i, r in ipairs(by_planet[planet] or {}) do
      if i == 1 then
        local head = tbl.add{type = "label", style = "caption_label",
          caption = planet == "space" and {"es.dossier-space"} or {"", "[planet=" .. planet .. "] ", {"space-location-name." .. planet}}}
        head.style.top_margin = 6
        for _ = 2, 7 do tbl.add{type = "empty-widget"} end
      end
      local quiet = r.n == 0
      local cells = {shared.target_caption(r.t), tostring(r.n), {"es.cov-of", tostring(r.tested), tostring(n_offer)},
        tostring(r.pays), tostring(r.loses), r.settled and string.format("%.2f", r.settled) or "–"}
      for _, c in ipairs(cells) do
        local l = tbl.add{type = "label", caption = c}
        if quiet then l.style.font_color = {r = 0.55, g = 0.55, b = 0.55} end
      end
      local strip = tbl.add{type = "flow", direction = "horizontal"}
      strip.style.horizontal_spacing = 1
      for _, f in ipairs(fams) do
        local l = strip.add{type = "label", caption = r.fams[f] and "■" or "□", tooltip = {"es.family-" .. f}}
        l.style.font_color = r.fams[f] and {r = 0.55, g = 0.85, b = 1} or {r = 0.45, g = 0.45, b = 0.45}
      end
    end
  end
end

-- The Theory tab reads one effect at a time (0.70: side effects lean by process class too).
gui.theory_effects = {"yield", "speed", "pollution", "efficiency"}
function gui.theory_effect(player)
  return storage.gui_theory_effect and storage.gui_theory_effect[player.index] or "yield"
end
-- (0.72) The fit kept per evidence table and effect until evidence changes (stats.add bumps the version):
-- refitted on every refresh, it cost most of a second on a large save. Runtime only.
local THEORY = setmetatable({}, {__mode = "k"})
local function theory_of(book)
  local v = storage.evidence_version or 0
  local c = THEORY[book]
  if c and c.v == v then return c.cells, c.fit end
  local cells = theory.cells(book)
  local targets, n_targets = {}, 0
  for _, cell in ipairs(cells) do if not targets[cell.target] then targets[cell.target] = true; n_targets = n_targets + 1 end end
  local fit = n_targets >= 2 and theory.fit(cells) or nil
  THEORY[book] = {v = v, cells = cells, fit = fit}
  return cells, fit
end
local THEORY_MAX_WIDTH = 1000  -- per mille: a range of ±50%
function gui.fill_theory(page, pool, effect)
  effect = effect or "yield"
  for i, e in ipairs(gui.theory_effects) do if e == effect then page.head.effect.selected_index = i end end
  local cells, cached_fit = theory_of(effect == "yield" and (pool.obs or {}) or ((pool.side or {})[effect] or {}))
  local targets = {}
  for _, c in ipairs(cells) do targets[c.target] = true end
  local n_targets = 0
  for _ in pairs(targets) do n_targets = n_targets + 1 end
  local fams, nxt = page.families, page.next_scroll.next
  fams.clear(); nxt.clear()
  local fit = cached_fit
  if not fit then page.fit.caption = {"es.theory-none"}; return end
  page.fit.caption = {"es.theory-fit", tostring(#cells), tostring(n_targets), string.format("%.1f%%", math.sqrt(fit.tau2) / 10)}  -- (unsigned: "±+0.0%" before 0.70)
  for _, h in ipairs({"theory-col-family", "theory-col-metalwork", "theory-col-chemistry", "theory-col-electronics",
                      "theory-col-cells"}) do
    fams.add{type = "label", caption = {"es." .. h}, style = "caption_label"}
  end
  for _, c in ipairs(shared.process_classes) do
    fams.add{type = "label", caption = {"es.theory-col-shape", {"es.theory-col-" .. c}}, style = "caption_label",
      tooltip = {"es.theory-col-shape-tooltip"}}
  end
  local shapes = gui.family_shapes(pool)
  local names = {}
  for f in pairs(fit.families) do table.insert(names, f) end
  table.sort(names)
  for _, f in ipairs(names) do
    local fam = fit.families[f]
    fams.add{type = "label", caption = {"es.family-" .. f}}
    for c = 1, #shared.process_classes do
      local wide = fam.hi[c] - fam.lo[c] > THEORY_MAX_WIDTH  -- (no evidence in that class: the prior, "–")
      fams.add{type = "label", caption = wide and "–" or {"es.theory-cell", pct1(fam.est[c]), pct1(fam.lo[c]), pct1(fam.hi[c])}}
    end
    fams.add{type = "label", caption = tostring(fam.cells or 0)}
    for _, c in ipairs(shared.process_classes) do
      local sh = shapes[f] and shapes[f][c]
      fams.add{type = "label", caption = sh and {"es.theory-shape", {"es.model-" .. sh.model}, tostring(sh.n)} or "–"}
    end
  end
  for _, h in ipairs({"theory-col-additive", "theory-col-target", "theory-col-predicted"}) do
    nxt.add{type = "label", caption = {"es." .. h}, style = "caption_label"}
  end
  -- (0.72) A prediction whose 95% range is wider than ±50% ranks nothing (a family with no results in that
  -- class reads as the prior, ±190%): left out, and a list with none left says so.
  local shown = 0
  for _, u in ipairs(theory.untested(fit, cells)) do
    if shown >= 15 then break end
    if u.hi - u.lo <= THEORY_MAX_WIDTH then
      shown = shown + 1
      nxt.add{type = "label", caption = gui.item_caption(u.additive)}
      nxt.add{type = "label", caption = shared.target_caption(shared.target(u.target))}
      nxt.add{type = "label", caption = {"es.theory-cell", pct1(u.gain), pct1(u.lo), pct1(u.hi)}}
    end
  end
  if shown == 0 then nxt.clear(); nxt.add{type = "label", caption = {"es.theory-next-none"}} end
end

-- The Screening grid's table (inside its scroll pane since 0.62).
function gui.overview(panel) return panel.pages.screening.grid_scroll.overview end

-- Sorting and showing the grid's rows (0.62).
gui.SCREEN_SORTS = {"list", "family", "samples", "yield", "data"}
function gui.screen_rows(player, visible, sums_by, force_index, obs, target_key, skey)
  storage.gui_screen = storage.gui_screen or {}
  local st = storage.gui_screen[player.index] or {sort = 1, show = 1}
  -- Show: 1 all, 2 tested, 3 untested, then one entry per family among the visible additives.
  local families = {}
  local seen = {}
  for _, a in ipairs(visible) do
    local f = a.premix_of and a.phase or a.family
    if not seen[f] then seen[f] = true; table.insert(families, f) end
  end
  table.sort(families)
  local function n_of(a) return sums_by.yield.additives[a.name] and sums_by.yield.additives[a.name].n or 0 end
  local out = {}
  for _, a in ipairs(visible) do
    local f = a.premix_of and a.phase or a.family
    local keep = st.show == 1 or (st.show == 2 and n_of(a) > 0) or (st.show == 3 and n_of(a) == 0)
      or (st.show > 3 and families[st.show - 3] == f)
    if keep then table.insert(out, a) end
  end
  local key = gui.SCREEN_SORTS[st.sort] or "list"
  if key ~= "list" then
    local val = {}
    for i, a in ipairs(out) do
      local row = sums_by.yield.additives[a.name]
      local v
      if key == "family" then v = (a.premix_of and a.phase or a.family) .. string.format("%05d", i)
      elseif key == "samples" then v = -n_of(a)
      elseif key == "yield" then v = row and row.best and -row.doses[row.best].mean or math.huge
      else
        local r = obs and research.row(force_index, obs, target_key, a.name, skey)
        v = r and -r.rate or 0
      end
      val[a.name] = {v, i}
    end
    table.sort(out, function(x, y)
      local a, b = val[x.name], val[y.name]
      if a[1] == b[1] then return a[2] < b[2] end
      return a[1] < b[1]
    end)
  end
  return out, families, st
end

-- Screening grid: one row per additive, the best-dose gain for each effect.
local function fill_overview(o, sums_by, visible, force_index, obs, target_key, skey, qual)
  -- Staged reveal: speed, cleanliness, efficiency and freshness are measured from Precision instruments
  -- 1; before, one grey column says so (0.59: four grey columns crowded the first screen). Freshness shows
  -- only on targets that spoil (elsewhere it is zero by rule).
  local shown, measured = shown_effects(game.forces[force_index], target_key)
  local cols = {"col-additive", "col-family", "col-n", "col-best-dose"}  -- (0.68: one dose column, not "@4" per cell)
  for _, e in ipairs(shown) do table.insert(cols, "col-" .. e) end
  if not measured then table.insert(cols, "col-side-effects") end
  table.insert(cols, "col-data")
  table.insert(cols, "col-rate")
  if shared.quality_on then table.insert(cols, "col-quality") end
  -- A table's column count is fixed at creation: rebuilt in place when the columns change.
  if o.column_count ~= #cols then
    local parent, index = o.parent, o.get_index_in_parent()
    o.destroy()
    o = parent.add{type = "table", name = "overview", column_count = #cols, draw_horizontal_line_after_headers = true,
      index = index}
    o.style.horizontal_spacing = 12
  else
    o.clear()
  end
  for _, key in ipairs(cols) do
    local l = o.add{type = "label", caption = {"es." .. key}, style = "caption_label", tooltip = HEADER_TIPS[key]}
    if key == "col-side-effects" then unmeasured(l) end
  end
  local ctrl = sums_by.yield.control
  o.add{type = "label", caption = {"es.control"}}
  o.add{type = "label", caption = ""}
  o.add{type = "label", caption = tostring(ctrl and ctrl.n or 0)}
  o.add{type = "label", caption = ""}
  for _, effect in ipairs(shown) do
    local c = sums_by[effect].control
    o.add{type = "label", caption = c and pct(c.mean) or "–", tooltip = {"es.control-row-tooltip"}}
  end
  if not measured then unmeasured_cell(o) end
  -- The control row: controls to add for a balanced design, the research data a control would earn on hover.
  local need = obs and research.controls_needed(obs, target_key)
  o.add{type = "label", caption = need == nil and "?" or (need == 0 and {"es.control-enough"} or {"es.control-more", about(need)}),
    tooltip = {"es.control-tooltip"}}
  rate_cell(o, research.rate(force_index, obs or {}, target_key, "control", skey, nil, true))
  if shared.quality_on then o.add{type = "label", caption = "–", tooltip = {"es.quality-not-agent"}} end
  for _, a in ipairs(visible) do
    o.add{type = "label", caption = item_caption(a.name)}
    o.add{type = "label", caption = {"es.family-" .. (a.premix_of and a.phase or a.family)}}
    o.add{type = "label", caption = tostring(sums_by.yield.additives[a.name].n)}
    -- Speed and cleanliness at the dose that gives the best yield: the trade-off being weighed (their
    -- own best dose is in the tooltip).
    local ybest = sums_by.yield.additives[a.name].best
    local yband = sums_by.yield.additives[a.name].band  -- a liquid premix: the best yield's band
    o.add{type = "label", caption = ybest and tostring(ybest) or "–"}
    for _, effect in ipairs(shown) do
      local row = effect ~= "yield" and yband and sums_by[effect].bands[a.name] and sums_by[effect].bands[a.name][yband]
        or sums_by[effect].additives[a.name]
      local d = effect == "yield" and row.best or ybest
      effect_cell(o, d and row.doses[d], nil, sums_by[effect].control, effect ~= "yield" and row.best)
    end
    if not measured then unmeasured_cell(o) end
    local row = obs and research.row(force_index, obs, target_key, a.name, skey, qual,
      ybest and ((yband and yband ~= usual_band(a.name)) and (a.name .. suffix_of(band_kind(a.name)) .. yband) or a.name) .. ":" .. ybest)
    data_cell(o, row)
    rate_cell(o, row and row.rate)
    if shared.quality_on then quality_cell(o, qual, a.name) end
  end
end

-- An agent's upgrade rate at one dose (Dose-response, with the quality mod): counts until enough units
-- are rolled, then the rate and its 95% range. Not an agent, or no data: "–". No curve is fitted.
local function quality_dose_cell(t, q)
  if not q or q.b <= 0 then t.add{type = "label", caption = "–"}; return end
  if q.b < shared.quality_min_units then
    t.add{type = "label", caption = {"es.quality-count-short", q.k, q.b}}
    return
  end
  local p, lo, hi = stats.wilson(q.k, q.b)
  local function rate(x) return string.format("%.1f%%", x * 100) end
  t.add{type = "label", caption = {"es.quality-rate", rate(p), rate(lo), rate(hi)}}
end

-- The Dose-response table's columns, read by its builder too (0.70: 0.67 dropped a column from the rows and
-- not from the table, and every row slid by one cell).
function gui.detail_columns()
  local cols = {"col-dose", "col-n", "col-gain", "col-ci", "col-bound"}
  if shared.quality_on then table.insert(cols, "col-quality-dose") end
  return cols
end
local function fill_detail(t, sums, additive, obs, qual)
  t.clear()
  -- The quality column (with the quality mod) is blank unless the additive is an agent.
  local agent = shared.is_agent(additive)
  local cols = gui.detail_columns()
  for _, key in ipairs(cols) do
    t.add{type = "label", caption = (key ~= "col-quality-dose" or agent) and {"es." .. key} or "", style = "caption_label",
      tooltip = HEADER_TIPS[key]}
  end
  t.add{type = "label", caption = {"es.control"}}
  t.add{type = "label", caption = tostring(sums.control and sums.control.n or 0)}
  t.add{type = "label", caption = gain_caption(sums.control)}
  ci_bar(t, sums.control)
  t.add{type = "label", caption = ""}
  if shared.quality_on then t.add{type = "label", caption = ""} end
  for _, d in ipairs(listed_doses(obs, additive)) do
    local s = sums.additives[additive].doses[d]
    t.add{type = "label", caption = tostring(d)}
    t.add{type = "label", caption = tostring(s and s.n or 0)}
    t.add{type = "label", caption = gain_caption(s)}
    ci_bar(t, s)
    if s then bound_label(t, s, sums.control) else t.add{type = "label", caption = "–"} end
    if shared.quality_on then
      if agent then quality_dose_cell(t, qual and qual[additive .. ":" .. d]) else t.add{type = "label", caption = ""} end
    end
  end
end

-- Fit the chosen model, describe the fit, and draw the chart.
local function fill_fit(panel, station, player, target_key, sums, additive)
  local choice = selected_model(player)
  local max_dose = shared.additive(shared.split_band(additive)).max_dose
  local points = gui.points(station, target_key, additive, gui.effect(player), gui.priced(player))
  local fit, why
  if choice == "auto" then fit, why = regress.auto(points, max_dose) else fit, why = regress.fit(points, choice, max_dose) end
  local model = fit and fit.model or (choice == "auto" and "linear" or choice)
  local fitbox = panel.pages.dose.fit
  if not fit then
    fitbox.line1.caption = {"es.fit-" .. why, regress.params[model]}
    fitbox.line2.caption = ""
  else
    local lof = fit.lof_p and {"es.fit-lof",  -- one word (good, fair, poor); p on hover
      {fit.lof_p < shared.fit_lof_p and "es.fit-poor" or fit.lof_p < 0.2 and "es.fit-fair" or "es.fit-ok"}}
      or (fit.lof_exact and {"es.fit-lof-exact"} or {"es.fit-lof-na"})
    local name = fit.auto and {"es.model-auto-chose", {"es.model-" .. model}} or {"es.model-" .. model}
    fitbox.line1.caption = {"", name, "   ", lof}
    fitbox.line1.tooltip = {"", {"es.fit-r2", string.format("%.2f", fit.r2 or 0)},
      fit.lof_p and {"", "\n", {"es.fit-lof-tooltip", string.format("%.3f", fit.lof_p), tostring(shared.fit_lof_p)}} or ""}
    if fit.optimum then
      local o = fit.optimum
      fitbox.line2.caption = {"es.fit-optimum", string.format("%.1f", o.dose),
        string.format("%.1f", o.lo), string.format("%.1f", o.hi), pct(o.gain)}
    elseif fit.cliff_at then
      fitbox.line2.caption = {"es.fit-cliff", string.format("%.1f", fit.best_dose), pct(fit.best_gain),
        string.format("%.1f", fit.cliff_at)}
    else
      fitbox.line2.caption = {"es.fit-best", string.format("%.1f", fit.best_dose), pct(fit.best_gain)}
    end
  end

  local points = {}
  local function add(dose, s, control)
    if s then table.insert(points, {dose = dose, mean = s.mean, lo = s.lo, hi = s.hi, control = control}) end
  end
  add(0, sums.control, true)
  for d, s in pairs(sums.additives[additive].doses) do add(d, s) end
  local effect = gui.effect(player)
  chart.draw(player.index, {points = points, curve = fit and fit.curve, max_dose = max_dose,
    y_title = effect ~= "yield" and "es.chart-y-" .. effect or nil,
    optimum = fit and (fit.optimum or {dose = fit.best_dose})})
  return fit
end

-- The temperature view (0.53): each band's mean at the additive's best dose, the bell fitted over them
-- (regress.fit_temperature) and its best temperature with a 95% interval. The fit lines say so.
function gui.fill_temperature(panel, player, sums, base)
  local best_row = sums.additives[base]
  local d = best_row and best_row.best
  local points = {}
  local ripe = band_kind(base) == "ripe"  -- (0.62: the same view over ripeness, in percent)
  local lo_t, hi_t = shared.premix.cold, shared.premix.hot  -- the axis: Nauvis's reach, widened to what was tested
  if ripe then lo_t, hi_t = 0, 100 end
  for _, b in ipairs(ripe and shared.ripe_bands() or shared.all_bands()) do
    local row = sums.bands[base] and sums.bands[base][b]
    local s = d and row and row.doses[d]
    if s and s.n >= 2 and s.half then
      local blo, bhi
      if ripe then blo, bhi = shared.ripe_range(b) else blo, bhi = shared.band_range(b) end
      local t = (blo + bhi) / 2
      lo_t, hi_t = math.min(lo_t, blo), math.max(hi_t, bhi)
      table.insert(points, {temp = t, dose = t, mean = s.mean, lo = s.lo, hi = s.hi, se = s.half / 1.96})
    end
  end
  local fit = regress.fit_temperature(points, lo_t, hi_t)
  local fitbox = panel.pages.dose.fit
  local key = ripe and "es.ripe" or "es.temp"
  fitbox.line1.caption = {key .. "-view", tostring(#points), tostring(d or "?")}
  fitbox.line2.caption = fit and {key .. "-best", string.format("%.0f", fit.temp), string.format("%.0f", fit.lo),
    string.format("%.0f", fit.hi), string.format("%+.1f%%", fit.gain / 10)} or {key .. "-need"}
  chart.draw(player.index, {points = points, curve = fit and fit.curve, min_dose = math.min(0, lo_t), max_dose = hi_t,
    x_title = ripe and "es.chart-x-ripeness" or "es.chart-x-temperature", no_control = true,
    optimum = fit and {dose = fit.temp, lo = fit.lo, hi = fit.hi}})
end

-- What can be adopted for an additive: every dose for a tier 1 item; otherwise the tested doses and,
-- when the chosen model has one, its fitted optimum (rounded): precision pays by adopting the fit.
local function adopt_options(obs, additive, fit)
  local a = shared.additive(shared.split_band(additive))
  local values, captions = {}, {}
  if a.tier == 1 then
    for d = 1, a.max_dose do table.insert(values, d); table.insert(captions, tostring(d)) end
    return values, captions
  end
  for _, d in ipairs(tested_doses(obs, additive)) do table.insert(values, d); table.insert(captions, tostring(d)) end
  local opt = fit and (fit.optimum and fit.optimum.dose or fit.best_dose)
  if opt and opt > 0 then
    local d = math.max(1, math.min(a.max_dose, math.floor(opt + 0.5)))
    table.insert(values, d)
    table.insert(captions, {"es.adopt-fitted", tostring(d)})
  end
  return values, captions
end

-- Parse a station key into {name = dose}: "control", "a:3", or "a:3+b:40".
local function parse_key(key)
  if key == "control" then return {} end
  local mix = {}
  for part in key:gmatch("[^+]+") do
    local name, dose = part:match("^(.+):(%d+)$")
    if not name then return nil end
    mix[shared.split_band(name)] = tonumber(dose)
  end
  return mix
end
gui.parse_key = parse_key

local function mix_caption(mix)
  local parts = {""}
  for name, dose in pairs(mix) do
    if dose > 0 then  -- a zero dose is no additive at all
      local fluid = shared.additive(name).fluid
      table.insert(parts, (fluid and "[fluid=" or "[item=") .. name .. "]×" .. dose .. " ")
    end
  end
  if #parts == 1 then return {"es.control"} end
  return parts
end
gui.mix_caption = mix_caption


local function mix_key(mix)
  local parts = {}
  for name, dose in pairs(mix) do table.insert(parts, name .. ":" .. dose) end
  table.sort(parts)
  return table.concat(parts, "+")
end

-- Presets tab: the force's saved compositions, how many samples of each exact composition the force has
-- analysed for the preset's target, and a delete button.
local function fill_presets(page, player)
  local t = page.list_scroll.list
  t.clear()
  for _, key in ipairs({"col-for", "col-composition", "col-tested", "col-action"}) do
    t.add{type = "label", caption = {"es." .. key}, style = "caption_label"}
  end
  local force = player.force
  local list = dosing.presets(force)
  for i, p in ipairs(list) do
    local obs = gui.pool(force, gui.view_surface(player)).obs[p.target]
    local acc = obs and obs[mix_key(p.mix)]
    local count = acc and acc.n or 0
    t.add{type = "label", caption = shared.target_caption(shared.target(p.target))}
    t.add{type = "label", caption = mix_caption(p.mix)}
    t.add{type = "label", caption = tostring(count), tooltip = {"es.tested-tooltip"}}
    t.add{type = "button", caption = {"es.preset-delete"}, style = "red_button", tags = {es_action = "preset-delete", index = i}}
  end
  page.empty.caption = #list == 0 and {"es.presets-empty"} or ""
end

local function selected_pair(player)
  local visible = gui.visible_additives(player.force)
  return visible[index_of(visible, stored_name(storage.gui_mix_a[player.index], "coal"))].name,
         visible[index_of(visible, stored_name(storage.gui_mix_b[player.index], "stone"))].name
end
gui.selected_pair = selected_pair

-- Mixtures by band (0.72, user: a heated member's results were plotted and fitted with its usual ones). A result
-- key's members as stored: raw name (with its band, "water@3"), base name, dose.
local function key_parts(key)
  local parts = {}
  for part in key:gmatch("[^+]+") do
    local raw, dose = part:match("^(.+):(%d+)$")
    if not raw then return nil end
    table.insert(parts, {raw = raw, base = (shared.split_band(raw)), dose = tonumber(dose)})
  end
  table.sort(parts, function(x, y) return x.raw < y.raw end)
  return parts
end
-- Whether a member's band can be chosen: living additives always, fluids once temperature is studied.
local function band_choice(force, name)
  local kind = band_kind(name)
  if kind == "ripe" or (kind == "temp" and shared.stage_ok(force, shared.stages.thermal.tech)) then return kind end
end
-- The band chosen for a mixture member (its usual band unless chosen), and its name as results store it.
local function mix_band(player, name)
  local t = storage.gui_mix_band and storage.gui_mix_band[player.index]
  return t and t[name] or usual_band(name)
end
local function banded_name(name, band)
  local kind = band_kind(name)
  if not kind or band == usual_band(name) then return name end
  return name .. suffix_of(kind) .. band
end
local function band_caption_of(kind, b)
  if kind == "ripe" then
    local lo, hi = shared.ripe_range(b)
    return {"es.ripe-band", string.format("%d", lo), string.format("%d", hi)}
  end
  return {"es.temp-band", shared.band_caption(b)}
end
-- A mixture's caption with each banded member's band (its usual band says nothing, as everywhere).
local function parts_caption(parts)
  local out = {""}
  for _, p in ipairs(parts) do
    if p.dose > 0 then
      local fluid = shared.additive(p.base).fluid
      table.insert(out, (fluid and "[fluid=" or "[item=") .. p.base .. "]×" .. p.dose .. " ")
      local _, b = shared.split_band(p.raw)
      if b then table.insert(out, {"", "(", band_caption_of(band_kind(p.base), b), ") "}) end
    end
  end
  return out
end

-- Mixtures tab: surface fit for the selected pair, every tested mixture with its interaction.
local function fill_mixtures(panel, station, player, target)
  local page = panel.pages.mixtures
  local effect = gui.effect(player)
  local obs = gui.obs_of(station, target.key, effect == "fullcost" and "yield" or effect)  -- mixtures: no full cost view
  local A, B = selected_pair(player)
  local ma, mb = shared.additive(A).max_dose, shared.additive(B).max_dose
  local head = page.head
  local function sync(el, index) if el.selected_index ~= index then el.selected_index = index end end
  local visible = gui.visible_additives(player.force)
  refresh_items(head.mix_a, visible)
  refresh_items(head.mix_b, visible)
  sync(head.mix_a, index_of(visible, A))
  sync(head.mix_b, index_of(visible, B))

  -- Each member's band (0.72): a fluid's temperature, a living additive's ripeness, as chosen (usual unless).
  local want = {[A] = banded_name(A, mix_band(player, A)), [B] = banded_name(B, mix_band(player, B))}
  for _, pair in ipairs({{A, head.band_a}, {B, head.band_b}}) do
    local name, dd = pair[1], pair[2]
    local kind = band_choice(player.force, name)
    dd.visible = kind ~= nil
    if kind then
      local items, sel = {}, 1
      for i, b in ipairs(bands_of(kind)) do
        items[i] = band_caption_of(kind, b)
        if b == mix_band(player, name) then sel = i end
      end
      if #dd.items ~= #items or (dd.tags.kind ~= kind) then dd.items = items; dd.tags = {es_action = dd.tags.es_action, kind = kind} end
      if dd.selected_index ~= sel then dd.selected_index = sel end
    end
  end

  -- Surface points: control, each additive alone, and mixtures of exactly these two, at the chosen bands.
  local points = {}
  for key, acc in pairs(obs) do
    local parts = key == "control" and {} or key_parts(key)
    if parts and acc.n > 0 and #parts <= 2 and A ~= B then
      local only_pair, at = true, {}
      for _, p in ipairs(parts) do
        if want[p.base] ~= p.raw then only_pair = false end
        at[p.base] = p.dose
      end
      if only_pair then
        local mean = acc.sum / acc.n
        table.insert(points, {a = at[A] or 0, b = at[B] or 0, n = acc.n, mean = mean,
          ss = acc.sumsq - acc.n * mean * mean})
      end
    end
  end
  local fit, why = nil, "need-points"
  if A ~= B then fit, why = regress.fit_surface(points) end
  local fitbox = page.fit
  if not fit then
    fitbox.line1.caption = A == B and {"es.mix-same"} or {"es.mix-fit-" .. why, regress.surface_params}
    fitbox.line2.caption = ""
  else
    local lof = fit.lof_p and {"es.fit-lof",  -- one word (good, fair, poor); p on hover
      {fit.lof_p < shared.fit_lof_p and "es.fit-poor" or fit.lof_p < 0.2 and "es.fit-fair" or "es.fit-ok"}} or (fit.lof_exact and {"es.fit-lof-exact"} or {"es.fit-lof-na"})
    fitbox.line1.caption = {"", {"es.mix-model"}, "   ", lof}
    fitbox.line1.tooltip = {"", {"es.fit-r2", string.format("%.2f", fit.r2 or 0)},
      fit.lof_p and {"", "\n", {"es.fit-lof-tooltip", string.format("%.3f", fit.lof_p), tostring(shared.fit_lof_p)}} or ""}
    local ba, bb = math.floor(fit.best.a + 0.5), math.floor(fit.best.b + 0.5)
    fitbox.line2.caption = {ba > 0 and bb > 0 and "es.mix-optimum" or "es.mix-optimum-single",
      mix_caption({[A] = ba, [B] = bb}), pct(fit.best.gain)}
  end
  local tested_a, tested_b = 0, 0
  local marks = {}
  for _, p in ipairs(points) do
    tested_a, tested_b = math.max(tested_a, p.a), math.max(tested_b, p.b)
    table.insert(marks, {a = p.a, b = p.b})
  end
  chart.draw_surface(player.index, {surface = fit and fit.surface, max_a = ma, max_b = mb,
    tested_a = tested_a, tested_b = tested_b, points = marks,
    best = fit and {a = fit.best.a, b = fit.best.b},
    title_a = {"es.mix-dose-of", item_caption(A)}, title_b = {"es.mix-dose-of", item_caption(B)}})

  -- Every tested mixture for this target.
  local t = page.tested_scroll.tested
  t.clear()
  for _, k in ipairs({"col-mixture", "col-n", "col-gain", "col-interaction", "col-result"}) do
    t.add{type = "label", caption = {"es." .. k}, style = "caption_label"}
  end
  local control = stats.summary(obs.control)
  local options, captions = {}, {}
  local keys = {}
  for key in pairs(obs) do if key:find("+", 1, true) then table.insert(keys, key) end end
  table.sort(keys)
  for _, key in ipairs(keys) do
    local mix = parse_key(key)
    local parts = key_parts(key)
    local s = stats.summary(obs[key])
    if mix and parts and s then
      local names = {}
      for name in pairs(mix) do table.insert(names, name) end
      local inter
      if #parts == 2 then
        -- (0.72) Against each member alone at its own band in this mixture: the two-by-two of this band.
        local none = {n = 0, sum = 0, sumsq = 0}
        inter = regress.interaction(s, stats.summary(obs[parts[1].raw .. ":" .. parts[1].dose] or none),
          stats.summary(obs[parts[2].raw .. ":" .. parts[2].dose] or none), control)
      end
      t.add{type = "label", caption = parts_caption(parts)}
      t.add{type = "label", caption = tostring(s.n)}
      t.add{type = "label", caption = gain_caption(s)}
      t.add{type = "label", caption = inter and (pct(inter.estimate) .. "  [" .. pct(inter.lo) .. ", " .. pct(inter.hi) .. "]")
        or (#names > 2 and {"es.mix-multi", #names} or "–")}
      -- The verdict by the interaction's bound, as every other result: proven synergy or antagonism, or unclear.
      local verdict, colour = "mix-unclear", UNCLEAR
      if inter and inter.lo and inter.lo > 0 then verdict, colour = "mix-synergy", effect_colour.gain
      elseif inter and inter.hi and inter.hi < 0 then verdict, colour = "mix-antagonism", effect_colour.loss end
      local tip = inter and inter.p and {"es.cell-detail", pct(inter.estimate), tostring(s.n), p_caption(inter.p)} or nil
      -- (0.72, user: a synergy at three samples did not unlock its premix, and nothing said why) A synergy's
      -- premix: unlocked, or the samples each of its four groups has against the floor.
      local gate = verdict == "mix-synergy" and research.premix_gate(player.force, obs, key)
      if gate and gate.recipe.enabled then
        tip = {"", tip, "\n", {"es.mix-premix-unlocked", item_caption(gate.recipe.name)}}
      elseif gate then
        local c = gate.counts
        tip = {"", tip, "\n\n", {"es.mix-premix-needs", item_caption(gate.recipe.name), tostring(shared.premix.discovery_n),
          tostring(c[1]), mix_caption({[shared.split_band(gate.a)] = gate.da}), tostring(c[2]), mix_caption({[shared.split_band(gate.b)] = gate.db}),
          tostring(c[3]), tostring(c[4])}}
      end
      local l = t.add{type = "label", caption = inter and {"es." .. verdict} or "–", tooltip = tip}
      l.style.font_color = colour
      table.insert(options, mix)
      table.insert(captions, mix_caption(mix))
    end
  end
  if #keys == 0 then
    t.add{type = "label", caption = {"es.mix-none"}}
    for _ = 1, 4 do t.add{type = "label", caption = ""} end
  end
  if fit and fit.best.a > 0.5 and fit.best.b > 0.5 then
    local best = {[A] = math.floor(fit.best.a + 0.5), [B] = math.floor(fit.best.b + 0.5)}
    table.insert(options, best)
    table.insert(captions, {"es.adopt-fitted", mix_caption(best)})
  end
  -- Adopt options change only when the data does (rebuilding an open drop-down closes it).
  local signature = {}
  for _, m in ipairs(options) do table.insert(signature, mix_key(m)) end
  signature = table.concat(signature, "|")
  local dd = page.adopt.choice
  if (storage.gui_mix_adopt[player.index] or {}).key ~= signature then
    dd.items = captions
    dd.selected_index = #captions > 0 and 1 or 0
  end
  storage.gui_mix_adopt[player.index] = {key = signature, values = options}
  page.adopt.adopt.enabled = #options > 0
  page.adopt.adopt.tags = {es_action = "save-preset-mix", target = target.key}
end

local function fill(panel, station, player)
  -- `station` is the force's pool (it has the fields the station records had: obs, side, counts).
  local target = shared.target(gui.view_target(player))
  local effect = gui.effect(player)
  local sums_by = {}
  for _, e in ipairs(gui.effects) do sums_by[e] = gui.summaries(station, target.key, e) end
  local sums = effect == "fullcost" and gui.summaries(station, target.key, "fullcost", gui.priced(player)) or sums_by[effect]
  local stations = 0
  for _, st in pairs(storage.stations) do
    if st.entity.valid and st.entity.force == player.force then stations = stations + 1 end
  end
  panel.pages.screening.empty.visible = station.analysed == 0
  panel.summary.caption = {"es.pool-summary", station.analysed, stations,
    station.unreadable > 0 and {"", " ", {"es.pool-unreadable", station.unreadable}} or "",
    string.format("%.0f", station.data_made or 0),
    -- World strength (0.59): the map's own, fixed when it was made. The science seed (0.70), to share a world.
    {"string-mod-setting.es-world-strength-" .. (storage.truth and storage.truth.strength or "standard")},
    tostring(storage.truth and storage.truth.science_seed or game.surfaces[1].map_gen_settings.seed)}
  panel.foot.adopted.caption = foot_caption(player, target)
  local rows, families, st = gui.screen_rows(player, gui.visible_additives(player.force), sums_by, player.force.index,
    station.obs[target.key], target.key, gui.view_surface(player))
  local tools = panel.pages.screening.grid_tools
  local shows = {{"es.screen-show-all"}, {"es.screen-show-tested"}, {"es.screen-show-untested"}}
  for _, f in ipairs(families) do table.insert(shows, {"es.screen-show-family", {"es.family-" .. f}}) end
  if #tools.show.items ~= #shows then tools.show.items = shows end  -- (rebuilding an open drop-down closes it)
  if tools.show.selected_index ~= math.min(st.show, #shows) then tools.show.selected_index = math.min(st.show, #shows) end
  if tools.sort.selected_index ~= st.sort then tools.sort.selected_index = st.sort end
  fill_overview(gui.overview(panel), sums_by, rows, player.force.index,
    station.obs[target.key], target.key, gui.view_surface(player), station.quality and station.quality[target.key])
  -- Planet selector: rebuilt only when the list changes (rebuilding an open drop-down closes it).
  local surfaces = gui.surfaces_for(player)
  local sig = table.concat(surfaces, ",")
  storage.gui_surfaces = storage.gui_surfaces or {}
  local sdd = panel.top.surface
  if (storage.gui_surfaces[player.index] or {}).sig ~= sig then
    local items = {}
    for i, k in ipairs(surfaces) do
      items[i] = prototypes.space_location and prototypes.space_location[k] and {"space-location-name." .. k} or k
    end
    sdd.items = items
    storage.gui_surfaces[player.index] = {sig = sig, keys = surfaces}
  end
  for i, k in ipairs(surfaces) do if k == gui.view_surface(player) and sdd.selected_index ~= i then sdd.selected_index = i end end
  local mix_samples, mixes = 0, 0
  for key, acc in pairs(gui.obs_of(station, target.key, "yield")) do
    if key:find("+", 1, true) and acc.n > 0 then mix_samples, mixes = mix_samples + acc.n, mixes + 1 end
  end
  panel.pages.screening.mixnote.caption = mixes > 0 and (shared.stage_ok(player.force, shared.stages.mixtures.tech)
    and {"es.mix-note", mix_samples, mixes} or {"es.mix-note-locked", mix_samples, mixes, shared.tech_caption(shared.stages.mixtures.tech)}) or ""
  if panel.pages.theory then gui.fill_theory(panel.pages.theory, station, gui.theory_effect(player)) end
  gui.fill_dossiers(panel.pages.dossiers, player.force)
  -- Coverage: filled only while it is the tab shown (it reads every target's evidence).
  local sel = panel.pages.selected_tab_index and panel.pages.tabs[panel.pages.selected_tab_index]
  if sel and sel.tab.name == "tab_coverage" then gui.fill_coverage(panel.pages.coverage, station, player) end
  if sel and sel.tab.name == "tab_progress" then gui.fill_progress(panel.pages.progress, player) end
  local base = selected_additive(player)
  local additive = base
  local temp_view = false
  local sums_all_bands = sums
  -- A fluid: the Dose-response tab shows one temperature band (chosen, else its best); a living additive one
  -- ripeness band (0.62).
  local kind = band_kind(base)
  local banded = kind == "ripe" or (kind == "temp" and shared.stage_ok(player.force, shared.stages.thermal.tech))
  local head = panel.pages.dose.head
  head.temp.visible, head.temp_label.visible = banded and true or false, banded and true or false
  if banded then
    storage.gui_band_kind = storage.gui_band_kind or {}
    if storage.gui_band_kind[player.index] ~= kind then
      storage.gui_band_kind[player.index] = kind
      local items = {}
      for i, b in ipairs(bands_of(kind)) do
        if kind == "ripe" then
          local lo, hi = shared.ripe_range(b)
          items[i] = {"es.ripe-band", string.format("%d", lo), string.format("%d", hi)}
        else
          items[i] = {"es.temp-band", shared.band_caption(b)}
        end
      end
      table.insert(items, {kind == "ripe" and "es.ripe-all" or "es.temp-all"})
      head.temp.items = items
      head.temp_label.caption = {kind == "ripe" and "es.ripe" or "es.temp"}
      head.temp_label.tooltip = kind == "ripe" and {"es.ripe-tooltip", tostring(math.floor(100 / shared.ripe.bands + 0.5))}
        or {"es.temp-tooltip", tostring(shared.premix.band_width)}
    end
    storage.gui_temp_band = storage.gui_temp_band or {}
    local chosen = storage.gui_temp_band[player.index]
    -- "All temperatures": the chart shows the response over temperature; the rest, the best band.
    temp_view = chosen == "all"
    local b = (not temp_view and chosen) or sums.additives[base].band or usual_band(base)
    additive = b == usual_band(base) and base or (base .. suffix_of(kind) .. b)
    sums = {control = sums.control, additives = {[additive] = sums.bands[base][b]}, bands = sums.bands}
    local bands = bands_of(kind)
    local want = #bands + 1
    if not temp_view then for i, x in ipairs(bands) do if x == b then want = i end end end
    if head.temp.selected_index ~= want then head.temp.selected_index = want end
  end
  -- Keep the drop-downs in step with what is shown (selections can change without a click).
  local function sync(el, index) if el.selected_index ~= index then el.selected_index = index end end
  refresh_items(head.additive, gui.visible_additives(player.force))
  sync(head.additive, index_of(gui.visible_additives(player.force), base))
  sync(head.model, storage.gui_model[player.index] or 1)
  local effect_index, mix_index = 1, 1
  for i, e in ipairs(gui.views) do if e == effect then effect_index = i end end
  for i, e in ipairs(gui.effects) do if e == effect then mix_index = i end end
  sync(head.effect, effect_index)
  if panel.pages.mixtures then sync(panel.pages.mixtures.head.effect, mix_index) end
  -- The full cost's prices: shown with that view only.
  local prow = panel.pages.dose.prices
  prow.visible = effect == "fullcost"
  if not prow.visible then panel.pages.dose.price_note.visible = false end
  if prow.visible then
    local P = gui.prices(player)
    for i, preset in ipairs(gui.price_presets) do if preset == P.preset then sync(prow.preset, i) end end
    for _, sl in ipairs(gui.price_sliders) do
      local slider = prow["slider_" .. sl.key]
      if math.abs(slider.slider_value - P[sl.key]) > 1e-9 then slider.slider_value = P[sl.key] end
      prow["value_" .. sl.key].caption = {"es.price-" .. sl.key, string.format("%g", P[sl.key])}
    end
    -- What the planet changes, said beside the sliders (the sliders keep the player's own prices).
    local _, changed = research.price_on(P, gui.view_surface(player))
    local parts = {""}
    if changed.pollution then table.insert(parts, {"es.price-no-pollution"}) end
    if changed.power then
      if #parts > 1 then table.insert(parts, "  ") end
      table.insert(parts, {"es.price-power-here", string.format("%.2f", changed.power)})
    end
    panel.pages.dose.price_note.caption = #parts > 1 and parts or ""
    panel.pages.dose.price_note.visible = #parts > 1
  end
  local measured = shared.stage_ok(player.force, shared.side_effects_tech)  -- staged reveal
  for _, h in ipairs({head, panel.pages.mixtures and panel.pages.mixtures.head or head}) do
    h.effect.visible, h.effect_label.visible = measured, measured
  end
  -- Target list: rebuilt only when it changes (a trial unlocked, or its first data).
  if panel.top.all_targets then panel.top.all_targets.state = gui.all_targets_on(player) end
  local list = gui.targets_for(station, player.force, target.key, not gui.all_targets_on(player))
  local keys = {}
  for i, t in ipairs(list) do keys[i] = t.key end
  storage.gui_targets = storage.gui_targets or {}
  -- (Counts refresh with the list, on opening and on a choice: rewriting the items of an open drop-down
  -- closes it, and they change with every sample.)
  local signature = table.concat(keys, ",")
  if (storage.gui_targets[player.index] or {}).signature ~= signature then
    local items = {}
    for i, t in ipairs(list) do
      local n = gui.samples_on(station, t.key)
      items[i] = n > 0 and {"", shared.target_caption(t), " (" .. n .. ")"} or shared.target_caption(t)
    end
    panel.top.target.items = items
    storage.gui_targets[player.index] = {signature = signature, keys = keys}
  end
  for i, key in ipairs(keys) do if key == target.key then sync(panel.top.target, i) end end
  -- Clearing is per target and needs a second click (control.lua): say which state the button is in.
  local armed = storage.clear_armed and storage.clear_armed[player.index]
  local clear = panel.foot.clear_button
  clear.caption = armed and armed.target == target.key and {"es.clear-confirm", shared.target_caption(target)}
    or {"es.clear-target"}
  fill_detail(panel.pages.dose.detail_scroll.detail, sums, additive, gui.obs_of(station, target.key, effect),
    station.quality and station.quality[target.key])
  if panel.pages.mixtures then fill_mixtures(panel, station, player, target) end
  fill_presets(panel.pages.presets, player)
  local fit = fill_fit(panel, station, player, target.key, sums, additive)
  if temp_view then gui.fill_temperature(panel, player, sums_all_bands, base) end
  local values, captions = adopt_options(gui.obs_of(station, target.key, "yield"), additive, fit)
  storage.gui_adopt = storage.gui_adopt or {}
  local key = additive .. ":" .. table.concat(values, ",")
  local dd = panel.pages.dose.adopt.dose
  if storage.gui_adopt[player.index] == nil or storage.gui_adopt[player.index].key ~= key then
    dd.items = captions  -- only when the options change: rebuilding an open drop-down closes it
    dd.selected_index = #captions > 0 and 1 or 0
  end
  storage.gui_adopt[player.index] = {key = key, values = values}

  -- The save button follows the selected additive and target.
  local button = panel.pages.dose.adopt.adopt
  button.caption = {"es.save-preset", item_caption(base)}
  button.enabled = #values > 0
  button.tags = {es_action = "save-preset", additive = base, target = target.key}  -- presets name the premix
end

-- The Empirical Science screen: the force's evidence, opened from the shortcut bar, a hotkey or a
-- station's window. A screen of its own, like the technology screen: stations are its labs.
function gui.open(player)
  gui.close(player)
  local frame = player.gui.screen.add{type = "frame", name = "es_science", direction = "vertical"}
  local bar = frame.add{type = "flow", name = "titlebar", direction = "horizontal"}
  bar.drag_target = frame
  bar.add{type = "label", caption = {"es.science-title"}, style = "frame_title", ignored_by_interaction = true}
  local drag = bar.add{type = "empty-widget", style = "draggable_space_header", ignored_by_interaction = true}
  drag.style.horizontally_stretchable = true
  drag.style.height = 24
  bar.add{type = "sprite-button", name = "close_button", sprite = "utility/close", style = "frame_action_button",
    tags = {es_action = "close-science"}}
  local panel = frame.add{type = "frame", name = "panel", style = "inside_shallow_frame_with_padding",
    direction = "vertical"}

  local top = panel.add{type = "flow", name = "top", direction = "horizontal"}
  top.style.vertical_align = "center"
  top.add{type = "label", name = "target_label", caption = {"es.target"}, style = "caption_label"}
  -- Filled by fill (the list grows as trials unlock).
  top.add{type = "drop-down", name = "target", items = {}, tags = {es_action = "target"}}
  top.add{type = "checkbox", name = "all_targets", caption = {"es.all-targets"}, tooltip = {"es.all-targets-tooltip"},
    state = gui.all_targets_on(player), tags = {es_action = "all-targets"}}
  top.add{type = "label", caption = {"es.surface"}, style = "caption_label", tooltip = {"es.surface-tooltip"}}
  top.add{type = "drop-down", name = "surface", items = {}, tags = {es_action = "surface"}}
  storage.gui_surfaces = storage.gui_surfaces or {}
  storage.gui_surfaces[player.index] = nil
  storage.gui_targets = storage.gui_targets or {}
  storage.gui_targets[player.index] = nil
  panel.add{type = "label", name = "summary"}

  local tabs = panel.add{type = "tabbed-pane", name = "pages"}
  local t1 = tabs.add{type = "tab", name = "tab_screening", caption = {"es.tab-screening"}}
  local screening = tabs.add{type = "flow", name = "screening", direction = "vertical"}
  -- Sort and show (0.62, user: the grid grew long and overflowed): remembered per player.
  local tools = screening.add{type = "flow", name = "grid_tools", direction = "horizontal"}
  tools.style.vertical_align = "center"
  local sorts, shows = {}, {}
  for i, k in ipairs(gui.SCREEN_SORTS) do sorts[i] = {"es.screen-sort-" .. k} end
  tools.add{type = "label", caption = {"es.screen-sort"}, style = "caption_label"}
  tools.add{type = "drop-down", name = "sort", items = sorts, selected_index = 1, tags = {es_action = "screen-sort"}}
  tools.add{type = "label", caption = {"es.screen-show"}, style = "caption_label"}
  tools.add{type = "drop-down", name = "show", items = {{"es.screen-show-all"}}, selected_index = 1,
    tags = {es_action = "screen-show"}}
  local grid_scroll = screening.add{type = "scroll-pane", name = "grid_scroll", horizontal_scroll_policy = "never",
    vertical_scroll_policy = "auto-and-reserve-space"}
  grid_scroll.style.maximal_height = 460
  local o = grid_scroll.add{type = "table", name = "overview", column_count = shared.quality_on and 10 or 9,
    draw_horizontal_line_after_headers = true}
  o.style.horizontal_spacing = 12
  local empty = screening.add{type = "label", name = "empty", caption = {"es.empty-screen"}}
  empty.style.single_line = false
  empty.style.maximal_width = 620
  screening.add{type = "label", name = "mixnote"}  -- where mixture results are, when there are any
  -- A fresh panel has fresh drop-downs: forget which choices were last put in them.
  if storage.gui_adopt then storage.gui_adopt[player.index] = nil end
  if storage.gui_mix_adopt then storage.gui_mix_adopt[player.index] = nil end
  tabs.add_tab(t1, screening)

  local t2 = tabs.add{type = "tab", name = "tab_dose", caption = {"es.tab-dose"}}
  local dose = tabs.add{type = "flow", name = "dose", direction = "vertical"}
  local head = dose.add{type = "flow", name = "head", direction = "horizontal"}
  head.style.vertical_align = "center"
  head.add{type = "label", caption = {"es.additive"}, style = "caption_label"}
  local visible = gui.visible_additives(player.force)
  local items = {}
  for i, a in ipairs(visible) do items[i] = item_caption(a.name) end
  head.add{type = "drop-down", name = "additive", items = items, selected_index = index_of(visible, selected_additive(player)),
    tags = {es_action = "select"}}
  local effect_items, view_items = {}, {}
  for i, e in ipairs(gui.effects) do effect_items[i] = {"es.effect-" .. e} end
  for i, e in ipairs(gui.views) do view_items[i] = {"es.effect-" .. e} end
  head.add{type = "label", name = "effect_label", caption = {"es.effect"}, style = "caption_label"}
  head.add{type = "drop-down", name = "effect", items = view_items, selected_index = 1, tags = {es_action = "effect"},
    tooltip = {"es.effect-tooltip"}}
  head.add{type = "label", caption = {"es.model"}, style = "caption_label"}
  local models = {}
  for i, m in ipairs(gui.model_choices) do models[i] = {"es.model-" .. m} end
  head.add{type = "drop-down", name = "model", items = models, selected_index = storage.gui_model[player.index] or 1,
    tags = {es_action = "model"}, tooltip = {"es.model-tooltip"}}
  -- Temperature band, for liquid premixes only (shown by fill).
  local bands = {}
  for i, b in ipairs(shared.all_bands()) do bands[i] = {"es.temp-band", shared.band_caption(b)} end
  table.insert(bands, {"es.temp-all"})  -- the temperature view (0.53)
  head.add{type = "label", name = "temp_label", caption = {"es.temp"}, style = "caption_label", tooltip = {"es.temp-tooltip", tostring(shared.premix.band_width)}}
  head.add{type = "drop-down", name = "temp", items = bands, selected_index = 1, tags = {es_action = "temp-band"}}
  -- Prices for the full cost view: a preset, and a slider per price (ore is the unit).
  local prow = dose.add{type = "flow", name = "prices", direction = "horizontal"}
  prow.style.vertical_align = "center"
  prow.visible = false
  local presets = {}
  for i, p in ipairs(gui.price_presets) do presets[i] = {"es.price-preset-" .. p} end
  prow.add{type = "drop-down", name = "preset", items = presets, selected_index = 1, tags = {es_action = "price-preset"},
    tooltip = {"es.price-tooltip"}}
  for _, sl in ipairs(gui.price_sliders) do
    prow.add{type = "label", name = "value_" .. sl.key, caption = ""}
    local slider = prow.add{type = "slider", name = "slider_" .. sl.key, minimum_value = 0, maximum_value = sl.max,
      value_step = sl.step, value = 0, tags = {es_action = "price", key = sl.key}}
    slider.style.width = 90
  end
  -- What the planet changes in the prices, on its own line (at the row's end it was pushed out of view).
  local note = dose.add{type = "label", name = "price_note", caption = ""}
  note.visible = false
  local camera = dose.add{type = "camera", name = "chart", position = {0, 0}}
  camera.style.width = chart.width
  camera.style.height = chart.height
  chart.setup_camera(camera, player)
  local fitbox = dose.add{type = "flow", name = "fit", direction = "vertical"}
  fitbox.add{type = "label", name = "line1"}
  fitbox.add{type = "label", name = "line2"}
  -- (0.68: the growing tables scroll.)
  local dscroll = dose.add{type = "scroll-pane", name = "detail_scroll", horizontal_scroll_policy = "never"}
  dscroll.style.maximal_height = 260
  local t = dscroll.add{type = "table", name = "detail", column_count = #gui.detail_columns(),
    draw_horizontal_line_after_headers = true}
  t.style.horizontal_spacing = 12
  -- Saving a composition sits with its evidence: this additive, at a dose from this tab.
  local dadopt = dose.add{type = "flow", name = "adopt", direction = "horizontal"}
  dadopt.style.top_margin = 8
  dadopt.style.vertical_align = "center"
  dadopt.add{type = "label", caption = {"es.save-dose-label"}}
  local doses = {}
  for d = 1, shared.max_dose do doses[d] = tostring(d) end
  dadopt.add{type = "drop-down", name = "dose", items = doses, selected_index = 1}
  dadopt.add{type = "button", name = "adopt", tooltip = {"es.save-tooltip"}}
  tabs.add_tab(t2, dose)

  -- Mixtures and Theory join the panel when researched (0.70: hidden tabs made the engine misdraw the strip,
  -- a hidden tab's caption in the first slot; gui.refresh_player rebuilds when a stage opens).
  if shared.stage_ok(player.force, shared.stages.mixtures.tech) then
    local t3 = tabs.add{type = "tab", name = "tab_mixtures", caption = {"es.tab-mixtures"}}
    local mixtures = tabs.add{type = "flow", name = "mixtures", direction = "vertical"}
    local mhead = mixtures.add{type = "flow", name = "head", direction = "horizontal"}
    mhead.style.vertical_align = "center"
    local all = {}
    for i, a in ipairs(visible) do all[i] = item_caption(a.name) end
    local mix_a, mix_b = selected_pair(player)
    mhead.add{type = "label", name = "effect_label", caption = {"es.effect"}, style = "caption_label"}
    mhead.add{type = "drop-down", name = "effect", items = effect_items, selected_index = 1, tags = {es_action = "effect"},
      tooltip = {"es.effect-tooltip"}}
    mhead.add{type = "label", caption = {"es.mix-a"}, style = "caption_label"}
    mhead.add{type = "drop-down", name = "mix_a", items = all, selected_index = index_of(visible, mix_a),
      tags = {es_action = "mix-a"}}
    mhead.add{type = "drop-down", name = "band_a", items = {}, tags = {es_action = "mix-band-a"}, visible = false}
    mhead.add{type = "label", caption = {"es.mix-b"}, style = "caption_label"}
    mhead.add{type = "drop-down", name = "mix_b", items = all, selected_index = index_of(visible, mix_b),
      tags = {es_action = "mix-b"}}
    mhead.add{type = "drop-down", name = "band_b", items = {}, tags = {es_action = "mix-band-b"}, visible = false}
    local mcamera = mixtures.add{type = "camera", name = "chart", position = {0, 0}}
    mcamera.style.width = chart.width
    mcamera.style.height = chart.height
    chart.setup_camera(mcamera, player, "mix")
    local mfit = mixtures.add{type = "flow", name = "fit", direction = "vertical"}
    mfit.add{type = "label", name = "line1"}
    mfit.add{type = "label", name = "line2"}
    local mscroll = mixtures.add{type = "scroll-pane", name = "tested_scroll", horizontal_scroll_policy = "never"}
    mscroll.style.maximal_height = 300
    local tested = mscroll.add{type = "table", name = "tested", column_count = 5, draw_horizontal_line_after_headers = true}
    tested.style.horizontal_spacing = 12
    local madopt = mixtures.add{type = "flow", name = "adopt", direction = "horizontal"}
    madopt.style.top_margin = 8
    madopt.style.vertical_align = "center"
    madopt.add{type = "label", caption = {"es.save-mix-label"}}
    madopt.add{type = "drop-down", name = "choice", items = {}}
    madopt.add{type = "button", name = "adopt", caption = {"es.save-mix"}, tooltip = {"es.save-tooltip"}}
    tabs.add_tab(t3, mixtures)
  end

  -- Coverage (0.70): where the evidence is.
  local tc = tabs.add{type = "tab", name = "tab_coverage", caption = {"es.tab-coverage"}}
  local cov = tabs.add{type = "flow", name = "coverage", direction = "vertical"}
  cov.add{type = "label", name = "summary"}
  local cscroll = cov.add{type = "scroll-pane", name = "scroll"}
  cscroll.style.maximal_height = 420
  cscroll.add{type = "flow", name = "body", direction = "vertical"}
  tabs.add_tab(tc, cov)

  -- Theory (0.53): hidden before its stage.
  if shared.stage_ok(player.force, shared.stages.theory.tech) then
    local t5 = tabs.add{type = "tab", name = "tab_theory", caption = {"es.tab-theory"}}
    local th = tabs.add{type = "flow", name = "theory", direction = "vertical"}
    local intro = th.add{type = "label", caption = {"es.theory-intro"}}
    intro.style.single_line = false
    intro.style.maximal_width = 640
    local thead = th.add{type = "flow", name = "head", direction = "horizontal"}
    thead.style.vertical_align = "center"
    local theory_items = {}
    for i, e in ipairs(gui.theory_effects) do theory_items[i] = {"es.effect-" .. e} end
    thead.add{type = "label", caption = {"es.effect"}, style = "caption_label"}
    thead.add{type = "drop-down", name = "effect", items = theory_items, selected_index = 1,
      tags = {es_action = "theory-effect"}, tooltip = {"es.effect-tooltip"}}
    th.add{type = "label", name = "fit"}
    th.add{type = "label", caption = {"es.theory-families"}, style = "caption_label"}
    th.add{type = "table", name = "families", column_count = 8, draw_horizontal_line_after_headers = true}
    th.add{type = "label", caption = {"es.theory-next"}, style = "caption_label"}
    local nscroll = th.add{type = "scroll-pane", name = "next_scroll"}
    nscroll.style.maximal_height = 260
    nscroll.add{type = "table", name = "next", column_count = 3, draw_horizontal_line_after_headers = true}
    tabs.add_tab(t5, th)
  end

  -- Dossiers.
  local t6 = tabs.add{type = "tab", name = "tab_dossiers", caption = {"es.tab-dossiers"}}
  local dp = tabs.add{type = "flow", name = "dossiers", direction = "vertical"}
  -- The report (0.69): above the rest, once the force has finished.
  local rep_flow = dp.add{type = "flow", name = "report", direction = "vertical"}
  rep_flow.visible = false
  local dintro = dp.add{type = "label", name = "intro"}
  dintro.style.single_line = false
  dintro.style.maximal_width = 640
  dp.add{type = "label", name = "status", style = "caption_label"}
  dp.add{type = "label", name = "bars"}
  local dscroll = dp.add{type = "scroll-pane", name = "scroll", horizontal_scroll_policy = "never"}
  dscroll.style.maximal_height = 420
  dscroll.add{type = "flow", name = "body", direction = "vertical"}
  tabs.add_tab(t6, dp)

  local t4 = tabs.add{type = "tab", name = "tab_presets", caption = {"es.tab-presets"}}
  local pre = tabs.add{type = "flow", name = "presets", direction = "vertical"}
  pre.add{type = "label", caption = {"es.presets-intro"}}.style.single_line = false
  local pscroll = pre.add{type = "scroll-pane", name = "list_scroll", horizontal_scroll_policy = "never"}
  pscroll.style.maximal_height = 400
  local pt = pscroll.add{type = "table", name = "list", column_count = 4, draw_horizontal_line_after_headers = true}
  pt.style.horizontal_spacing = 12
  pre.add{type = "label", name = "empty"}
  tabs.add_tab(t4, pre)

  -- Progress (0.72, user: numbers go up): the force's totals over game time (control.lua, record_progress).
  local tg = tabs.add{type = "tab", name = "tab_progress", caption = {"es.tab-progress"}}
  local pg = tabs.add{type = "flow", name = "progress", direction = "vertical"}
  local ph = pg.add{type = "flow", name = "head", direction = "horizontal"}
  ph.style.vertical_align = "center"
  ph.add{type = "label", caption = {"es.progress-graph"}, style = "caption_label"}
  local graphs = {}
  for i, g in ipairs(gui.PROGRESS_GRAPHS) do graphs[i] = {"es.progress-" .. g, tostring(shared.progress_per)} end
  ph.add{type = "drop-down", name = "graph", items = graphs, selected_index = 1, tags = {es_action = "progress-graph"}}
  ph.add{type = "label", caption = {"es.progress-range"}, style = "caption_label"}
  local ranges = {}
  for i, r in ipairs(gui.PROGRESS_RANGES) do
    ranges[i] = r[2] and r[2] > 216000 and {"es.progress-range-hours", tostring(r[2] / 216000)} or {"es.progress-range-" .. r[1]}
  end
  ph.add{type = "drop-down", name = "range", items = ranges, selected_index = #ranges, tags = {es_action = "progress-range"}}
  ph.add{type = "checkbox", name = "marks", caption = {"es.progress-marks"}, tooltip = {"es.progress-marks-tooltip"},
    state = true, tags = {es_action = "progress-marks"}}
  local pcam = pg.add{type = "camera", name = "chart", position = {0, 0}}
  pcam.style.width = chart.width
  pcam.style.height = chart.height
  chart.setup_camera(pcam, player, "progress")
  pg.add{type = "label", name = "legend"}
  tabs.add_tab(tg, pg)

  -- Notebook (0.72, user: as simple as possible): one page of the force's own notes, kept with the map.
  local tn = tabs.add{type = "tab", name = "tab_notebook", caption = {"es.tab-notebook"}}
  local nb = tabs.add{type = "flow", name = "notebook", direction = "vertical"}
  local box = nb.add{type = "text-box", name = "page", text = storage.notebook and storage.notebook[player.force.index] or "",
    tags = {es_action = "notebook"}}
  box.word_wrap = true
  box.style.width = 640
  box.style.height = 420
  tabs.add_tab(tn, nb)

  local foot = panel.add{type = "flow", name = "foot", direction = "horizontal"}
  foot.style.top_margin = 12
  foot.style.vertical_align = "center"
  foot.add{type = "label", name = "adopted"}
  local spacer = foot.add{type = "empty-widget"}
  spacer.style.horizontally_stretchable = true
  foot.add{type = "button", name = "clear_button", tooltip = {"es.clear-tooltip"},
    style = "red_button", tags = {es_action = "clear"}}

  frame.force_auto_center()
  storage.open[player.index] = true
  player.opened = frame  -- Esc and E close it, like any window
  fill(panel, gui.pool(player.force, gui.view_surface(player)), player)
end

function gui.close(player)
  local frame = player.gui.screen.es_science
  if frame then frame.destroy() end
  storage.open[player.index] = nil
  chart.clear(player.index)
end

function gui.toggle(player)
  if player.gui.screen.es_science then gui.close(player) else gui.open(player) end
end

-- Theory, Findings and Presets do not depend on the target (0.70, user): there the Target row and the
-- target's footer hide; Planet stays (Theory reads it).
local GENERAL_TABS = {tab_coverage = true, tab_theory = true, tab_dossiers = true, tab_presets = true, tab_notebook = true,
  tab_progress = true}
function gui.target_row(panel)
  local pages = panel.pages
  local sel = pages.selected_tab_index and pages.tabs[pages.selected_tab_index]
  local on = not (sel and GENERAL_TABS[sel.tab.name])
  for _, name in ipairs({"target_label", "target", "all_targets"}) do
    if panel.top[name] then panel.top[name].visible = on end
  end
  panel.foot.visible = on
end

function gui.refresh_player(player)
  local frame = player.gui.screen.es_science
  -- A stage researched since the panel was built: rebuild it with its tab, on the same tab.
  if frame then
    local pages = frame.panel.pages
    if (pages.tab_mixtures ~= nil) ~= shared.stage_ok(player.force, shared.stages.mixtures.tech)
        or (pages.tab_theory ~= nil) ~= shared.stage_ok(player.force, shared.stages.theory.tech) then
      local sel = pages.selected_tab_index and pages.tabs[pages.selected_tab_index]
      local name = sel and sel.tab.name
      gui.open(player)
      frame = player.gui.screen.es_science
      if frame then
        frame.panel.pages.selected_tab_index = 1
        for i, t in ipairs(frame.panel.pages.tabs) do
          if name and t.tab.name == name then frame.panel.pages.selected_tab_index = i end
        end
      end
    end
  end
  if frame then
    fill(frame.panel, gui.pool(player.force, gui.view_surface(player)), player)
    gui.target_row(frame.panel)
  end
end

-- Refresh every open screen of a force.
function gui.refresh_force(force_index)
  for player_index in pairs(storage.open) do
    local player = game.get_player(player_index)
    if player and player.force.index == force_index then gui.refresh_player(player) end
  end
end

-- The station's own window, beside its inventory: what this station did, its port's target, and the way
-- to the screen.
local function fill_station(frame, station, player)
  local inv = station.entity.get_inventory(defines.inventory.chest)
  local packs = {""}
  for name in pairs(station.packs_seen) do
    table.insert(packs, "[item=" .. name .. "]" .. inv.get_item_count_filtered{name = name} .. " ")  -- (any quality)
  end
  local counts = frame.panel.counts
  counts.v_analysed.caption = tostring(station.analysed)
  local waiting = 0
  for _, it in pairs(inv.get_contents()) do if shared.is_sample(it.name) then waiting = waiting + it.count end end
  counts.v_waiting.caption = tostring(waiting)
  counts.v_packs.caption = #packs > 1 and packs or "–"
  counts.v_unreadable.caption = tostring(station.unreadable)
  counts.v_failed.caption = tostring(station.failed or 0)
  -- (0.72: shown only once they count something; on most planets they never do.)
  counts.k_unreadable.visible, counts.v_unreadable.visible = station.unreadable > 0, station.unreadable > 0
  counts.k_failed.visible, counts.v_failed.visible = (station.failed or 0) > 0, (station.failed or 0) > 0
  counts.v_data.caption = string.format("%.0f", station.data_made or 0)
  -- The page the port serves now (0.59: the circuit interface was silent about it).
  local served = station.served
  local st = served and served.target and shared.target(served.target)
  counts.v_port.caption = st and {"es.st-port-value", tostring(served.page or 0), shared.target_caption(st)} or "–"
  frame.panel.hint.visible = station.analysed == 0
  local list = gui.targets_for(gui.pool(player.force, shared.surface_key(station.entity.surface)), player.force,
    station.view_target)
  local items, selected = {}, 1
  for i, t in ipairs(list) do
    items[i] = shared.target_caption(t)
    if t.key == station.view_target then selected = i end
  end
  local dd = frame.panel.port.port_target
  if #dd.items ~= #items then dd.items = items end  -- rebuilding an open drop-down closes it
  if dd.selected_index ~= selected then dd.selected_index = selected end
  storage.station_targets = storage.station_targets or {}
  local keys = {}
  for i, t in ipairs(list) do keys[i] = t.key end
  storage.station_targets[player.index] = keys
end

function gui.open_station(player, unit)
  gui.close_station(player)
  local station = storage.stations[unit]
  if not station then return end
  local frame = player.gui.relative.add{type = "frame", name = "es_station", direction = "vertical",
    caption = {"es.station-title"},
    anchor = {gui = defines.relative_gui_type.container_gui, position = defines.relative_gui_position.right,
      name = STATION}}
  local panel = frame.add{type = "frame", name = "panel", style = "inside_shallow_frame_with_padding",
    direction = "vertical"}
  -- The station's own counts, one per row (a single line wrapped mid-way through the packs).
  local counts = panel.add{type = "table", name = "counts", column_count = 2}
  counts.style.horizontal_spacing = 12
  for _, key in ipairs({"analysed", "waiting", "packs", "unreadable", "failed", "data", "port"}) do
    counts.add{type = "label", name = "k_" .. key, caption = {"es.st-" .. key}, style = "caption_label", tooltip = {"es.st-" .. key .. "-tooltip",
      tostring(math.floor(shared.spoil_fail * 100))}}  -- (only st-failed reads it)
    counts.add{type = "label", name = "v_" .. key}
  end
  local port = panel.add{type = "flow", name = "port", direction = "horizontal"}
  port.style.vertical_align = "center"
  port.add{type = "label", caption = {"es.port-target"}, style = "caption_label", tooltip = {"es.port-target-tooltip"}}
  port.add{type = "drop-down", name = "port_target", items = {}, tags = {es_action = "port-target"}}
  panel.add{type = "checkbox", name = "port_own", caption = {"es.port-own"}, tooltip = {"es.port-own-tooltip"},
    state = station.port_source == "station", tags = {es_action = "port-source"}}
  local hint = panel.add{type = "label", name = "hint", caption = {"es.empty-station"}}
  hint.style.single_line = false
  hint.style.maximal_width = 300
  panel.add{type = "button", caption = {"es.open-science"}, tags = {es_action = "open-science"}}
  storage.station_open = storage.station_open or {}
  storage.station_open[player.index] = unit
  fill_station(frame, station, player)
end

function gui.close_station(player)
  local frame = player.gui.relative.es_station
  if frame then frame.destroy() end
  if storage.station_open then storage.station_open[player.index] = nil end
end

-- Refresh every window on this station (closing them when it is gone).
function gui.refresh_station(unit)
  for player_index, open_unit in pairs(storage.station_open or {}) do
    if open_unit == unit then
      local player = game.get_player(player_index)
      local frame = player and player.gui.relative.es_station
      local station = storage.stations[unit]
      if frame and station and station.entity.valid then
        fill_station(frame, station, player)
      elseif player then
        gui.close_station(player)
      end
    end
  end
end

return gui
