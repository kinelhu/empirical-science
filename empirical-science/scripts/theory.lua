-- The Theory tab's instrument: a lawful model fitted to the force's own evidence,
-- never to the truth. gain(additive, target) = sum over classes of w_c(target) x a(family, c), with w the
-- target's process mix at unit length (as the hidden score is). One affinity per family and class, by
-- weighted least squares over every tested cell (weights 1 / (SE^2 + residual variance)), with a ridge
-- toward zero; the residual variance (quirks, members' spreads) is estimated from the fit.
local shared = require("shared")
local stats = require("scripts.stats")

local theory = {}

theory.PRIOR_SD = 150   -- per mille: the ridge, a family seen on one target gives a cautious answer
theory.Z = 1.96

local function solve(A, b)
  local n = #b
  local M = {}
  for i = 1, n do M[i] = {}; for j = 1, n do M[i][j] = A[i][j] end; M[i][n + 1] = b[i] end
  for c = 1, n do
    local p = c
    for r = c + 1, n do if math.abs(M[r][c]) > math.abs(M[p][c]) then p = r end end
    if math.abs(M[p][c]) < 1e-12 then return nil end
    M[c], M[p] = M[p], M[c]
    for r = 1, n do
      if r ~= c then
        local f = M[r][c] / M[c][c]
        for k = c, n + 1 do M[r][k] = M[r][k] - f * M[c][k] end
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
  for j = 1, n do
    local e = {}
    for i = 1, n do e[i] = i == j and 1 or 0 end
    local col = solve(A, e)
    if not col then return nil end
    for i = 1, n do inv[i] = inv[i] or {}; inv[i][j] = col[i] end
  end
  return inv
end

-- A target's process mix at unit length, in shared.process_classes order.
function theory.mix_of(target)
  local w, norm = {}, 0
  for i, c in ipairs(shared.process_classes) do
    w[i] = target.process and target.process[c] or 0
    norm = norm + w[i] * w[i]
  end
  norm = math.sqrt(math.max(norm, 1e-12))
  for i = 1, #w do w[i] = w[i] / norm end
  return w
end

-- The additives the instrument speaks about: tier 1, tier 2 and residues (not premixes, catalysts or
-- quality agents: their chemistry is their members' or none).
function theory.raw_additives()
  local list = {}
  for _, a in ipairs(shared.all_additives) do
    if not a.premix_of and not a.refined_from and not a.agent then table.insert(list, a) end
  end
  return list
end

-- Cells from a book's observations: {additive, target, gain, se} for each additive's best tested dose on
-- each base target (two samples or more on both sides).
function theory.cells(obs)
  local out = {}
  for _, t in ipairs(shared.targets) do
    local o = obs[t.key]
    local c = o and o.control and stats.summary(o.control)
    if c and c.n >= 2 and c.var then
      for _, a in ipairs(theory.raw_additives()) do
        local best
        for key, acc in pairs(o) do
          local name, d = key:match("^([^+:@]+):(%d+)$")
          if name == a.name and acc.n >= 2 then
            local s = stats.summary(acc)
            if s and s.var and (not best or s.mean > best.mean) then best = s end
          end
        end
        if best then
          table.insert(out, {additive = a.name, target = t.key, gain = best.mean - c.mean,
            se = math.sqrt(best.var / best.n + c.var / c.n)})
        end
      end
    end
  end
  return out
end

-- Fit: returns {families = {fam = {est = {..}, lo = {..}, hi = {..}, cells = n}}, tau2, predict = fn}
-- or nil when nothing has been tested.
function theory.fit(cells)
  if #cells == 0 then return nil end
  local fam_index, fams = {}, {}
  for _, cell in ipairs(cells) do
    local f = shared.mix_family(cell.additive)
    if not fam_index[f] then table.insert(fams, f); fam_index[f] = #fams end
  end
  local k = #shared.process_classes
  local p = #fams * k
  local mixes = {}
  for _, t in ipairs(shared.targets) do mixes[t.key] = theory.mix_of(t) end
  local function row(cell)
    local x = {}
    for j = 1, p do x[j] = 0 end
    local base = (fam_index[shared.mix_family(cell.additive)] - 1) * k
    for c = 1, k do x[base + c] = mixes[cell.target][c] end
    return x
  end
  local tau2, beta, V = 0, nil, nil
  for _ = 1, 3 do  -- weights depend on the residual variance, estimated from the fit before
    local A, b = {}, {}
    for i = 1, p do A[i] = {}; for j = 1, p do A[i][j] = i == j and 1 / theory.PRIOR_SD ^ 2 or 0 end; b[i] = 0 end
    for _, cell in ipairs(cells) do
      -- (A floor of half a per mille: readings are rounded to one, so two equal ones give a zero error
      -- and an infinite weight; 0.70, the GUI test's seeded speed cells showed "nan".)
      local x, wt = row(cell), 1 / math.max(cell.se ^ 2 + tau2, 0.25)
      for i = 1, p do
        if x[i] ~= 0 then
          b[i] = b[i] + wt * x[i] * cell.gain
          for j = 1, p do if x[j] ~= 0 then A[i][j] = A[i][j] + wt * x[i] * x[j] end end
        end
      end
    end
    V = inverse(A)
    if not V then return nil end
    beta = {}
    for i = 1, p do beta[i] = 0; for j = 1, p do beta[i] = beta[i] + V[i][j] * b[j] end end
    local excess, n = 0, 0
    for _, cell in ipairs(cells) do
      local x, yhat = row(cell), 0
      for j = 1, p do yhat = yhat + x[j] * beta[j] end
      excess, n = excess + (cell.gain - yhat) ^ 2 - cell.se ^ 2, n + 1
    end
    tau2 = n > p and math.max(0, excess / (n - p)) or tau2
  end
  -- The multiplier: Student's t on the residual's degrees of freedom (results minus parameters): with a
  -- few targets the residual variance is itself uncertain, and 1.96 covered the truth on 83% of cells.
  local df = math.max(1, #cells - p)
  local z = stats.t_crit(df)
  local out = {families = {}, tau2 = tau2, df = df}
  for f, i in pairs(fam_index) do
    local est, lo, hi = {}, {}, {}
    for c = 1, k do
      local j = (i - 1) * k + c
      local sd = math.sqrt(math.max(V[j][j], 0))
      est[c], lo[c], hi[c] = beta[j], beta[j] - z * sd, beta[j] + z * sd
    end
    out.families[f] = {est = est, lo = lo, hi = hi}
  end
  for _, cell in ipairs(cells) do
    local fam = out.families[shared.mix_family(cell.additive)]
    fam.cells = (fam.cells or 0) + 1
  end
  -- A predicted gain on (additive, target) and its 95% prediction interval, or nil for a family never seen.
  function out.predict(additive, target_key)
    local i = fam_index[shared.mix_family(additive)]
    if not i then return nil end
    local x = mixes[target_key]
    local yhat, var = 0, tau2
    for c = 1, k do
      local jc = (i - 1) * k + c
      yhat = yhat + x[c] * beta[jc]
      for d = 1, k do var = var + x[c] * V[jc][(i - 1) * k + d] * x[d] end
    end
    local half = z * math.sqrt(math.max(var, 0))
    return {gain = yhat, lo = yhat - half, hi = yhat + half}
  end
  return out
end

-- Every untested (additive, target) pair on base targets, predicted, best first.
function theory.untested(fit, cells)
  local tested = {}
  for _, cell in ipairs(cells) do tested[cell.additive .. "|" .. cell.target] = true end
  local out = {}
  for _, t in ipairs(shared.targets) do
    for _, a in ipairs(theory.raw_additives()) do
      if not tested[a.name .. "|" .. t.key] then
        local pr = fit.predict(a.name, t.key)
        if pr then table.insert(out, {additive = a.name, target = t.key, gain = pr.gain, lo = pr.lo, hi = pr.hi}) end
      end
    end
  end
  table.sort(out, function(x, y) return x.gain > y.gain end)
  return out
end

return theory
