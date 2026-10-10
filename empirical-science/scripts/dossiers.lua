-- Dossiers: the ending. A dossier is a target's record of an effect the
-- force proved and put to work: the effect's lower 95% bound (its own samples against their control, in
-- one planet's evidence) above the readout's threshold, and machines dosed with that composition having
-- made shared.dossier.volume_batches trial batches of the target. Thresholds, quotas and each planet's
-- targets come from docs/balance.py (scripts/dossier_<strength>.lua, rule D3), never typed here.
-- Judged by the force's own evidence and factory, never by the truth.
local shared = require("shared")
local stats = require("scripts.stats")

local dossiers = {}

local GENERATED = {standard = require("scripts.dossier_standard"), harsh = require("scripts.dossier_harsh")}
dossiers.STANDARD = {"yield", "speed", "cleanliness", "efficiency"}
dossiers.EXCEPTIONAL = {"yield", "speed", "cleanliness", "efficiency", "freshness", "quality"}
dossiers.ACHIEVEMENT = "es-dossiers-complete"

function dossiers.thresholds()
  local strength = storage.truth and storage.truth.strength or "standard"
  return GENERATED[strength] or GENERATED.standard
end
-- Standard bars per planet (0.70, user: one bar for all let Gleba's ripened additives set Nauvis's). A
-- target off the model's lists (another mod's) is judged by Nauvis's.
function dossiers.planet_of(th, key)
  th.planet_of = th.planet_of or {}
  if not next(th.planet_of) then
    for planet, keys in pairs(th.planets) do for _, k in ipairs(keys) do th.planet_of[k] = planet end end
  end
  return th.planet_of[key] or "nauvis"
end
function dossiers.standard_of(th, planet)
  if type(th.standard.yield) == "number" then return th.standard end  -- (a flat table: one bar for all)
  return th.standard[planet] or th.standard.nauvis
end
function dossiers.standard_for(th, key) return dossiers.standard_of(th, dossiers.planet_of(th, key)) end

-- Products of a target made by machines dosed with a composition (its evidence key), per force.
-- `written` (test hooks only): history written into a save, not production; the Progress tab leaves it out.
function dossiers.record_made(force, target_key, key, count, written)
  storage.dossier_made = storage.dossier_made or {}
  local by = storage.dossier_made[force.index] or {}
  storage.dossier_made[force.index] = by
  by[target_key] = by[target_key] or {}
  by[target_key][key] = (by[target_key][key] or 0) + count
  if not written then
    storage.dosed_total = storage.dosed_total or {}  -- (0.72: every dosed product, for the Progress tab)
    storage.dosed_total[force.index] = (storage.dosed_total[force.index] or 0) + count
  end
  storage.dossier_dirty = storage.dossier_dirty or {}
  storage.dossier_dirty[force.index] = true
end

local function made_of(force, target_key, key)
  local by = storage.dossier_made and storage.dossier_made[force.index]
  return by and by[target_key] and by[target_key][key] or 0
end

function dossiers.volume(target)
  return shared.dossier.volume_batches * target.batch
end

-- A cell's effect against its control, lower 95% bound, as a fraction (readings are in per mille).
-- (Every reading is "good is positive", truth.lua: a positive pollution reading is less emitted, i.e. cleaner.)
local function lower_bound(cell, control, sign)
  local a, b = stats.summary(cell), stats.summary(control)
  if not (a and b and a.var and b.var) then return nil end
  local se = math.sqrt(a.var / a.n + b.var / b.n)
  return (sign * (a.mean - b.mean) - 1.96 * se) / 1000
end

-- Every proven cell of a target in one pool: {readout, key, lb}.
local function cells_of(pool, target_key, out, skey)
  local function each(tbl, readout, sign)
    if not (tbl and tbl.control) then return end
    for key, cell in pairs(tbl) do
      if key ~= "control" then
        local lb = lower_bound(cell, tbl.control, sign)
        if lb then table.insert(out, {readout = readout, key = key, lb = lb, skey = skey, n = cell.n}) end
      end
    end
  end
  each(pool.obs and pool.obs[target_key], "yield", 1)
  local side = pool.side or {}
  each(side.speed and side.speed[target_key], "speed", 1)
  each(side.pollution and side.pollution[target_key], "cleanliness", 1)
  each(side.efficiency and side.efficiency[target_key], "efficiency", 1)
  each(side.freshness and side.freshness[target_key], "freshness", 1)
  for key, q in pairs(pool.quality and pool.quality[target_key] or {}) do
    if q.b > 0 then
      local _, lo = stats.wilson(q.k, q.b)
      table.insert(out, {readout = "quality", key = key, lb = lo, skey = skey, n = q.n})
    end
  end
end

-- (0.72) A target's proven-cell list, kept until evidence changes (stats.add bumps the version): the
-- lower bounds of every result for five readouts were recomputed each time findings were judged. Runtime only.
local CELLS = {}
function dossiers.cached_cells(force, key, pools)
  -- (When this target's evidence last changed, in any pool: a sample on another target leaves it.)
  local id, v = force.index .. "|" .. key, 0
  for _, pool in pairs(pools) do
    local ch = pool.changed and pool.changed[key]
    if ch and ch > v then v = ch end
  end
  local c = CELLS[id]
  if c and c.v == v then return c.list end
  local all, by = {}, {}
  for skey, pool in pairs(pools) do cells_of(pool, key, all, skey) end
  for _, cell in ipairs(all) do  -- (by readout: each pass of the judgement reads one or a few)
    by[cell.readout] = by[cell.readout] or {}
    table.insert(by[cell.readout], cell)
  end
  CELLS[id] = {v = v, list = by}
  return by
end

-- Every tested cell of the force on one target, over its pools: {readout, key, lb, skey, n} (the report).
function dossiers.cells(force, target_key)
  local list = {}
  for skey, pool in pairs(storage.pools and storage.pools[force.index] or {}) do cells_of(pool, target_key, list, skey) end
  return list
end

-- Where a planet counts: reached by the force (Nauvis always; space once it has a platform).
local function reached(force, planet)
  if planet == "nauvis" then return true end
  if planet == "space" then return next(force.platforms) ~= nil end
  local p = game.planets and game.planets[planet]
  return p ~= nil and p.surface ~= nil
end

dossiers.is_reached = function(force, planet) return reached(force, planet) end

-- The force's dossiers now. Returns {planets = {name -> {quota, done, reached, targets = {...}}},
-- exceptional = {readout -> {...}}, exc_done, exc_needed, finished}.
function dossiers.evaluate(force)
  local th = dossiers.thresholds()
  local pools = storage.pools and storage.pools[force.index] or {}
  local function best(list, readouts, thresholds, target)
    -- The entry to show: a complete one if any, else a proven one with the most made, else the closest.
    -- (0.72) Compared in place; only the winner is copied (a copy per cell per pass cost seconds on a big
    -- save, every ten seconds while doses were made).
    local volume = dossiers.volume(target)
    local done, done_r, proven, proven_made, closest, closest_r
    for readout in pairs(readouts) do for _, cell in ipairs(list[readout] or {}) do
      local t = thresholds[cell.readout]
      if t then
        local r = cell.lb / t
        if cell.lb >= t then
          local made = made_of(force, target.key, cell.key)
          if made >= volume then
            if not done or r > done_r then done, done_r = cell, r end
          elseif not proven or made > proven_made then proven, proven_made = cell, made end
        elseif not closest or r > closest_r then closest, closest_r = cell, r end
      end
    end end
    local function entry(cell)
      -- A copy (review 0.68: written into the shared cell, the major pass overwrote the planet rows' bars).
      return {readout = cell.readout, key = cell.key, lb = cell.lb, skey = cell.skey, threshold = thresholds[cell.readout],
        made = made_of(force, target.key, cell.key), volume = volume, target = target.key}
    end
    return done and {entry = entry(done), state = "done"} or proven and {entry = entry(proven), state = "proven"}
      or closest and {entry = entry(closest), state = "open"} or {state = "none"}
  end
  local std_set, exc_set = {}, {}
  for _, r in ipairs(dossiers.STANDARD) do std_set[r] = true end
  for _, r in ipairs(dossiers.EXCEPTIONAL) do exc_set[r] = true end

  local by_target = {}
  local result = {planets = {}, exceptional = {}, exc_needed = th.exceptional_needed}
  for planet, keys in pairs(th.planets) do
    local p = {quota = th.quota[planet], done = 0, reached = reached(force, planet), targets = {}}
    for _, key in ipairs(keys) do
      local target = shared.target(key)
      if target then
        local list = by_target[key] and by_target[key].list or dossiers.cached_cells(force, key, pools)
        by_target[key] = {target = target, list = list}
        local b = best(list, std_set, dossiers.standard_of(th, planet), target)
        b.target = target
        table.insert(p.targets, b)
        if b.state == "done" then p.done = p.done + 1 end
      end
    end
    if #p.targets > 0 then
      p.quota = math.min(p.quota, #p.targets)
      result.planets[planet] = p
    end
  end
  local exc_done = 0
  for _, r in ipairs(dossiers.EXCEPTIONAL) do
    local only, pick = {[r] = true}, {state = "none"}
    local rank = {done = 3, proven = 2, open = 1, none = 0}
    for _, bt in pairs(by_target) do
      local b = best(bt.list, only, th.exceptional, bt.target)
      if rank[b.state] > rank[pick.state] or (b.state == pick.state and b.entry and pick.entry
          and b.entry.lb > pick.entry.lb) then
        pick = b
      end
    end
    result.exceptional[r] = pick
    if pick.state == "done" then exc_done = exc_done + 1 end
  end
  result.exc_done = exc_done
  local finished = exc_done >= th.exceptional_needed
  for _, p in pairs(result.planets) do
    if p.reached and p.done < p.quota then finished = false end
  end
  result.finished = finished
  return result
end

-- Re-judge forces whose evidence or production changed; the first time one finishes, tell its players
-- and unlock the achievement. Called on a slow tick.
-- One message per finding as it completes (0.67): planet findings by target, major ones by effect.
local function announce(force, r)
  storage.dossier_announced = storage.dossier_announced or {}
  local seen = storage.dossier_announced[force.index] or {}
  storage.dossier_announced[force.index] = seen
  local function say(id, b)
    if b.state ~= "done" or seen[id] then return end
    seen[id] = true
    -- (0.72, user: findings get timings) When it completed, for the Findings tab and the progress charts.
    storage.dossier_done_at = storage.dossier_done_at or {}
    storage.dossier_done_at[force.index] = storage.dossier_done_at[force.index] or {}
    storage.dossier_done_at[force.index][id] = game.tick
    local e = b.entry
    local t = shared.target(e.target)
    local value = e.readout == "quality" and string.format("%.1f%%", e.lb * 100) or string.format("%+.1f%%", e.lb * 100)
    local mix = {""}
    for part in e.key:gmatch("[^+]+") do
      local name, dose = part:match("^(.+):(%d+)$")
      if name then
        local base = shared.split_band(name)
        local a = shared.additive(base)
        table.insert(mix, ((a and a.fluid) and "[fluid=" or "[item=") .. base .. "]×" .. dose .. " ")
      end
    end
    force.print({"es.finding-complete", shared.target_caption(t),
      {"es.effect-" .. (e.readout == "cleanliness" and "pollution" or e.readout)}, value, mix})
  end
  for _, p in pairs(r.planets) do
    for _, b in ipairs(p.targets) do say("t|" .. b.target.key, b) end
  end
  for readout, b in pairs(r.exceptional) do say("x|" .. readout, b) end
end

dossiers.announce = announce

function dossiers.update(on_finished)
  storage.dossier_state = storage.dossier_state or {}
  storage.dossier_finished = storage.dossier_finished or {}
  storage.dossier_seen = storage.dossier_seen or {}
  storage.dossier_dirty = storage.dossier_dirty or {}
  for _, force in pairs(game.forces) do
    local i = force.index
    local analysed = dossiers.analysed(force)
    if #force.players > 0 and (storage.dossier_dirty[i] or storage.dossier_seen[i] ~= analysed) then
      local r = dossiers.evaluate(force)
      storage.dossier_state[i], storage.dossier_seen[i], storage.dossier_dirty[i] = r, analysed, nil
      announce(force, r)
      if dossiers.on_judged then dossiers.on_judged(force, r) end  -- (0.72, the achievements)
      if r.finished and not storage.dossier_finished[i] then
        storage.dossier_finished[i] = game.tick
        on_finished(force, r)
      end
    end
  end
end

-- Samples analysed across the force's pools: a cheap sign that the evidence changed.
function dossiers.analysed(force)
  local n = 0
  for _, pool in pairs(storage.pools and storage.pools[force.index] or {}) do n = n + (pool.analysed or 0) end
  return n
end

function dossiers.state(force)
  local s = storage.dossier_state and storage.dossier_state[force.index]
  if not s then
    s = dossiers.evaluate(force)
    storage.dossier_state = storage.dossier_state or {}
    storage.dossier_state[force.index] = s
  end
  return s
end

return dossiers
