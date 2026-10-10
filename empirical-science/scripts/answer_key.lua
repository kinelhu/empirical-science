-- The answer key (debug screen, decided 2026-10-02): one map's hidden world as a table, for
-- the /es-answer-key screen and scripts/ground_truth.sh. Per target, every dosable additive at every dose,
-- for every effect: yield, net ore, full cost at both price sets, speed, cleanliness, efficiency,
-- freshness and quality chance; its best dose for each; alternative recipes; family chemistry; and (0.68)
-- what would make a finding or a major finding on this map. Never shown without asking.
local shared = require("shared")
local truth = require("scripts.truth")
local research = require("scripts.research")
local dossiers = require("scripts.dossiers")

local answer_key = {}

-- Every effect the screen ranks by, in its order. "cleanliness" is the pollution effect ("good is
-- positive", truth.lua); findings use the same names.
answer_key.READOUTS = {"yield", "net", "full_early", "full_late", "speed", "cleanliness", "efficiency", "freshness", "quality"}

-- All effects of one composition on one target.
local function effects(t, key, mix, spoilable, agent)
  local g = truth.gain_on(t, key, mix)
  local sp = truth.effect_on(t, key, mix, "speed")
  local cl = truth.effect_on(t, key, mix, "pollution")
  local ef = truth.effect_on(t, key, mix, "efficiency")
  return {yield = g, net = g - research.tau(key, mix) / 1000, speed = sp, cleanliness = cl, efficiency = ef,
    full_early = research.full_saving(key, mix, g, sp, cl, ef, shared.prices.early),
    full_late = research.full_saving(key, mix, g, sp, cl, ef, shared.prices.late),
    freshness = spoilable and truth.effect_on(t, key, mix, "freshness") or nil,
    quality = agent and truth.quality_chance(t, key, mix) or nil}
end
answer_key.effects = effects

function answer_key.compute()
  local t = storage.truth
  local out = {seed = storage.truth.science_seed or game.surfaces[1].map_gen_settings.seed, targets = {}, chemistry = {}}
  local function kind_of(a)
    if a.agent then return "quality agent" end
    if a.premix_of then
      return (shared.additive(a.premix_of[1]).refined_from or shared.additive(a.premix_of[2]).refined_from)
        and "catalyst premix" or "premix"
    end
    if a.refined_from then return "activated catalyst" end
    if a.residue_of then return "residue" end
    if a.living then return "living" end  -- (0.62: ripeness)
    if shared.is_early(a.name) then return "early" end  -- (0.70: wood is tier 1, not early)
    return "tier " .. a.tier
  end
  for _, target in ipairs(shared.targets) do
    local rows = {}
    local batch_ore = 1000 / research.tau(target.key, {coal = 1})
    local spoilable = truth.spoilable(target.key)
    for _, a in ipairs(shared.all_additives) do
      if not a.volatile then
        local step = a.fluid and 10 or 1
        -- Every dose's effects, and each effect's best dose.
        local by_dose, best = {}, {}
        for d = step, a.max_dose, step do
          local e = effects(t, target.key, {[a.name] = d}, spoilable, a.agent)
          by_dose[d] = e
          for _, r in ipairs(answer_key.READOUTS) do
            if e[r] and (not best[r] or e[r] > best[r].v) then best[r] = {v = e[r], d = d} end
          end
        end
        -- Its best state (0.61-0.62): a fluid's best temperature, a living additive's best ripeness, and the
        -- yield at its best dose there (the yield above is at the usual temperature, fresh).
        local state = a.living and truth.ripe_best(t, a.name)
          or (a.fluid and ((t.premix_temp and t.premix_temp[a.name]) or (t.fluid_temp and t.fluid_temp[a.name])))
        local at_state, net_state, net_state_d
        if state then
          at_state, net_state = -1e9, -1e9
          for d = step, a.max_dose, step do
            local g = truth.gain_on(t, target.key, {[a.name] = d}, nil, {[a.name] = state})
            at_state = math.max(at_state, g)
            -- (0.70) Net ore there too: a living additive is dosed at the ripeness a player picks.
            local n = g - research.tau(target.key, {[a.name] = d}) / 1000
            if n > net_state then net_state, net_state_d = n, d end
          end
        end
        local r = t.targets[target.key] and t.targets[target.key][a.name]
        local gd = best.yield.d
        local at = by_dose[gd]
        table.insert(rows, {name = a.name, kind = kind_of(a), family = a.premix_of and a.phase or shared.mix_family(a.name) or a.family,
          shape = r and r.kind == "activator" and truth.shape_of(t, target.key, a.name, r) or (r and r.kind) or nil,
          state = state, living = a.living or nil, at_state = at_state, net_state = net_state, net_state_d = net_state_d, mixes_as = shared.mix_family(a.name),
          premix_of = a.premix_of, fluid = a.fluid or false, agent = a.agent or nil, by_dose = by_dose, best = best,
          -- (The fields scripts/ground_truth.sh has always read.)
          gain = best.yield.v, gain_dose = gd, net = best.net.v, net_dose = best.net.d, speed = at.speed,
          pollution = at.cleanliness, efficiency = at.efficiency, full_early = best.full_early and best.full_early.v,
          full_late = best.full_late and best.full_late.v, quality = best.quality and best.quality.v})
      end
    end
    table.insert(out.targets, {key = target.key, result = target.result, batch = target.batch, batch_ore = batch_ore,
      spoilable = spoilable, responsiveness = t.responsiveness and t.responsiveness[target.key] or 1, rows = rows})
  end
  local fams = {}
  for f in pairs(t.chem or {}) do if not f:find("^premix") then table.insert(fams, f) end end
  table.sort(fams)
  for _, f1 in ipairs(fams) do
    out.chemistry[f1] = {}
    for _, f2 in ipairs(fams) do out.chemistry[f1][f2] = truth.pair_strength(t, f1, f2) end
  end
  return out
end

-- The best two-additive mixtures on a target for one effect: pairs among the eight best single additives
-- (raw, not premixes or agents), each at its own best dose for that effect. Returns {mix, v, alone}.
function answer_key.pairs(target, readout)
  local t = storage.truth
  local singles = {}
  for _, r in ipairs(target.rows) do
    if r.best[readout] and not r.premix_of and not r.agent then table.insert(singles, r) end
  end
  table.sort(singles, function(x, y) return x.best[readout].v > y.best[readout].v end)
  local out = {}
  for i = 1, math.min(8, #singles) do
    for j = i + 1, math.min(8, #singles) do
      local a, b = singles[i], singles[j]
      local mix = {[a.name] = a.best[readout].d, [b.name] = b.best[readout].d}
      local e = effects(t, target.key, mix, target.spoilable, false)
      if e[readout] then
        table.insert(out, {mix = mix, v = e[readout], alone = math.max(a.best[readout].v, b.best[readout].v)})
      end
    end
  end
  table.sort(out, function(x, y) return x.v > y.v end)
  return out
end

---------------------------------------------------------------------------
-- The screen: /es-answer-key. By target (rank by any effect), Summary, Findings.
---------------------------------------------------------------------------
local KINDS = {early = "early", ["tier 1"] = "tier1", ["tier 2"] = "tier2", residue = "residue", living = "living", ["activated catalyst"] = "catalyst",
               premix = "premix", ["catalyst premix"] = "cat-premix", ["quality agent"] = "agent"}
local ROWS = 40  -- the target tab shows the best forty by the chosen effect
local PLANET_ORDER = {"nauvis", "vulcanus", "fulgora", "gleba", "aquilo", "space"}

local function icon(name, fluid) return (fluid and "[fluid=" or "[item=") .. name .. "]" end
local function additive_caption(r)
  if r.premix_of then
    local a, b = shared.additive(r.premix_of[1]), shared.additive(r.premix_of[2])
    return icon(a.name, a.fluid) .. icon(b.name, b.fluid)
  end
  return icon(r.name, r.fluid)
end
local function tooltip_of(r)
  if r.premix_of then
    local a, b = r.premix_of[1], r.premix_of[2]
    local function n(x) local d = shared.additive(x); return d.fluid and prototypes.fluid[x].localised_name or prototypes.item[x].localised_name end
    return {"", n(a), " + ", n(b)}
  end
  return r.fluid and prototypes.fluid[r.name].localised_name or prototypes.item[r.name].localised_name
end
local function pct(x)
  if not x then return "–" end
  if math.abs(x) < 0.0005 then return "0.0%" end  -- never "-0.0%"
  return string.format("%+.1f%%", x * 100)
end
local function rate(x) return x and string.format("%.1f%%", x * 100) or "–" end
local function value_caption(r, v) return r == "quality" and rate(v) or pct(v) end
local function mix_caption(mix)
  local parts = {""}
  local names = {}
  for name in pairs(mix) do table.insert(names, name) end
  table.sort(names)
  for _, name in ipairs(names) do
    local a = shared.additive(name)
    table.insert(parts, icon(name, a and a.fluid) .. "×" .. mix[name] .. " ")
  end
  return parts
end
local function readout_caption(r)
  if r == "net" then return {"es.ak-net"} end
  if r == "full_early" then return {"es.ak-full-early"} end
  if r == "full_late" then return {"es.ak-full-late"} end
  return {"es.effect-" .. (r == "cleanliness" and "pollution" or r)}
end
local function target_caption(t) return {"", "[item=" .. t.result .. "] ", prototypes.item[t.result].localised_name} end

-- What a true effect would make, by this map's thresholds: "major", "finding" or nil. (Proof needs the
-- lower bound above the bar, so a true effect just at it is out of reach.)
local function finding_of(readout, v, key)
  local th = dossiers.thresholds()
  local std = dossiers.standard_for(th, key)
  if v and th.exceptional[readout] and v >= th.exceptional[readout] then return "major" end
  if v and std[readout] and v >= std[readout] then return "finding" end
  return nil
end

-- Computed when needed, kept while the screen is open (the hidden world does not change; not saved).
local cache = {}
local function data_of()
  if not cache.value then cache.value = answer_key.compute() end
  return cache.value
end

local function fill_target(frame, player)
  local d = data_of()
  local state = storage.answer_key.players[player.index]
  local t = d.targets[state.target] or d.targets[1]
  local readout = answer_key.READOUTS[state.sort] or "yield"
  local rows = {}
  for _, r in ipairs(t.rows) do if r.best[readout] then table.insert(rows, r) end end
  table.sort(rows, function(x, y) return x.best[readout].v > y.best[readout].v end)
  local tbl = frame.ak_tabs.target_page.scroll.rows
  tbl.clear()
  local heads = {"ak-additive", "ak-family", "ak-kind", "ak-shape", "ak-dose", "ak-ranked", "ak-yield", "ak-net", "ak-speed",
                 "ak-clean", "ak-efficiency", "ak-freshness", "ak-quality", "ak-best-at", "ak-yield-best", "ak-finding"}
  for _, h in ipairs(heads) do
    tbl.add{type = "label", caption = h == "ak-ranked" and readout_caption(readout) or {"es." .. h}, style = "caption_label"}
  end
  for i = 1, math.min(ROWS, #rows) do
    local r = rows[i]
    local b = r.best[readout]
    local e = r.by_dose[b.d]
    tbl.add{type = "label", caption = {"", additive_caption(r), " ", tooltip_of(r)}, tooltip = tooltip_of(r)}
    tbl.add{type = "label", caption = {"es.family-" .. (r.family or "none")}}
    tbl.add{type = "label", caption = {"es.ak-kind-" .. KINDS[r.kind]}}
    tbl.add{type = "label", caption = r.shape and {"es.ak-shape-" .. r.shape} or "–"}
    tbl.add{type = "label", caption = tostring(b.d)}
    tbl.add{type = "label", caption = value_caption(readout, b.v), style = "bold_label"}
    tbl.add{type = "label", caption = pct(e.yield)}
    tbl.add{type = "label", caption = pct(e.net)}
    tbl.add{type = "label", caption = pct(e.speed)}
    tbl.add{type = "label", caption = pct(e.cleanliness)}
    tbl.add{type = "label", caption = pct(e.efficiency)}
    tbl.add{type = "label", caption = e.freshness and pct(e.freshness) or "–"}
    tbl.add{type = "label", caption = e.quality and rate(e.quality) or "–"}
    tbl.add{type = "label", caption = not r.state and "–" or r.living and string.format("%d%%", math.floor(r.state * 100 + 0.5))
      or string.format("%d °C", math.floor(r.state + 0.5))}
    tbl.add{type = "label", caption = r.at_state and pct(r.at_state) or "–"}
    local f = finding_of(readout, b.v, t.key)
    tbl.add{type = "label", caption = f and {"es.ak-finding-" .. f} or "–"}
  end
  frame.ak_tabs.target_page.head.info.caption = {"es.ak-target-info", string.format("%.2f", t.responsiveness),
    string.format("%.0f", t.batch_ore)}
  -- The best pairs for this effect.
  local pt = frame.ak_tabs.target_page.pairs
  pt.clear()
  for _, h in ipairs({"ak-mixture", "ak-ranked", "ak-vs-alone"}) do
    pt.add{type = "label", caption = h == "ak-ranked" and readout_caption(readout) or {"es." .. h}, style = "caption_label"}
  end
  local pairs_list = answer_key.pairs(t, readout)
  for i = 1, math.min(5, #pairs_list) do
    local p = pairs_list[i]
    pt.add{type = "label", caption = mix_caption(p.mix)}
    pt.add{type = "label", caption = value_caption(readout, p.v), style = "bold_label"}
    pt.add{type = "label", caption = pct(p.v - p.alone)}
  end
end

local function fill_summary(frame)
  local d = data_of()
  local tbl = frame.ak_tabs.summary_page.scroll.rows
  tbl.clear()
  for _, h in ipairs({"ak-target", "ak-best-raw", "ak-best-deep", "ak-best-quality"}) do
    tbl.add{type = "label", caption = {"es." .. h}, style = "caption_label"}
  end
  local RAW = {["tier 1"] = true, ["tier 2"] = true, residue = true}
  local DEEP = {["activated catalyst"] = true, premix = true, ["catalyst premix"] = true}
  for _, t in ipairs(d.targets) do
    local br, bd, bq
    for _, r in ipairs(t.rows) do
      if RAW[r.kind] and (not br or r.net > br.net) then br = r end
      if DEEP[r.kind] and (not bd or r.net > bd.net) then bd = r end
      if r.quality and (not bq or r.quality > bq.quality) then bq = r end
    end
    tbl.add{type = "label", caption = target_caption(t)}
    for _, r in ipairs({br, bd}) do
      tbl.add{type = "label", caption = r and {"", additive_caption(r), "  ", pct(r.net), " @", tostring(r.net_dose)} or "–",
        tooltip = r and tooltip_of(r) or nil}
    end
    tbl.add{type = "label", caption = bq and {"", additive_caption(bq), "  ", rate(bq.quality)} or "–"}
  end
end

-- Findings (0.68): this map's thresholds, what each planet could reach, and the major findings on offer.
local function fill_findings(frame, player)
  local d = data_of()
  local th = dossiers.thresholds()
  local page = frame.ak_tabs.findings_page.scroll.body
  page.clear()
  page.add{type = "label", caption = {"es.ak-findings-rules", tostring(shared.dossier.volume_batches),
    tostring(th.exceptional_needed), tostring(#dossiers.EXCEPTIONAL)}}.style.single_line = false
  -- (0.70) A finding's bar per planet, then the major finding's.
  local planets = {}
  for _, name in ipairs(PLANET_ORDER) do if th.planets[name] then table.insert(planets, name) end end
  local tt = page.add{type = "table", column_count = 2 + #planets, draw_horizontal_line_after_headers = true}
  tt.style.horizontal_spacing = 24
  tt.add{type = "label", caption = {"es.ak-effect"}, style = "caption_label"}
  for _, name in ipairs(planets) do
    tt.add{type = "label", caption = {"", {"es.ak-finding-finding"}, " ",
      name == "space" and {"es.dossier-space"} or "[planet=" .. name .. "]"}, style = "caption_label"}
  end
  tt.add{type = "label", caption = {"es.ak-finding-major"}, style = "caption_label"}
  for _, r in ipairs(dossiers.EXCEPTIONAL) do
    tt.add{type = "label", caption = readout_caption(r)}
    for _, name in ipairs(planets) do
      local std = dossiers.standard_of(th, name)
      tt.add{type = "label", caption = std[r] and value_caption(r, std[r]) or "–"}
    end
    tt.add{type = "label", caption = value_caption(r, th.exceptional[r])}
  end
  -- Planets: targets with a dose that would make a finding (true effect at or above a bar).
  local by_key = {}
  for _, t in ipairs(d.targets) do by_key[t.key] = t end
  page.add{type = "label", caption = {"es.ak-planets"}, style = "caption_label"}.style.top_margin = 8
  local pl = page.add{type = "table", column_count = 4, draw_horizontal_line_after_headers = true}
  pl.style.horizontal_spacing = 24
  for _, h in ipairs({"ak-planet", "ak-quota", "ak-qualifying", "ak-targets-qualifying"}) do
    pl.add{type = "label", caption = {"es." .. h}, style = "caption_label"}
  end
  for _, planet in ipairs(PLANET_ORDER) do
    local keys = th.planets[planet]
    if keys then
      local n, list = 0, {""}
      local present = 0
      for _, k in ipairs(keys) do
        local t = by_key[k]
        if t then
          present = present + 1
          local ok = false
          for _, r in ipairs(dossiers.STANDARD) do
            for _, row in ipairs(t.rows) do
              if row.best[r] and finding_of(r, row.best[r].v, k) then ok = true end
            end
          end
          if ok then n = n + 1; table.insert(list, "[item=" .. t.result .. "]") end
        end
      end
      if present > 0 then
        pl.add{type = "label", caption = planet == "space" and {"es.dossier-space"} or {"space-location-name." .. planet}}
        pl.add{type = "label", caption = tostring(math.min(th.quota[planet], present))}
        pl.add{type = "label", caption = string.format("%d / %d", n, present)}
        pl.add{type = "label", caption = list}
      end
    end
  end
  -- Major findings on offer, effect by effect: the best five (target, composition), with their room.
  page.add{type = "label", caption = {"es.ak-majors"}, style = "caption_label"}.style.top_margin = 8
  local mt = page.add{type = "table", column_count = 5, draw_horizontal_line_after_headers = true}
  mt.style.horizontal_spacing = 24
  for _, h in ipairs({"ak-effect", "ak-target", "ak-additive", "ak-value", "ak-room"}) do
    mt.add{type = "label", caption = {"es." .. h}, style = "caption_label"}
  end
  for _, r in ipairs(dossiers.EXCEPTIONAL) do
    local found = {}
    for _, t in ipairs(d.targets) do
      for _, row in ipairs(t.rows) do
        local b = row.best[r]
        if b and b.v >= th.exceptional[r] then table.insert(found, {t = t, row = row, v = b.v, d = b.d}) end
      end
    end
    table.sort(found, function(x, y) return x.v > y.v end)
    if #found == 0 then
      mt.add{type = "label", caption = readout_caption(r)}
      mt.add{type = "label", caption = {"es.ak-none-here"}}
      for _ = 1, 3 do mt.add{type = "label", caption = ""} end
    end
    for i = 1, math.min(5, #found) do
      local f = found[i]
      mt.add{type = "label", caption = i == 1 and readout_caption(r) or ""}
      mt.add{type = "label", caption = target_caption(f.t)}
      mt.add{type = "label", caption = {"", additive_caption(f.row), "×", tostring(f.d)}, tooltip = tooltip_of(f.row)}
      mt.add{type = "label", caption = value_caption(r, f.v)}
      mt.add{type = "label", caption = value_caption(r, f.v - th.exceptional[r])}
    end
  end
end

function answer_key.open(player)
  storage.answer_key = storage.answer_key or {}
  storage.answer_key.players = storage.answer_key.players or {}
  storage.answer_key.players[player.index] = storage.answer_key.players[player.index] or {target = 1, sort = 1}
  local old = player.gui.screen.es_answer_key
  if old then old.destroy() end
  local frame = player.gui.screen.add{type = "frame", name = "es_answer_key", direction = "vertical"}
  local bar = frame.add{type = "flow", direction = "horizontal"}
  bar.drag_target = frame
  bar.add{type = "label", caption = {"es.ak-title"}, style = "frame_title"}.drag_target = frame
  local filler = bar.add{type = "empty-widget", style = "draggable_space_header"}
  filler.style.horizontally_stretchable, filler.style.height = true, 24
  filler.drag_target = frame
  bar.add{type = "sprite-button", style = "frame_action_button", sprite = "utility/close",
    tags = {es_action = "ak-close"}}
  local tabs = frame.add{type = "tabbed-pane", name = "ak_tabs"}
  local d = data_of()
  -- By target: rank by an effect.
  local t1 = tabs.add{type = "tab", caption = {"es.ak-tab-target"}}
  local page = tabs.add{type = "flow", name = "target_page", direction = "vertical"}
  local head = page.add{type = "flow", name = "head", direction = "horizontal"}
  head.style.vertical_align = "center"
  local items = {}
  for i, t in ipairs(d.targets) do items[i] = target_caption(t) end
  local st = storage.answer_key.players[player.index]
  head.add{type = "drop-down", items = items, selected_index = st.target, tags = {es_action = "ak-target"}}
  local sorts = {}
  for i, k in ipairs(answer_key.READOUTS) do sorts[i] = readout_caption(k) end
  head.add{type = "label", caption = {"es.ak-sort"}, style = "caption_label"}
  head.add{type = "drop-down", items = sorts, selected_index = st.sort, tags = {es_action = "ak-sort"}}
  head.add{type = "label", name = "info"}
  local scroll = page.add{type = "scroll-pane", name = "scroll"}
  scroll.style.maximal_height = 460
  local rows = scroll.add{type = "table", name = "rows", column_count = 16, draw_horizontal_line_after_headers = true}
  rows.style.horizontal_spacing = 14
  for c = 5, 15 do rows.style.column_alignments[c] = "right" end
  page.add{type = "label", caption = {"es.ak-pairs"}, style = "caption_label"}.style.top_margin = 8
  local pt = page.add{type = "table", name = "pairs", column_count = 3, draw_horizontal_line_after_headers = true}
  pt.style.horizontal_spacing = 24
  tabs.add_tab(t1, page)
  -- Summary tab.
  local t2 = tabs.add{type = "tab", caption = {"es.ak-tab-summary"}}
  local spage = tabs.add{type = "flow", name = "summary_page", direction = "vertical"}
  spage.add{type = "label", caption = {"es.ak-seed", tostring(d.seed)}}
  local sscroll = spage.add{type = "scroll-pane", name = "scroll"}
  sscroll.style.maximal_height = 560
  sscroll.add{type = "table", name = "rows", column_count = 4, draw_horizontal_line_after_headers = true}
  tabs.add_tab(t2, spage)
  -- Findings tab.
  local t3 = tabs.add{type = "tab", caption = {"es.ak-tab-findings"}}
  local fpage = tabs.add{type = "flow", name = "findings_page", direction = "vertical"}
  local fscroll = fpage.add{type = "scroll-pane", name = "scroll"}
  fscroll.style.maximal_height = 560
  fscroll.add{type = "flow", name = "body", direction = "vertical"}
  tabs.add_tab(t3, fpage)
  fill_target(frame, player)
  fill_summary(frame)
  fill_findings(frame, player)
  frame.force_auto_center()
end

function answer_key.close(player)
  local f = player.gui.screen.es_answer_key
  if f then f.destroy() end
  cache.value = nil
end

-- A selection on the screen: target or effect. Returns true when it was the answer key's.
function answer_key.on_selection(player, action, index)
  if action ~= "ak-target" and action ~= "ak-sort" then return false end
  local st = storage.answer_key.players[player.index]
  if action == "ak-target" then st.target = index else st.sort = index end
  local f = player.gui.screen.es_answer_key
  if f then fill_target(f, player) end
  return true
end

-- The command: admins only in multiplayer; the first use warns (it shows everything a game would
-- uncover), the second opens.
function answer_key.command(event)
  local player = event.player_index and game.get_player(event.player_index)
  if not player then return end
  if game.is_multiplayer() and not player.admin then player.print({"es.ak-admin-only"}); return end
  storage.answer_key = storage.answer_key or {}
  storage.answer_key.warned = storage.answer_key.warned or {}
  if not storage.answer_key.warned[player.index] then
    storage.answer_key.warned[player.index] = true
    player.print({"es.ak-warning"})
    return
  end
  answer_key.open(player)
end

return answer_key
