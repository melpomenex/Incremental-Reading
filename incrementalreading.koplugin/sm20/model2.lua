-- M2 — classic SuperMemo SM-15 optimizer, ported 1:1 from sm20/model2.py
-- (FUN_00a65600 -> 00a651f0 -> 00a605a0 and the optimizer record behind
-- DAT_01135240). The optimizer is collection-wide; the item state is the
-- small per-item part.
--
-- Conceptual indices are 1..20 like the binary; Lua arrays are 1-based, so
-- `self.matrix[row][repetition]` here is `self.matrix[row-1][repetition-1]`
-- in the Python module.

local math = math
local num = require("sm20.num")

local model2 = {}

model2.TARGET_R = 0.9      -- [BIN] DAT_00a65950 family
model2.SCALE = 1000.0      -- [BIN] u16 fixed-point scale (_DAT_00a5ef60)
model2.MAX_CASES = 60000   -- [BIN] cell-case cap (FUN_00a5e8a0:54)

local TARGET_R = model2.TARGET_R
local SCALE = model2.SCALE
local MAX_CASES = model2.MAX_CASES

local function clamp(value, low, high)
  if value < low then return low end
  if value > high then return high end
  return value
end

local py_round = num.py_round

-- Round through the unsigned-word representation used by the record.
function model2._q(value, scale)
  scale = scale or SCALE
  return clamp(py_round(value * scale) + 0.0, 0.0, 65535.0) / scale
end

-- Round a double through Delphi's 6-byte Real48 format.
function model2._real48(value)
  if value == 0.0 then return 0.0 end
  local sign = -1.0
  if value > 0.0 then sign = 1.0 end
  local fraction, exponent = math.frexp(math.abs(value))
  exponent = exponent - 1
  local mantissa = py_round((fraction * 2.0 - 1.0) * 549755813888.0)  -- 2^39
  if mantissa == 549755813888 then
    mantissa = 0
    exponent = exponent + 1
  end
  if exponent + 129 <= 0 then
    return 0.0
  end
  if exponent + 129 >= 255 then
    error("value is outside the Real48 range")
  end
  return sign * math.ldexp(1.0 + mantissa / 549755813888.0, exponent)
end

-- FUN_0097bc90 / FUN_0097c2c0 weighted slope and intercept.
-- xs, ys, weights: equal-length arrays.
function model2._weighted_linear(xs, ys, weights, plus_one)
  local total, sum_ax, sum_ay, sum_xx, sum_xy = 0.0, 0.0, 0.0, 0.0, 0.0
  for i = 1, #xs do
    local w
    if plus_one then
      w = py_round(weights[i]) + 1.0
    else
      w = py_round(weights[i]) + 1e-5
    end
    local x, y = xs[i], ys[i]
    total = total + w
    sum_ax = sum_ax + x * w
    sum_ay = sum_ay + y * w
    sum_xx = sum_xx + x * x * w
    sum_xy = sum_xy + x * y * w
  end
  local mean_x = sum_ax / total
  local mean_y = sum_ay / total
  local variance = sum_xx / total - mean_x * mean_x
  if variance == 0.0 then
    return 0.0, mean_y
  end
  local covariance = sum_xy / total - mean_x * mean_y
  local slope = covariance / variance
  return slope, mean_y - mean_x * slope
end

-- FUN_0097ba30 / FUN_0097c6d0 least-squares slope (optional fixed intercept).
function model2._fixed_intercept_slope(xs, ys, weights, intercept)
  intercept = intercept or 0.0
  local denominator = 0.0
  local numerator = 0.0
  for i = 1, #xs do
    local a, w = xs[i], weights[i]
    denominator = denominator + a * a * w
    numerator = numerator + a * w * (ys[i] - intercept)
  end
  if denominator == 0.0 then
    return 0.0
  end
  return numerator / denominator
end

-- FUN_00a610d0: 1.2, 1.5, ..., 6.9.
function model2.a_axis(index)
  return 1.2 + 0.3 * (index - 1)
end

-- FUN_00a612c0: A-factor to a 1..20 row.
function model2.a_bucket(a_factor)
  local value = clamp(a_factor + 1e-6, 1.2, 10.0)
  return math.min(20, math.floor((value - 1.2) / 0.3) + 1)
end

-- FUN_00a5fdc0: value represented by a 1..20 U-factor bin.
function model2.u_value(a_index, repetition_index, bin_index)
  if repetition_index == 1 then
    return bin_index + 0.0
  end
  return bin_index * (math.floor(model2.a_axis(a_index)) / 20.0) + 1.0
end

-- FUN_00a5df30: observed U-factor to a 1..20 bin.
function model2.u_bucket(a_index, repetition_index, value)
  local low = model2.u_value(a_index, repetition_index, 1)
  local high = model2.u_value(a_index, repetition_index, 20)
  if high == low then
    return 1
  end
  local bounded = clamp(value, low, high)
  return math.min(20, py_round(((bounded - low) / (high - low)) * 19.0) + 1)
end

-- FUN_00a5d5e0, used by FUN_00a64fb0 for a new collection.
function model2.fresh_optimum(a_index, repetition_index)
  local axis = model2.a_axis(a_index)
  if repetition_index == 1 then
    return math.exp(-0.057 * (a_index - 1) + 0.91)
  end
  if repetition_index == 2 then
    return axis
  end
  return (axis - 1.2) / (repetition_index - 1) + 1.2
end

function model2.new_item_state()
  return {
    last_review_day = -1,
    previous_interval = 0,
    repetitions = 0,
    lapses = 0,
    a_factor = 3.0,
    u_factor = 1.0,
  }
end

-- ---------------------------------------------------------------------------
-- ClassicM2Optimizer — the 0x49bc-byte collection optimizer
-- ---------------------------------------------------------------------------

local ClassicM2Optimizer = {}
ClassicM2Optimizer.__index = ClassicM2Optimizer
model2.ClassicM2Optimizer = ClassicM2Optimizer

local function deep_copy(v)
  if type(v) ~= "table" then return v end
  local out = {}
  for k, x in pairs(v) do out[k] = deep_copy(x) end
  return out
end

function ClassicM2Optimizer.new()
  local self = setmetatable({}, ClassicM2Optimizer)
  -- +0x000: generated optimum-factor matrix
  self.matrix = {}
  for a = 1, 20 do
    local row = {}
    for r = 1, 20 do
      row[r] = model2._q(model2.fresh_optimum(a, r))
    end
    self.matrix[a] = row
  end
  -- +0x2f6: empirical optimum factors and +0x616: their case counts
  self.empirical = deep_copy(self.matrix)
  self.cell_cases = {}
  for a = 1, 20 do
    local row = {}
    for r = 1, 20 do row[r] = 0 end
    self.cell_cases[a] = row
  end
  -- +0x807 / +0x2747: remembered and total observations by U bin
  self.remembered = {}
  self.observed = {}
  for a = 1, 20 do
    local rem_row, obs_row = {}, {}
    for r = 1, 20 do
      local rem_cell, obs_cell = {}, {}
      for b = 1, 20 do rem_cell[b] = 0; obs_cell[b] = 0 end
      rem_row[r] = rem_cell
      obs_row[r] = obs_cell
    end
    self.remembered[a] = rem_row
    self.observed[a] = obs_row
  end
  -- +0x95c / +0x982: per-row decay exponent and regression weight
  self.row_exponent = {}
  self.row_weight = {}
  for i = 1, 20 do self.row_exponent[i] = 1.0; self.row_weight[i] = 1 end
  -- +0x4826 / +0x48a2: grade graph used to infer an A-factor
  self.first_grade = {}
  for i = 1, 20 do
    self.first_grade[i] = model2._real48(clamp(
      5.2 - math.exp(-0.67 * model2.a_axis(i) + 2.4), 0.0, 5.0))
  end
  self.first_grade_cases = {}
  for i = 1, 20 do self.first_grade_cases[i] = 1 end
  -- +0x48c6 / +0x497e: grade by forgetting-index graph
  local second_defaults = {
    4.8, 4.7, 4.6, 4.5, 4.4, 4.3, 4.2, 4.1, 4.0,
    3.95, 3.9, 3.8, 3.74, 3.65, 3.55, 3.48, 3.39, 3.3,
  }
  self.second_grade = {}
  for i = 1, 18 do self.second_grade[i] = model2._real48(second_defaults[i]) end
  self.second_grade_cases = {}
  for i = 1, 18 do self.second_grade_cases[i] = 1 end
  return self
end

function ClassicM2Optimizer:clone()
  local copy = setmetatable({}, ClassicM2Optimizer)
  for k, v in pairs(self) do copy[k] = deep_copy(v) end
  return copy
end

function ClassicM2Optimizer:to_dict()
  return deep_copy({
    matrix = self.matrix,
    empirical = self.empirical,
    cell_cases = self.cell_cases,
    remembered = self.remembered,
    observed = self.observed,
    row_exponent = self.row_exponent,
    row_weight = self.row_weight,
    first_grade = self.first_grade,
    first_grade_cases = self.first_grade_cases,
    second_grade = self.second_grade,
    second_grade_cases = self.second_grade_cases,
  })
end

function ClassicM2Optimizer:from_dict(data)
  local obj = ClassicM2Optimizer.new()
  obj.matrix = deep_copy(data.matrix)
  obj.empirical = deep_copy(data.empirical)
  obj.cell_cases = deep_copy(data.cell_cases)
  obj.remembered = deep_copy(data.remembered)
  obj.observed = deep_copy(data.observed)
  obj.row_exponent = deep_copy(data.row_exponent)
  obj.row_weight = deep_copy(data.row_weight)
  obj.first_grade = deep_copy(data.first_grade)
  obj.first_grade_cases = deep_copy(data.first_grade_cases)
  obj.second_grade = deep_copy(data.second_grade)
  obj.second_grade_cases = deep_copy(data.second_grade_cases)
  obj:validate()
  return obj
end

function ClassicM2Optimizer:validate()
  local function check_len(t, n, name)
    assert(#t == n, name .. " has wrong length " .. tostring(#t))
  end
  check_len(self.matrix, 20, "matrix")
  check_len(self.empirical, 20, "empirical")
  check_len(self.cell_cases, 20, "cell_cases")
  for i = 1, 20 do
    check_len(self.matrix[i], 20, "matrix row")
    check_len(self.empirical[i], 20, "empirical row")
    check_len(self.cell_cases[i], 20, "cell_cases row")
  end
  check_len(self.remembered, 20, "remembered")
  check_len(self.observed, 20, "observed")
  for a = 1, 20 do
    check_len(self.remembered[a], 20, "remembered row")
    check_len(self.observed[a], 20, "observed row")
    for r = 1, 20 do
      check_len(self.remembered[a][r], 20, "remembered cell")
      check_len(self.observed[a][r], 20, "observed cell")
    end
  end
  check_len(self.first_grade, 20, "first_grade")
  check_len(self.second_grade, 18, "second_grade")
end

-- FUN_00a5e650: interpolate a generated matrix row.
function ClassicM2Optimizer:interpolate(row, repetition_stage)
  local stage = math.min(20.0, repetition_stage)
  local lower = math.max(1, math.min(20, math.floor(stage)))
  local upper = math.min(20, lower + 1)
  local left = self.matrix[row][lower]
  local right = self.matrix[row][upper]
  return left + (stage - lower) * (right - left)
end

-- FUN_00a600b0: map an interval onto the current matrix row.
function ClassicM2Optimizer:repetition_stage(used_interval, a_factor)
  local previous = self.matrix[1][1]
  local current = previous
  local stage = 2
  local row = model2.a_bucket(a_factor)
  while current < used_interval and stage < 20 do
    previous = current
    current = current * self.matrix[row][stage]
    stage = stage + 1
  end
  local result
  if stage < 3 or current == previous then
    result = 1.0
  else
    result = (stage - 2) + (used_interval - previous) / (current - previous)
  end
  return clamp(result, 2.0, 20.0)
end

-- FUN_00a5e140: fit log(recall) against the U-factor bins.
function ClassicM2Optimizer:_forgetting_rate(row, repetition)
  if self.cell_cases[row][repetition] == 0 then
    return -math.log(TARGET_R) / self.empirical[row][repetition]
  end
  local xs, ys, weights = {}, {}, {}
  for bin_index = 1, 20 do
    local total = self.observed[row][repetition][bin_index]
    local success = self.remembered[row][repetition][bin_index]
    xs[#xs + 1] = model2.u_value(row, repetition, bin_index)
    weights[#weights + 1] = total + 0.0
    if total <= 0 then
      ys[#ys + 1] = 0.0
    elseif success <= 0 then
      ys[#ys + 1] = -3.0
    else
      ys[#ys + 1] = math.max(-3.0, math.log(success / total))
    end
  end
  -- The stored parameter is the positive decay rate in exp(-rate * U).
  return -model2._fixed_intercept_slope(xs, ys, weights)
end

-- FUN_00a5eff0: rebuild the generated matrix from empirical data.
function ClassicM2Optimizer:_rebuild()
  -- FUN_00a5ee40: regress the first column over A rows.
  local xs, ys, weights = {}, {}, {}
  for i = 1, 20 do
    xs[i] = i - 1.0
    ys[i] = math.log(math.max(self.empirical[i][1], 1e-300))
    weights[i] = self.cell_cases[i][1] + 1
  end
  local slope, intercept = model2._weighted_linear(xs, ys, weights, true)
  for i = 1, 20 do
    self.matrix[i][1] = model2._q(clamp(
      math.exp(slope * (i - 1) + intercept), 1.0, 20.0))
  end

  -- FUN_00a5d770: fit each A row's power-decay exponent.
  for row = 2, 20 do
    local rxs, rys, rws = {}, {}, {}
    for repetition = 3, 20 do
      rxs[#rxs + 1] = math.log(repetition - 1.0)
      local optimum = self.empirical[row][repetition]
      local transformed
      if optimum <= 1.21 then
        transformed = -10000.0
      else
        transformed = math.log(optimum - 1.2)
      end
      rys[#rys + 1] = clamp(transformed, -4.0, 4.0)
      rws[#rws + 1] = self.cell_cases[row][repetition] + 0.0
    end
    local any_positive = false
    for _, w in ipairs(rws) do
      if w > 0 then any_positive = true break end
    end
    if not any_positive then
      rws[#rws] = 1.0
    end
    local fixed_intercept = math.log(model2.a_axis(row) - 1.2)
    local exponent = clamp(
      -model2._fixed_intercept_slope(rxs, rys, rws, fixed_intercept), 0.0, 3.0)
    self.row_exponent[row] = py_round(exponent * 10000.0) / 10000.0
    local weight_sum = 0
    for _, w in ipairs(rws) do weight_sum = weight_sum + py_round(w) end
    self.row_weight[row] = math.min(MAX_CASES, weight_sum)
  end

  -- FUN_00a64350: smooth the row exponents with a weighted line.
  local xs, ys, ws = { 1.2 }, { 1.0 }, { 1 }
  for _, i in ipairs({ 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20 }) do
    xs[#xs + 1] = model2.a_axis(i)
    ys[#ys + 1] = self.row_exponent[i]
    ws[#ws + 1] = self.row_weight[i]
  end
  local decay_slope, decay_intercept = model2._weighted_linear(xs, ys, ws, false)
  if decay_slope < -0.5 or decay_slope > 0.5 then
    local anchor = decay_slope * 3.6 + decay_intercept
    decay_slope = clamp(decay_slope, -0.5, 0.5)
    decay_intercept = anchor - decay_slope * 3.6
  end

  -- FUN_00a5dd20: fill columns 2..20 from the fitted decay curve.
  for row = 2, 20 do
    local axis = model2.a_axis(row)
    local exponent = clamp(decay_slope * axis + decay_intercept, 0.0, 3.0)
    for repetition = 2, 20 do
      local factor = (repetition - 1.0) ^ (-exponent)
      self.matrix[row][repetition] = model2._q(factor * (axis - 1.2) + 1.2)
    end
  end
end

-- FUN_00a67640: update one local optimizer cell and rebuild it (the rebuild
-- itself is invoked by the review orchestrator, once per review).
function ClassicM2Optimizer:_record(row, repetition, observed_u, remembered, rng)
  local bin_index = model2.u_bucket(row, repetition, observed_u)
  local rem = self.remembered[row][repetition]
  local obs = self.observed[row][repetition]

  -- At the capped U bin, a lapse can probabilistically count as remembered
  -- when it occurred beyond the represented range (the binary's tail fix).
  local effective_remembered = remembered
  if bin_index == 20 and not remembered then
    local rate = self:_forgetting_rate(row, repetition)
    local represented_r = math.exp(-rate * model2.u_value(row, repetition, 20))
    local actual_r = math.exp(-rate * observed_u)
    if rng:random() < represented_r - actual_r then
      effective_remembered = true
    end
  end

  if effective_remembered then
    rem[bin_index] = math.min(255, rem[bin_index] + 1)
  end
  obs[bin_index] = math.min(255, obs[bin_index] + 1)
  if obs[bin_index] > 250 then
    obs[bin_index] = math.floor(obs[bin_index] / 2)
    rem[bin_index] = math.floor(rem[bin_index] / 2)
  end
  self.cell_cases[row][repetition] = math.min(
    MAX_CASES, self.cell_cases[row][repetition] + 1)

  local rate = self:_forgetting_rate(row, repetition)
  local optimum
  if rate == 0.0 then
    optimum = model2.u_value(row, repetition, 20)
  else
    optimum = -math.log(TARGET_R) / rate
  end
  if repetition == 1 then
    optimum = clamp(optimum, 1.0, 20.0)
  else
    optimum = clamp(optimum, 1.2, model2.a_axis(row))
  end
  self.empirical[row][repetition] = model2._q(optimum)
end

-- FUN_00a63470: weighted-linear fit of log(second_grade) over FI 3..20. [C][BIN]
function ClassicM2Optimizer:_grade_fit()
  local xs, ys = {}, {}
  for i = 3, 20 do
    xs[#xs + 1] = i + 0.0
  end
  for _, value in ipairs(self.second_grade) do
    ys[#ys + 1] = math.max(-5.0, math.log(math.max(value, 1e-300)))
  end
  return model2._weighted_linear(xs, ys, self.second_grade_cases, true)
end

-- FUN_00a63f50: weighted-linear fit of log(5.2-first_grade) over a_axis. [C][BIN]
function ClassicM2Optimizer:_first_grade_fit()
  local xs, ys = {}, {}
  for i = 1, 20 do
    xs[i] = model2.a_axis(i)
    local v = self.first_grade[i]
    if v < 0.0 then v = 0.0 elseif v > 5.0 then v = 5.0 end
    ys[i] = math.log(math.max(5.2 - v, 1e-300))
  end
  local slope, intercept = model2._weighted_linear(xs, ys, self.first_grade_cases, true)
  return math.min(0.0, slope), intercept
end

-- FUN_00a615b0: exp(clamp(slope*fi+intercept)) clamped to [0.1, 5.0]. [C][BIN]
function model2._grade_at(value, slope, intercept)
  local x = slope * value + intercept
  if x > 38.0 then x = 38.0 end
  if x < -38.0 then x = -38.0 end
  return clamp(math.exp(x), 0.1, 5.0)
end

-- FUN_00a61740: invert the grade fit to a forgetting index. [C][BIN]
function model2._forgetting_index_for_grade(grade, slope, intercept)
  if slope == 0.0 then
    return 50.0  -- [BIN] fallback when slope==0
  end
  local value = (math.log(math.max(grade, 0.3)) - intercept) / slope
  return clamp(value, 0.2, 90.0)  -- [BIN] clamps
end

-- FUN_00a64880 (predicted-FI calculator). [C][BIN]
function ClassicM2Optimizer:_predicted_fi(old_repetitions, old_lapses, old_a,
                                          stage, observed_u)
  local optimum
  if old_repetitions == 1 then
    optimum = self.matrix[math.min(20, old_lapses + 1)][1]
  else
    optimum = self:interpolate(model2.a_bucket(old_a), stage)
  end
  local retrievability = math.exp((observed_u / optimum) * math.log(TARGET_R))
  return clamp((1.0 - retrievability) * 100.0, 0.1, 99.5)
end

-- FUN_00a62b70: invert the first-grade fit to an A-factor. [C][BIN]
function ClassicM2Optimizer:_a_from_first_grade(grade_value)
  local slope, intercept = self:_first_grade_fit()
  if slope == 0.0 then
    return 6.9
  end
  return clamp((math.log(5.2 - grade_value) - intercept) / slope, 1.2, 6.9)
end

-- FUN_00a63010 + FUN_00a62ce0. [C][BIN] Returns new_a, predicted_fi, fitted_grade.
function ClassicM2Optimizer:_new_a_factor(item, grade, used_interval,
                                          observed_u, stage)
  if item.repetitions == 0 then
    -- [BIN] _DAT_00a62f28=3.0, _DAT_00a62f20=0.3
    return (((grade - 4.0) * 0.3 + 3.0) * 0.6 + 0.4 * item.a_factor), 10.0, 4.0
  end

  local slope, intercept = self:_grade_fit()
  local predicted_fi = self:_predicted_fi(
    item.repetitions, item.lapses, item.a_factor, stage, observed_u)
  local inferred_fi = model2._forgetting_index_for_grade(grade + 0.0, slope, intercept)

  -- FUN_00a63010 computes fitted_grade (+0xf7) UNCONDITIONALLY from the four
  -- grade-at components (no early-return gate in the binary).
  local g10 = model2._grade_at(10.0, slope, intercept)
  local g_predicted = model2._grade_at(predicted_fi, slope, intercept)
  local c1 = model2._grade_at((inferred_fi / predicted_fi) * 10.0, slope, intercept)
  local c2 = model2._grade_at(inferred_fi + 10.0 - predicted_fi, slope, intercept)
  local c3 = grade * (g10 / g_predicted)
  local c4 = g10 + (grade - g_predicted)
  local fitted_grade = clamp((c1 + c2 + c3 + c4) * 0.25, 0.0, 5.0)
  if grade < 3 then
    fitted_grade = math.min(fitted_grade, 2.5)
  else
    fitted_grade = math.max(fitted_grade, 2.5)
  end

  -- FUN_00a62ce0 gate: compute unless BOTH fits are negative.
  if not (fitted_grade >= 0.0 and inferred_fi >= 0.0) then
    return item.a_factor, predicted_fi, grade + 0.0
  end

  local new_a
  if item.repetitions == 1 and item.lapses == 0 then
    new_a = 0.85 * self:_a_from_first_grade(fitted_grade) + 0.15 * item.a_factor
  elseif item.repetitions == 1 then
    new_a = 0.4 * (((grade - 4.0) * 0.3) + 3.0) + 0.6 * item.a_factor
  else
    local denominator = math.log(1.0 - inferred_fi / 100.0)
    local target_interval
    if denominator ~= 0.0 then
      target_interval = used_interval * math.log(TARGET_R) / denominator
    else
      target_interval = used_interval
    end
    local target_u = (target_interval / used_interval) * observed_u
    local row = 20
    while row > 0 and self:interpolate(row, stage) >= target_u do
      row = row - 1
    end
    local estimated_a = model2.a_axis(math.max(1, row))
    new_a = 0.4 * estimated_a + 0.6 * item.a_factor
  end
  return new_a, predicted_fi, fitted_grade
end

function ClassicM2Optimizer:_update_grade_graphs(new_a, predicted_fi, grade,
                                                old_repetitions, old_lapses)
  -- FUN_00a5e8a0: grade by forgetting-index graph.
  local index = math.min(18, math.max(1, py_round(predicted_fi)))
  self.second_grade_cases[index] = math.min(
    MAX_CASES, self.second_grade_cases[index] + 1)
  local count = self.second_grade_cases[index]
  local alpha = 1.0 / (10.0 * math.log(count + 2.0))
  self.second_grade[index] = model2._real48(
    self.second_grade[index] * (1.0 - alpha) + alpha * grade)

  -- FUN_00a639c0: first-grade graph; excludes a first clean repetition.
  if old_repetitions ~= 0
    and not (old_repetitions == 1 and old_lapses == 0)
    and grade < 6 then
    local row = model2.a_bucket(new_a)
    self.first_grade_cases[row] = math.min(
      MAX_CASES, self.first_grade_cases[row] + 1)
    local falpha
    if old_repetitions == 2 then falpha = 0.15 else falpha = 0.07 end
    self.first_grade[row] = model2._real48(clamp(
      (1.0 - falpha) * self.first_grade[row] + falpha * grade, 0.0, 5.0))
  end
end

-- FUN_00a60980: compensate when a review occurs before its due day.
-- Returns corrected_factor, adjusted_used.
function model2._correct_early_factor(factor, scheduled, used)
  if used >= scheduled then
    return factor, used
  end
  local difference = scheduled - used
  local previous = scheduled - 1.0
  local correction_scale = scheduled * 0.4
  local candidate = ((factor - 1.0) * (previous + correction_scale)) / previous
  local deduction = (candidate * difference) / (correction_scale + difference)
  local corrected = math.min(factor, factor - deduction)
  local adjusted_used = py_round((scheduled * corrected) / factor)
  return corrected, math.min(scheduled, math.max(used, adjusted_used))
end

-- Run the local equivalent of a65600 -> a651f0 -> a605a0.
-- opts: { forgetting_index = 10, commit = false, rng = nil }
-- rng: object with :random(); defaults to a fresh CPython Random(0), matching
-- the Python `rng or random.Random(0)`.
function ClassicM2Optimizer:review(item, today, grade, opts)
  opts = opts or {}
  local forgetting_index = opts.forgetting_index or 10
  local commit = opts.commit or false
  if grade < 0 or grade > 5 then
    error("grade must be in 0..5")
  end
  local work = commit and self or self:clone()
  local rng = opts.rng or num.CPythonRandom.new(0)
  local used = 0
  if item.last_review_day >= 0 then
    used = math.max(1, today - item.last_review_day)
  end
  local remembered = grade >= 3
  local new_repetitions, new_lapses
  if remembered then
    new_repetitions = math.min(20, item.repetitions + 1)
    new_lapses = math.min(19, item.lapses)
  else
    new_repetitions = 1
    if item.repetitions == 0 then
      new_lapses = 0
    else
      new_lapses = math.min(19, item.lapses + 1)
    end
  end

  local stage = 1.0
  local observed_u = item.u_factor
  if item.repetitions ~= 0 then
    local scheduled = math.max(1, item.previous_interval)
    used = math.max(1, used)
    observed_u = (used / scheduled) * item.u_factor
    stage = work:repetition_stage(used, item.a_factor)
    local row
    if item.repetitions == 1 then
      row = math.min(20, item.lapses + 1)
    else
      row = model2.a_bucket(item.a_factor)
    end
    local repetition
    if item.repetitions == 1 then
      repetition = 1
    else
      repetition = math.min(20, math.max(1, py_round(stage)))
    end
    work:_record(row, repetition, observed_u, remembered, rng)
    -- FUN_00a651f0:83 invokes the rebuild once per review after the record.
    work:_rebuild()
  end

  local new_a, predicted_fi = select(1, work:_new_a_factor(
    item, grade, math.max(1, used), observed_u, stage))

  local adjusted_used = math.max(1, used)
  local base
  if new_repetitions == 1 then
    base = work.matrix[math.min(20, new_lapses + 1)][1]
  else
    local factor = work:interpolate(model2.a_bucket(new_a), stage + 1.0)
    factor, adjusted_used = model2._correct_early_factor(
      factor, math.max(1, item.previous_interval), math.max(1, used))
    base = math.max(math.max(1, item.previous_interval), math.max(1, used)) * factor
  end

  local fi_factor = math.log(1.0 - forgetting_index / 100.0) / math.log(TARGET_R)
  local stability = math.max(1, py_round(base * fi_factor))
  local new_u
  if new_repetitions == 1 then
    new_u = stability + 0.0
  else
    new_u = math.max(1.0, stability / adjusted_used)
  end
  if item.repetitions ~= 0 then
    work:_update_grade_graphs(new_a, predicted_fi, grade, item.repetitions, item.lapses)
  end

  local next_item = {
    last_review_day = today,
    previous_interval = 0,
    repetitions = new_repetitions,
    lapses = new_lapses,
    a_factor = new_a,
    u_factor = new_u,
  }
  return {
    stability = stability,
    used_interval = used,
    adjusted_used_interval = adjusted_used,
    repetition_stage = stage,
    new_a_factor = new_a,
    new_u_factor = new_u,
    repetitions = new_repetitions,
    lapses = new_lapses,
    next_item = next_item,
  }
end

-- Convenience entry point for the reconstructed M2 model.
function model2.model_2(item, optimizer, today, grade, opts)
  return optimizer:review(item, today, grade, opts)
end

return model2
