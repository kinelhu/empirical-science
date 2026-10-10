-- Dose-response regression on per-dose summaries. The player chooses the model; the fit reports
-- how well it describes the data (R², lack-of-fit test against replicate scatter), never the truth.
local stats = require("scripts.stats")

local regress = {}

regress.models = {"quadratic", "linear", "saturating", "threshold", "cliff"}
regress.params = {linear = 2, quadratic = 3, saturating = 3, threshold = 3, cliff = 4}
regress.max_dose = 9

-- Solve A x = b for a small dense system by Gaussian elimination; nil if singular.
local function solve(A, b)
  local n = #b
  local M = {}
  for i = 1, n do
    M[i] = {}
    for j = 1, n do M[i][j] = A[i][j] end
    M[i][n + 1] = b[i]
  end
  for c = 1, n do
    local p = c
    for r = c + 1, n do if math.abs(M[r][c]) > math.abs(M[p][c]) then p = r end end
    if math.abs(M[p][c]) < 1e-12 then return nil end
    M[c], M[p] = M[p], M[c]
    for r = 1, n do
      if r ~= c then
        local f = M[r][c] / M[c][c]
        for j = c, n + 1 do M[r][j] = M[r][j] - f * M[c][j] end
      end
    end
  end
  local x = {}
  for i = 1, n do x[i] = M[i][n + 1] / M[i][i] end
  return x
end

local function inverse(A)
  local n = #A
  local inv = {}
  for i = 1, n do inv[i] = {} end
  for j = 1, n do
    local e = {}
    for i = 1, n do e[i] = (i == j) and 1 or 0 end
    local col = solve(A, e)
    if not col then return nil end
    for i = 1, n do inv[i][j] = col[i] end
  end
  return inv
end

-- Weighted least squares of per-dose means on basis functions (weights = n per dose).
local function wls(points, basis)
  local p = #basis(points[1].dose)  -- a dose may be a number or a pair {a, b}
  local A, b = {}, {}
  for i = 1, p do A[i] = {}; b[i] = 0; for j = 1, p do A[i][j] = 0 end end
  for _, pt in ipairs(points) do
    local x = basis(pt.dose)
    for i = 1, p do
      b[i] = b[i] + pt.n * x[i] * pt.mean
      for j = 1, p do A[i][j] = A[i][j] + pt.n * x[i] * x[j] end
    end
  end
  local coef = solve(A, b)
  if not coef then return nil end
  local lof = 0
  for _, pt in ipairs(points) do
    local x, fit = basis(pt.dose), 0
    for i = 1, p do fit = fit + coef[i] * x[i] end
    lof = lof + pt.n * (pt.mean - fit) ^ 2
  end
  return {coef = coef, A = A, lof_ss = lof, basis = basis}
end

local function predict(fit, d)
  local x, y = fit.basis(d), 0
  for i = 1, #x do y = y + fit.coef[i] * x[i] end
  return y
end

local builders = {
  linear = function(points) return wls(points, function(d) return {1, d} end) end,
  quadratic = function(points) return wls(points, function(d) return {1, d, d * d} end) end,
  -- Nonlinear parameters are profiled on a grid: the best-fitting scale or step position.
  saturating = function(points, max_dose)
    local best
    for i = 1, 24 do
      local tau = 0.25 * i * max_dose / regress.max_dose
      local f = wls(points, function(d) return {1, 1 - math.exp(-d / tau)} end)
      if f and (not best or f.lof_ss < best.lof_ss) then best = f; best.tau = tau end
    end
    return best
  end,
  threshold = function(points)
    -- Candidate steps: at each tested dose (a step between two tested doses fits identically).
    local best
    for _, pt in ipairs(points) do
      local at = pt.dose
      local f = at > 0 and wls(points, function(d) return {1, d >= at and 1 or 0} end)
      if f and (not best or f.lof_ss < best.lof_ss) then best = f; best.at = at end
    end
    return best
  end,
  -- Cliff (0.59): a saturating rise and a steep fall (a logistic over about
  -- a dose, as the world's cliffs fall; a hard step failed lack of fit at the dose where they fall). The
  -- rise's scale and the fall's position are profiled; a fall that goes up is not a cliff.
  cliff = function(points, max_dose)
    local best
    local unit = max_dose / regress.max_dose
    for i = 1, 24 do
      local tau = 0.25 * i * unit
      for j = 10, 85 do
        local at = j / 10 * unit
        local f = wls(points, function(d)
          return {1, 1 - math.exp(-d / tau), 1 / (1 + math.exp(-4 * (d / unit - at / unit)))}
        end)
        if f and f.coef[3] < 0 and (not best or f.lof_ss < best.lof_ss) then best = f; best.tau = tau; best.at = at end
      end
    end
    return best
  end,
}

-- points: array of {dose, n, mean, ss} where ss is the within-dose sum of squares.
-- Returns nil with a reason, or a fit: model, coef, curve(d), r2, sigma, lof_p, optimum info.
function regress.fit(points, model, max_dose)
  max_dose = max_dose or regress.max_dose
  local p = regress.params[model]
  local used, N, pure_ss = {}, 0, 0
  for _, pt in ipairs(points) do
    if pt.n > 0 then
      table.insert(used, pt)
      N = N + pt.n
      pure_ss = pure_ss + math.max(pt.ss or 0, 0)
    end
  end
  -- A model needs as many doses as parameters to be fitted. Testing whether it fits needs more;
  -- that is reported (lof_exact), not enforced: the player may fit what they like.
  if #used < p then return nil, "need-doses" end
  local f = builders[model](used, max_dose)
  if not f then return nil, "singular" end

  local grand = 0
  for _, pt in ipairs(used) do grand = grand + pt.n * pt.mean end
  grand = grand / N
  local between = 0
  for _, pt in ipairs(used) do between = between + pt.n * (pt.mean - grand) ^ 2 end
  local sse = pure_ss + f.lof_ss
  local df = N - p
  local out = {model = model, coef = f.coef, tau = f.tau, at = f.at, n = N, doses = #used, sse = sse, df = df,
               cliff_at = model == "cliff" and f.at or nil,
               r2 = (pure_ss + between) > 0 and 1 - sse / (pure_ss + between) or nil,
               sigma = df > 0 and math.sqrt(sse / df) or nil}
  out.curve = function(d) return predict(f, d) end

  -- Lack of fit: does the model miss the per-dose means by more than replicate scatter explains?
  local df_lof, df_pe = #used - p, N - #used
  out.lof_exact = df_lof == 0  -- the curve passes through every dose mean: nothing to test it against
  if df_lof > 0 and df_pe > 0 and pure_ss > 0 then
    local F = (f.lof_ss / df_lof) / (pure_ss / df_pe)
    out.lof_F = F
    out.lof_p = stats.f_upper(F, df_lof, df_pe)
  end

  -- Where the fitted curve is highest on [0, max_dose].
  local best_d, best_y = 0, predict(f, 0)
  for i = 1, 180 do
    local d = i * max_dose / 180
    local y = predict(f, d)
    if y > best_y then best_d, best_y = d, y end
  end
  -- A cliff: the best tested dose before the collapse (the fitted curve peaks just short of the step).
  if model == "cliff" then
    best_d, best_y = 0, predict(f, 0)
    for _, pt in ipairs(used) do
      if pt.dose < f.at and predict(f, pt.dose) > best_y then best_d, best_y = pt.dose, predict(f, pt.dose) end
    end
  end
  out.best_dose, out.best_gain = best_d, best_y

  -- Interior optimum of a quadratic, with a delta-method CI.
  if model == "quadratic" and f.coef[3] < 0 and df > 0 then
    local b, c = f.coef[2], f.coef[3]
    local d_star = -b / (2 * c)
    local cov = inverse(f.A)
    if cov and d_star > 0 and d_star < max_dose then
      local s2 = sse / df
      local g = {0, -1 / (2 * c), b / (2 * c * c)}
      local var = 0
      for i = 1, 3 do for j = 1, 3 do var = var + g[i] * g[j] * cov[i][j] * s2 end end
      local half = stats.t_crit(df) * math.sqrt(math.max(var, 0))
      out.optimum = {dose = d_star, lo = d_star - half, hi = d_star + half, gain = predict(f, d_star)}
    end
  end
  return out
end

-- The automatic model: the simplest the data supports. A straight line, unless the
-- best-fitting three-parameter curve fits it clearly better (extra sum of squares F-test, p < 0.05).
function regress.auto(points, max_dose)
  local line, why = regress.fit(points, "linear", max_dose)
  if not line then return nil, why end
  local curve
  for _, model in ipairs(regress.models) do
    if regress.params[model] == 3 then  -- (the cliff is tested on top, below)
      local f = regress.fit(points, model, max_dose)
      if f and f.df > 0 and (not curve or f.sse < curve.sse) then curve = f end
    end
  end
  local chosen = line
  if curve and curve.sse > 0 and line.sse > curve.sse then
    local F = (line.sse - curve.sse) / (curve.sse / curve.df)
    if stats.f_upper(F, 1, curve.df) < 0.05 then chosen = curve end
  end
  -- A cliff (one more parameter) when it fits clearly better than what was chosen (0.59).
  local cliff = regress.fit(points, "cliff", max_dose)
  if cliff and cliff.df > 0 and cliff.sse > 0 and chosen.sse > cliff.sse then
    local extra = regress.params.cliff - regress.params[chosen.model]
    local F = ((chosen.sse - cliff.sse) / extra) / (cliff.sse / cliff.df)
    if stats.f_upper(F, extra, cliff.df) < 0.05 then chosen = cliff end
  end
  chosen.auto = true
  return chosen
end

-- Response surface over two doses: quadratic in (a, b) with an interaction term, 6 parameters.
-- points: {a, b, n, mean, ss}. The optimum is searched only within the tested range of each dose:
-- a fitted surface says nothing reliable outside the data.
regress.surface_params = 6

function regress.fit_surface(points)
  local p = regress.surface_params
  local used, N, pure_ss, max_a, max_b = {}, 0, 0, 0, 0
  for _, pt in ipairs(points) do
    if pt.n > 0 then
      table.insert(used, {dose = {pt.a, pt.b}, n = pt.n, mean = pt.mean})
      N = N + pt.n
      pure_ss = pure_ss + math.max(pt.ss or 0, 0)
      max_a, max_b = math.max(max_a, pt.a), math.max(max_b, pt.b)
    end
  end
  if #used < p then return nil, "need-points" end
  local f = wls(used, function(d) return {1, d[1], d[2], d[1] * d[1], d[2] * d[2], d[1] * d[2]} end)
  if not f then return nil, "singular" end
  local grand = 0
  for _, pt in ipairs(used) do grand = grand + pt.n * pt.mean end
  grand = grand / N
  local between = 0
  for _, pt in ipairs(used) do between = between + pt.n * (pt.mean - grand) ^ 2 end
  local sse = pure_ss + f.lof_ss
  local out = {coef = f.coef, n = N, points = #used, max_a = max_a, max_b = max_b,
               r2 = (pure_ss + between) > 0 and 1 - sse / (pure_ss + between) or nil,
               lof_exact = #used == p}
  out.surface = function(a, b) return predict(f, {a, b}) end
  local df_lof, df_pe = #used - p, N - #used
  if df_lof > 0 and df_pe > 0 and pure_ss > 0 then
    out.lof_p = stats.f_upper((f.lof_ss / df_lof) / (pure_ss / df_pe), df_lof, df_pe)
  end
  local best_a, best_b, best_y = 0, 0, predict(f, {0, 0})
  for i = 0, 30 do
    for j = 0, 30 do
      local a, b = max_a * i / 30, max_b * j / 30
      local y = predict(f, {a, b})
      if y > best_y then best_a, best_b, best_y = a, b, y end
    end
  end
  out.best = {a = best_a, b = best_b, gain = best_y}
  return out
end

-- Interaction of a mixture of two additives from the 2x2 factorial contrast:
-- mean(A+B) - mean(A) - mean(B) + mean(control), with a Welch-Satterthwaite CI. Summaries from
-- stats.summary; nil unless all four have variance.
function regress.interaction(ab, a, b, control)
  local groups = {ab, a, b, control}
  local se2, denom = 0, 0
  -- By index, not ipairs: a missing group (never tested) is a nil hole that ipairs would stop at.
  for i = 1, 4 do
    local s = groups[i]
    if not (s and s.var and s.n > 1) then return nil end
    se2 = se2 + s.var / s.n
    denom = denom + (s.var / s.n) ^ 2 / (s.n - 1)
  end
  local est = ab.mean - a.mean - b.mean + control.mean
  if se2 == 0 then return {estimate = est, lo = est, hi = est} end
  local df = se2 * se2 / denom
  local half = stats.t_crit(df) * math.sqrt(se2)
  return {estimate = est, lo = est - half, hi = est + half, p = stats.p_two(math.abs(est) / math.sqrt(se2), df)}
end

-- A response over temperature (0.53, the temperature view): a bell over a baseline, as the hidden
-- world's (y = c + A exp(-((T - T0) / w)^2), A > 0), fitted to band means weighted by their standard
-- errors. T0 on a half-degree grid, w on a coarse one (the width is the world's; not known to the
-- player); the interval for T0 by profile likelihood (chi-square within 3.84 of its minimum). A
-- quadratic put the best temperature within a band of the truth on 44% of worlds, this on 98%
-- (docs/balance.md, The temperature view). points: {{temp, mean, se}}; nil with fewer than three.
-- Bell widths tried (0.61: far best temperatures are broad, up to about 190 degrees).
regress.temp_widths = {10, 15, 20, 25, 30, 35, 40, 60, 90, 130, 190}
function regress.fit_temperature(points, lo_t, hi_t)
  local used = {}
  for _, p in ipairs(points) do if p.se and p.se > 0 then table.insert(used, p) end end
  if #used < 3 then return nil end
  local best, profile = nil, {}
  for t0 = lo_t, hi_t + 1e-9, 0.5 do
    local pbest
    for _, w in ipairs(regress.temp_widths) do
      local s00, s01, s11, b0, b1 = 0, 0, 0, 0, 0
      for _, p in ipairs(used) do
        local g, wt = math.exp(-((p.temp - t0) / w) ^ 2), 1 / p.se ^ 2
        s00, s01, s11 = s00 + wt, s01 + wt * g, s11 + wt * g * g
        b0, b1 = b0 + wt * p.mean, b1 + wt * g * p.mean
      end
      local det = s00 * s11 - s01 * s01
      if math.abs(det) > 1e-12 then
        local c = (s11 * b0 - s01 * b1) / det
        local A = (s00 * b1 - s01 * b0) / det
        if A > 0 then
          local chi = 0
          for _, p in ipairs(used) do
            chi = chi + ((p.mean - c - A * math.exp(-((p.temp - t0) / w) ^ 2)) / p.se) ^ 2
          end
          if not pbest or chi < pbest.chi then pbest = {chi = chi, t0 = t0, w = w, c = c, A = A} end
        end
      end
    end
    if pbest then
      table.insert(profile, pbest)
      if not best or pbest.chi < best.chi then best = pbest end
    end
  end
  if not best then return nil end
  local lo, hi = best.t0, best.t0
  for _, p in ipairs(profile) do
    if p.chi <= best.chi + 3.84 then lo, hi = math.min(lo, p.t0), math.max(hi, p.t0) end
  end
  local b = best
  return {temp = b.t0, lo = lo, hi = hi, gain = b.c + b.A, width = b.w,
    curve = function(t) return b.c + b.A * math.exp(-((t - b.t0) / b.w) ^ 2) end}
end

return regress
