-- Small-sample statistics: Student t via the regularized incomplete beta function.
local stats = {}

local lanczos = {0.99999999999980993, 676.5203681218851, -1259.1392167224028,
  771.32342877765313, -176.61502916214059, 12.507343278686905,
  -0.13857109526572012, 9.9843695780195716e-6, 1.5056327351493116e-7}

local function lgamma(x)
  if x < 0.5 then
    return math.log(math.pi / math.abs(math.sin(math.pi * x))) - lgamma(1 - x)
  end
  x = x - 1
  local a, t = lanczos[1], x + 7.5
  for i = 1, 8 do a = a + lanczos[i + 1] / (x + i) end
  return 0.5 * math.log(2 * math.pi) + (x + 0.5) * math.log(t) - t + math.log(a)
end

-- Continued fraction for the incomplete beta function (Numerical Recipes betacf).
local function betacf(a, b, x)
  local tiny = 1e-300
  local qab, qap, qam = a + b, a + 1, a - 1
  local c, d = 1, 1 - qab * x / qap
  if math.abs(d) < tiny then d = tiny end
  d = 1 / d
  local h = d
  for m = 1, 300 do
    local m2 = 2 * m
    local aa = m * (b - m) * x / ((qam + m2) * (a + m2))
    d = 1 + aa * d; if math.abs(d) < tiny then d = tiny end
    c = 1 + aa / c; if math.abs(c) < tiny then c = tiny end
    d = 1 / d; h = h * d * c
    aa = -(a + m) * (qab + m) * x / ((a + m2) * (qap + m2))
    d = 1 + aa * d; if math.abs(d) < tiny then d = tiny end
    c = 1 + aa / c; if math.abs(c) < tiny then c = tiny end
    d = 1 / d
    local del = d * c
    h = h * del
    if math.abs(del - 1) < 3e-14 then break end
  end
  return h
end

local function betai(a, b, x)
  if x <= 0 then return 0 end
  if x >= 1 then return 1 end
  local bt = math.exp(lgamma(a + b) - lgamma(a) - lgamma(b) + a * math.log(x) + b * math.log(1 - x))
  if x < (a + 1) / (a + b + 2) then return bt * betacf(a, b, x) / a end
  return 1 - bt * betacf(b, a, 1 - x) / b
end

-- Two-sided p-value of Student's t with df degrees of freedom.
function stats.p_two(t, df)
  return betai(df / 2, 0.5, df / (df + t * t))
end

-- Upper tail of the F distribution: P(F > f) with (d1, d2) degrees of freedom.
function stats.f_upper(f, d1, d2)
  if f <= 0 then return 1 end
  return betai(d2 / 2, d1 / 2, d2 / (d2 + d1 * f))
end

-- Quantile t such that p_two(t, df) = alpha, by bisection. Cached per df.
local quantile_cache = {}
function stats.t_crit(df, alpha)
  alpha = alpha or 0.05
  local key = df .. ":" .. alpha
  if quantile_cache[key] then return quantile_cache[key] end
  local lo, hi = 0, 1000
  for _ = 1, 100 do
    local mid = (lo + hi) / 2
    if stats.p_two(mid, df) > alpha then lo = mid else hi = mid end
  end
  quantile_cache[key] = (lo + hi) / 2
  return quantile_cache[key]
end

-- Summary of an accumulator {n, sum, sumsq}: mean, variance, 95% CI half-width.
function stats.summary(acc)
  local n = acc.n
  if n == 0 then return nil end
  local mean = acc.sum / n
  if n < 2 then return {n = n, mean = mean} end
  local var = math.max(0, (acc.sumsq - n * mean * mean) / (n - 1))
  local half = stats.t_crit(n - 1) * math.sqrt(var / n)
  return {n = n, mean = mean, var = var, half = half, lo = mean - half, hi = mean + half}
end

-- Welch's t-test between two summaries. Returns the two-sided p, or nil if undefined.
function stats.welch(a, b)
  if not (a and b and a.var and b.var) then return nil end
  local sa, sb = a.var / a.n, b.var / b.n
  local se2 = sa + sb
  if se2 == 0 then return (a.mean == b.mean) and 1 or 0 end
  local t = (a.mean - b.mean) / math.sqrt(se2)
  local df = se2 * se2 / (sa * sa / (a.n - 1) + sb * sb / (b.n - 1))
  return stats.p_two(math.abs(t), df)
end

-- Wilson score interval for a proportion k of n (95% by default): better than the normal interval at
-- the small proportions quality agents give. Returns the estimate, low and high.
function stats.wilson(k, n, z)
  if n <= 0 then return nil end
  z = z or 1.96
  local p = k / n
  local denom = 1 + z * z / n
  local centre = (p + z * z / (2 * n)) / denom
  local half = z * math.sqrt(p * (1 - p) / n + z * z / (4 * n * n)) / denom
  return p, math.max(0, centre - half), math.min(1, centre + half)
end

function stats.add(acc, x)
  -- (0.72) Every reading passes here: the version tells research.index its indexes are stale.
  storage.evidence_version = (storage.evidence_version or 0) + 1
  acc.n = acc.n + 1
  acc.sum = acc.sum + x
  acc.sumsq = acc.sumsq + x * x
end

return stats
