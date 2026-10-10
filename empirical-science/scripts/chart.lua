-- Dose-response chart, drawn with LuaRendering on factorio-charts' hidden surface and shown in the
-- GUI through a camera. factorio-charts provides the surface, chunk and camera management.
local charts = require("__factorio-charts__.charts")

local chart = {}

chart.width, chart.height = 576, 320          -- design size in pixels (32 px per tile at zoom 1)
local W, H = chart.width / 32, chart.height / 32
local LEFT, RIGHT, TOP, BOTTOM = 2.7, 0.5, 0.5, 1.7  -- margins in tiles (room for axis titles)

-- Okabe-Ito, named for what each colour encodes.
local colour = {
  dose_mean = {r = 0.0, g = 0.447, b = 0.698},      -- blue
  control = {r = 0.6, g = 0.6, b = 0.6},            -- grey
  fitted_curve = {r = 0.835, g = 0.369, b = 0.0},   -- vermillion
  optimum = {r = 0.0, g = 0.62, b = 0.451},         -- bluish green
  axis = {r = 0.75, g = 0.75, b = 0.75},
  grid = {r = 0.3, g = 0.3, b = 0.3},
  label = {r = 0.85, g = 0.85, b = 0.85},
}

local function surface_data()
  if not storage.chart_surface then
    storage.chart_surface = charts.surface.create("es-charts",
      {viewport_width = chart.width, viewport_height = chart.height})
  end
  return storage.chart_surface
end

-- One render state (a reserved patch of the hidden surface) per player and chart kind, kept for reuse.
local function key(player_index, kind) return kind and (player_index .. ":" .. kind) or player_index end

function chart.state_for(player_index, kind)
  storage.charts = storage.charts or {}
  local k = key(player_index, kind)
  if not storage.charts[k] then
    storage.charts[k] = charts.surface.create_render_state(surface_data(),
      {viewport_width = chart.width, viewport_height = chart.height})
  end
  return storage.charts[k]
end

function chart.clear(player_index)
  for _, kind in ipairs({false, "mix", "progress"}) do
    local state = storage.charts and storage.charts[key(player_index, kind or nil)]
    if state then charts.surface.clear_render_state(state) end
  end
end

-- Point the GUI camera at the player's chart (of the given kind).
function chart.setup_camera(camera, player, kind)
  local state = chart.state_for(player.index, kind)
  local c = state.chunk.coord
  camera.surface_index = surface_data().surface.index
  camera.position = {c.x + W / 2, c.y + H / 2}
  -- A GUI camera at zoom 1 shows tiles at twice the size the widget's GUI units suggest, so the zoom
  -- that fits the design size is display_scale / 2 (factorio-charts uses the same rule). Measured from
  -- screenshots at display scale 1.5 (scripts/guitest.sh): zoom 1.5 and 1.0 both cropped the chart.
  camera.zoom = player.display_scale / 2
end

local function nice_step(range)
  for _, step in ipairs({25, 50, 100, 200, 250, 500, 1000}) do
    if range / step <= 6 then return step end
  end
  return 2000
end

-- data: {points = {{dose, mean, lo, hi, control}}, curve = function(d) or nil, optimum = {dose, lo, hi} or nil}
-- Gains are in per mille. Returns the number of render objects drawn.
function chart.draw(player_index, data)
  local state = chart.state_for(player_index)
  charts.surface.clear_render_state(state)
  local surface = surface_data().surface
  local ox, oy = state.chunk.coord.x, state.chunk.coord.y
  local ids = state.line_ids
  local MAX_DOSE = data.max_dose or 9
  local MIN_DOSE = data.min_dose or 0  -- (temperatures below zero, 0.61)
  local span = MAX_DOSE - MIN_DOSE
  local label_step = span > 200 and 50 or span > 20 and 10 or 1
  -- Y range from the data, the fit and zero.
  local ymin, ymax = 0, 0
  for _, p in ipairs(data.points) do
    ymin = math.min(ymin, p.lo or p.mean); ymax = math.max(ymax, p.hi or p.mean)
  end
  if data.curve then
    for i = 0, 36 do
      local y = data.curve(MIN_DOSE + i * span / 36)
      ymin = math.min(ymin, y); ymax = math.max(ymax, y)
    end
  end
  local step = nice_step(math.max(ymax - ymin, 100))
  ymin = math.floor(ymin / step) * step
  ymax = math.ceil(ymax / step) * step
  if ymax == ymin then ymax = ymin + step end

  local x0, x1 = ox + LEFT, ox + W - RIGHT
  local y0, y1 = oy + H - BOTTOM, oy + TOP
  -- Half a dose of padding each side, so the control (dose 0) is not drawn on the y axis.
  local pad = span / 18
  local function X(d) return x0 + (x1 - x0) * (d - MIN_DOSE + pad) / (span + 2 * pad) end
  local function Y(v) return y0 + (y1 - y0) * (v - ymin) / (ymax - ymin) end
  local function line(a, b, c, width, dash)
    table.insert(ids, rendering.draw_line{surface = surface, from = a, to = b, color = c, width = width or 1,
      dash_length = dash, gap_length = dash})
  end
  local function text(s, at, c, align, valign)
    table.insert(ids, rendering.draw_text{surface = surface, target = at, text = s, color = c or colour.label,
      scale = 0.9, alignment = align or "center", vertical_alignment = valign or "middle"})
  end

  -- Grid, axes and labels.
  for v = ymin, ymax, step do
    line({x0, Y(v)}, {x1, Y(v)}, v == 0 and colour.axis or colour.grid, v == 0 and 2 or 1)
    text(string.format("%+d%%", math.floor(v / 10 + 0.5)), {x0 - 0.15, Y(v)}, colour.label, "right")
  end
  for d = math.ceil(MIN_DOSE / label_step) * label_step, MAX_DOSE, label_step do
    text(d == 0 and not data.no_control and "ctrl" or tostring(d), {X(d), y0 + 0.45}, colour.label)
  end
  line({x0, y0}, {x0, y1}, colour.axis, 1)
  -- Axis titles; the y title is rotated to read bottom to top.
  table.insert(ids, rendering.draw_text{surface = surface, target = {(x0 + x1) / 2, y0 + 1.1},
    text = {data.x_title or "es.chart-x"}, color = colour.label, scale = 0.9, alignment = "center", vertical_alignment = "middle"})
  table.insert(ids, rendering.draw_text{surface = surface, target = {ox + 0.45, (y0 + y1) / 2},
    text = {data.y_title or "es.chart-y"}, color = colour.label, scale = 0.9, orientation = 0.75,
    alignment = "center", vertical_alignment = "middle"})

  -- Fitted curve and optimum.
  if data.curve then
    local prev
    for i = 0, 90 do
      local d = MIN_DOSE + i * span / 90
      local pt = {X(d), Y(data.curve(d))}
      if prev then line(prev, pt, colour.fitted_curve, 3) end
      prev = pt
    end
  end
  if data.optimum then
    local o = data.optimum
    line({X(o.dose), y0}, {X(o.dose), y1}, colour.optimum, 2, 0.2)
    if o.lo and o.hi then
      local lo, hi = math.max(MIN_DOSE, o.lo), math.min(MAX_DOSE, o.hi)
      line({X(lo), y1 + 0.1}, {X(hi), y1 + 0.1}, colour.optimum, 4)
    end
  end

  -- Per-dose means with 95% CI whiskers.
  for _, p in ipairs(data.points) do
    local c = p.control and colour.control or colour.dose_mean
    if p.lo and p.hi then
      line({X(p.dose), Y(p.lo)}, {X(p.dose), Y(p.hi)}, c, 2)
      line({X(p.dose) - 0.12, Y(p.lo)}, {X(p.dose) + 0.12, Y(p.lo)}, c, 2)
      line({X(p.dose) - 0.12, Y(p.hi)}, {X(p.dose) + 0.12, Y(p.hi)}, c, 2)
    end
    table.insert(ids, rendering.draw_circle{surface = surface, target = {X(p.dose), Y(p.mean)},
      radius = 0.14, filled = true, color = c})
  end
  return #ids
end

-- (0.72) Progress over game time. data: {series = {{label, colour, points = {{tick, value}}}}, stacked = bool,
-- marks = {ticks} (findings: dotted lines), from = tick, to = tick, y_title = localised, percent = bool}.
-- Returns the number of render objects drawn.
local function nice_step_any(range)
  local mag = 10 ^ math.floor(math.log(math.max(range, 1e-9), 10))
  for _, m in ipairs({1, 2, 5, 10}) do
    if range / (m * mag) <= 6 then return m * mag end
  end
  return 10 * mag
end
chart.mark_colour = {r = 0.6, g = 0.6, b = 0.6}  -- a finding's time (grey, dotted)
function chart.draw_series(player_index, data)
  local state = chart.state_for(player_index, "progress")
  charts.surface.clear_render_state(state)
  local surface = surface_data().surface
  local ox, oy = state.chunk.coord.x, state.chunk.coord.y
  local ids = state.line_ids
  local t0, t1 = data.from, math.max(data.to, data.from + 3600)
  -- Stacked: each series drawn on top of the ones before it.
  local tops = {}
  local ymax, ymin = 0, 0
  for si, sr in ipairs(data.series) do
    tops[si] = {}
    for i, p in ipairs(sr.points) do
      local base = data.stacked and si > 1 and tops[si - 1][i] or 0
      tops[si][i] = base + p[2]
      if p[1] >= t0 then ymax = math.max(ymax, tops[si][i]); ymin = math.min(ymin, tops[si][i]) end
    end
  end
  local step = nice_step_any(math.max(ymax - ymin, 1))
  ymax = math.max(step, math.ceil(ymax / step) * step)
  ymin = math.floor(ymin / step) * step  -- (extra products dip below zero where a dose hurts)
  local x0, x1 = ox + LEFT, ox + W - RIGHT
  local y0, y1 = oy + H - BOTTOM, oy + TOP
  local function X(t) return x0 + (x1 - x0) * (t - t0) / (t1 - t0) end
  local function Y(v) return y0 + (y1 - y0) * (v - ymin) / (ymax - ymin) end
  local function line(a, b, c, width, dash)
    table.insert(ids, rendering.draw_line{surface = surface, from = a, to = b, color = c, width = width or 1,
      dash_length = dash, gap_length = dash})
  end
  local function text(s2, at, c, align)
    table.insert(ids, rendering.draw_text{surface = surface, target = at, text = s2, color = c or colour.label,
      scale = 0.9, alignment = align or "center", vertical_alignment = "middle"})
  end
  for v = ymin, ymax, step do
    line({x0, Y(v)}, {x1, Y(v)}, v == 0 and colour.axis or colour.grid, v == 0 and 2 or 1)
    local label = data.percent and string.format("%.0f%%", v) or (v >= 1e6 and string.format("%.1fM", v / 1e6)
      or v >= 1e4 and string.format("%.0fk", v / 1e3) or string.format("%g", v))
    text(label, {x0 - 0.15, Y(v)}, colour.label, "right")
  end
  -- Game time along the bottom: minutes under two hours (a new game's first hour is most of the early
  -- game), hours beyond.
  local minutes = (t1 - t0) / 3600
  if minutes <= 120 then
    local mstep = 1
    for _, m in ipairs({1, 2, 5, 10, 15, 30}) do if minutes / m <= 6 then mstep = m break end end
    for m = math.ceil(t0 / 3600 / mstep) * mstep, t1 / 3600 + 1e-9, mstep do
      text({"es.time-minutes", string.format("%d", m)}, {X(m * 3600), y0 + 0.45}, colour.label)
    end
  else
    local hours = minutes / 60
    local hstep = hours <= 12 and 1 or nice_step_any(hours)
    for h = math.ceil(t0 / 216000 / hstep) * hstep, t1 / 216000 + 1e-9, hstep do
      text({"es.time-hours", string.format("%d", h)}, {X(h * 216000), y0 + 0.45}, colour.label)
    end
  end
  line({x0, y0}, {x0, y1}, colour.axis, 1)
  table.insert(ids, rendering.draw_text{surface = surface, target = {ox + 0.45, (y0 + y1) / 2},
    text = data.y_title, color = colour.label, scale = 0.9, orientation = 0.75,
    alignment = "center", vertical_alignment = "middle"})
  for _, t in ipairs(data.marks or {}) do
    if t >= t0 and t <= t1 then line({X(t), y0}, {X(t), y1}, chart.mark_colour, 1, 0.15) end
  end
  for si, sr in ipairs(data.series) do
    -- A lone point (no history yet) as a dot: a line needs two.
    if #sr.points == 1 and sr.points[1][1] >= t0 then
      table.insert(ids, rendering.draw_circle{surface = surface, target = {X(sr.points[1][1]), Y(tops[si][1])},
        radius = 0.12, filled = true, color = sr.colour})
    end
    local prev
    for i, p in ipairs(sr.points) do
      if p[1] >= t0 then
        local pt = {X(p[1]), Y(tops[si][i])}
        if prev then line(prev, pt, sr.colour, 2) end
        prev = pt
      elseif tops[si][i + 1] and sr.points[i + 1][1] >= t0 then
        prev = {x0, Y(tops[si][i])}  -- (the line enters from the left edge)
      end
    end
  end
  return #ids
end

-- Heat map of a fitted response surface over two doses. data: {surface = function(a, b) or nil,
-- max_a, max_b (axis), tested_a, tested_b (range of the data), points = {{a, b}}, best = {a, b},
-- title_a, title_b (localised)}. Gains in per mille. Cells outside the tested range are faint.
local CELLS_X, CELLS_Y = 24, 14
local gain_colour = {r = 0.0, g = 0.447, b = 0.698}   -- blue: yield gained
local loss_colour = {r = 0.835, g = 0.369, b = 0.0}   -- vermillion: yield lost

function chart.draw_surface(player_index, data)
  local state = chart.state_for(player_index, "mix")
  charts.surface.clear_render_state(state)
  local surface = surface_data().surface
  local ox, oy = state.chunk.coord.x, state.chunk.coord.y
  local ids = state.line_ids
  local x0, x1 = ox + LEFT, ox + W - RIGHT
  local y0, y1 = oy + H - BOTTOM, oy + TOP
  local function X(a) return x0 + (x1 - x0) * a / data.max_a end
  local function Y(b) return y0 + (y1 - y0) * b / data.max_b end
  local function text(s, at, align, orientation)
    table.insert(ids, rendering.draw_text{surface = surface, target = at, text = s, color = colour.label, scale = 0.9,
      alignment = align or "center", vertical_alignment = "middle", orientation = orientation, use_rich_text = true})
  end
  if data.surface then
    local vmax = 100
    for i = 0, CELLS_X do for j = 0, CELLS_Y do
      vmax = math.max(vmax, math.abs(data.surface(data.max_a * i / CELLS_X, data.max_b * j / CELLS_Y)))
    end end
    for i = 0, CELLS_X - 1 do
      for j = 0, CELLS_Y - 1 do
        local a, b = data.max_a * (i + 0.5) / CELLS_X, data.max_b * (j + 0.5) / CELLS_Y
        local v = data.surface(a, b)
        local k = math.min(1, math.abs(v) / vmax)
        local inside = a <= data.tested_a + 1e-9 and b <= data.tested_b + 1e-9
        local base = v >= 0 and gain_colour or loss_colour
        local alpha = inside and 0.85 or 0.25
        table.insert(ids, rendering.draw_rectangle{surface = surface, filled = true,
          left_top = {X(data.max_a * i / CELLS_X), Y(data.max_b * (j + 1) / CELLS_Y)},
          right_bottom = {X(data.max_a * (i + 1) / CELLS_X), Y(data.max_b * j / CELLS_Y)},
          color = {r = base.r * k * alpha, g = base.g * k * alpha, b = base.b * k * alpha, a = alpha}})
      end
    end
  end
  local step_a = data.max_a > 20 and 10 or 1
  local step_b = data.max_b > 20 and 20 or 1
  for a = 0, data.max_a, step_a do text(a == 0 and "0" or tostring(a), {X(a), y0 + 0.45}) end
  for b = step_b, data.max_b, step_b do text(tostring(b), {x0 - 0.15, Y(b)}, "right") end
  table.insert(ids, rendering.draw_line{surface = surface, from = {x0, y0}, to = {x1, y0}, color = colour.axis, width = 1})
  table.insert(ids, rendering.draw_line{surface = surface, from = {x0, y0}, to = {x0, y1}, color = colour.axis, width = 1})
  text(data.title_a, {(x0 + x1) / 2, y0 + 1.1})
  text(data.title_b, {ox + 0.45, (y0 + y1) / 2}, "center", 0.75)
  for _, p in ipairs(data.points or {}) do
    table.insert(ids, rendering.draw_circle{surface = surface, target = {X(p.a), Y(p.b)}, radius = 0.13,
      filled = false, width = 2, color = {r = 1, g = 1, b = 1}})
  end
  if data.best then
    table.insert(ids, rendering.draw_circle{surface = surface, target = {X(data.best.a), Y(data.best.b)},
      radius = 0.18, filled = true, color = colour.optimum})
  end
  return #ids
end

return chart
