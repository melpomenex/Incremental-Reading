-- M3 — SM-19/W3 raw legacy matrix scheduler, ported 1:1 from
-- sm20/model3.py (FUN_00cea5a0 and callees; the single biggest ensemble
-- contributor at 45%). See the Python module for the full [C]/[BIN] provenance.
--
-- Flat matrix arrays are 1-based Lua arrays; matrix_cell_offset / 
-- lapse_cell_offset return the Python 0-based offset, so every array access
-- adds 1 (matching the Python `list[offset]`).

local math = math
local num = require("sm20.num")

local model3 = {}

local py_round = num.py_round

-- --- constants [BIN] ---
model3.STABILITY_POW_DENOM = math.log(6000.0) / math.log(20.0)
model3.R_LN_MULT = 20.0
model3.R_IDX_MIN = 1
model3.R_IDX_MAX = 20
model3.S_SUBTRACT = 2.0
model3.S_FLOOR = 0.0
model3.S_POW_NUM = 1.0
model3.S_IDX_MAX = 20
model3.D_MIN = 0.0
model3.D_MAX = 1.0
model3.D_MULT = 19.0
model3.D_SENTINEL = 10
model3.DECAY_HI = 38.0
model3.DECAY_LO = -38.0
model3.COUNT_FLOOR = 0.0
model3.PRIOR_A = 0.64
model3.PRIOR_B = 0.3
model3.SINC_K = 3.5
model3.SINC_BASE = 1.0
model3.SI_175 = 175.0
model3.SI_100 = 100.0
model3.SI_K_PASS = 3.0
model3.SI_W_PASS = 100.0
model3.SI_K_DIFF = 333.0
model3.SI_W_DIFF = 1.25
model3.SI_K_FAIL = 1.0
model3.SI_W_FAIL = 200.0
model3.ROUND_NARROW_HI = 2.0
model3.ROUND_NARROW_LO = 0.5
model3.ROUND_WIDE_HI = 20.0
model3.ROUND_WIDE_LO = 0.8
model3.MU_K = 10.0
model3.MU_PRIOR_W = 1.0
model3.MU_POW_BASE = 1.8
model3.MU_MUL_EXP = -0.27
model3.MU_COEFF = 3.5
model3.MU_ADD = 0.6
model3.BP_HI = 15.0
model3.BP_LO = 3.0
model3.BP_MID = 1.0
model3.BP_POW_LO = -0.08
model3.BP_POW_HI = -0.35
model3.BP_LIN_M = -2.0
model3.BP_LIN_B = 2.25
model3.BP_CLAMP = 600.0
model3.BS_CAP = 1.0
model3.BS_K = 300.0
model3.BS_W = 10.0
model3.BS_FLOOR = 0.1
model3.R_VALID_LO = 0.005
model3.R_VALID_HI = 0.995
model3.S_VALID_LO = 0.7
model3.S_VALID_HI = 44530.0
model3.W3_WRONG_TH = 0.0
model3.CF_R_HI = 0.9999
model3.CF_R_LO = 0.1
model3.CF_RATIO_TH = 0.99
model3.CF_POW_EXP = 0.07
model3.CF_BASE = 0.9
model3.CF_YEAR = 365.0
model3.CF_W_HI = 100.0
model3.CF_W_LO = 50.0
model3.INTERVAL_AXIS_BASE = 1.4
model3.INTERVAL_AXIS_SHIFT = 12.5
model3.OUTCOME_CELLS = 21 * 21 * 21          -- 9261
model3.LAPSE_R_DIM = 20
model3.LAPSE_STAGE_DIM = 21
model3.LAPSE_INTERVAL_DIM = 36
model3.LAPSE_CELLS = 20 * 21 * 36            -- 15120
model3.AXIS_LOG_BASE = 20.0
model3.WLS_EPS = 1e-05
model3.MATRIX_DIM = 21

-- ---------------------------------------------------------------------------
-- helpers  [C]
-- ---------------------------------------------------------------------------

local function ln(x) return math.log(x) end
local function exp(x) return math.exp(x) end

local function pow_f(base, e)
  if base > 0.0 then
    return math.exp(e * math.log(base))
  end
  return 0.0
end

local function round_half_up(x)
  return py_round(x)
end

function model3.sigmoid_ratio(x, y)
  local s = x + y
  if s == 0.0 then return 0.0 end
  return x / s
end

local function sign_flip(v) return -v end

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- FUN_00f614b0: exp(clamp(x, -38, 38)). [C][BIN]
function model3.decay_transform(x)
  if x > model3.DECAY_HI then x = model3.DECAY_HI end
  if x < model3.DECAY_LO then x = model3.DECAY_LO end
  return exp(x)
end

-- FUN_00cf7640: clamp/repair retrievability to [0.005, 0.995]. [C][BIN]
function model3.clamp_R(R)
  if R <= -1.0 then return 0.995 end   -- NaN / invalid -> 0.995
  if R <= model3.R_VALID_LO then return 0.005 end
  if R >= model3.R_VALID_HI then return 0.995 end
  return R
end

-- FUN_00cf7550: clamp/repair stability to [0.7, 44530.0]. [C][BIN]
function model3.clamp_S(S)
  if S <= -1.0 then return 44530.0 end
  if S <= model3.S_VALID_LO then return 0.7 end
  if S >= model3.S_VALID_HI then return 44530.0 end
  return S
end

-- ---------------------------------------------------------------------------
-- index mappers  [C]
-- ---------------------------------------------------------------------------

-- FUN_00cf7250: R -> matrix index 1..20 = clamp(round(20**R)). [ASM][BIN]
function model3.r_index(R)
  if R < 0.0 then
    error("Retrievability not set in categorizing R")
  end
  local v = round_half_up(exp(R * ln(model3.R_LN_MULT)))
  if v > model3.R_IDX_MAX then v = model3.R_IDX_MAX end
  if v < model3.R_IDX_MIN then v = model3.R_IDX_MIN end
  return v
end

-- FUN_00cf7330: S -> matrix index 1..20. [C][BIN]
function model3.s_index(S)
  S = model3.clamp_S(S)
  local d = S - model3.S_SUBTRACT
  if d < model3.S_FLOOR then d = model3.S_FLOOR end
  local raw = pow_f(d, model3.S_POW_NUM / model3.STABILITY_POW_DENOM)
  local idx = round_half_up(raw) + 1
  if idx > model3.S_IDX_MAX then idx = model3.S_IDX_MAX end
  if idx == 0 then idx = 1 end
  return idx
end

-- FUN_00cf6fd0: D in [0,1] -> matrix index 1..20, else sentinel 10. [C][BIN]
function model3.d_index(D)
  if model3.D_MIN <= D and D <= model3.D_MAX then
    return round_half_up(D * model3.D_MULT) + 1
  end
  return model3.D_SENTINEL
end

-- ---------------------------------------------------------------------------
-- matrix state  [C]
-- ---------------------------------------------------------------------------

-- Linear offset into the 21^3 matrices (indices are 1-based, 1..20). [C]
function model3.matrix_cell_offset(rep_idx, stab_idx, diff_idx)
  return (rep_idx - 1) * 441 + (stab_idx - 1) * 21 + (diff_idx - 1)
end

-- Offset for the 20x21x36 pre-lapse outcome matrices.
function model3.lapse_cell_offset(r_idx, stage_idx, interval_idx)
  if not (1 <= r_idx and r_idx <= 20 and 1 <= stage_idx and stage_idx <= 20
      and 1 <= interval_idx and interval_idx <= 36) then
    error("lapse-matrix indices out of range")
  end
  return (r_idx - 1) * (model3.LAPSE_STAGE_DIM * model3.LAPSE_INTERVAL_DIM)
    + (stage_idx - 1) * model3.LAPSE_INTERVAL_DIM + (interval_idx - 1)
end

local M3_FIELDS = {
  "outcome_count", "outcome_success", "smoothing_count", "smoothing_value",
  "lapse_observed", "lapse_remembered",
  "first_stage_observed", "first_stage_remembered",
}

local M3MatrixState = {}
M3MatrixState.__index = M3MatrixState
model3.M3MatrixState = M3MatrixState

local function zero_array(n)
  local t = {}
  for i = 1, n do t[i] = 0 end
  return t
end

function model3.new_matrix_state()
  local self = setmetatable({}, M3MatrixState)
  self.outcome_count = zero_array(model3.OUTCOME_CELLS)
  self.outcome_success = zero_array(model3.OUTCOME_CELLS)
  self.smoothing_count = zero_array(model3.OUTCOME_CELLS)
  self.smoothing_value = zero_array(model3.OUTCOME_CELLS)
  self.lapse_observed = zero_array(model3.LAPSE_CELLS)
  self.lapse_remembered = zero_array(model3.LAPSE_CELLS)
  self.first_stage_observed = zero_array(model3.LAPSE_INTERVAL_DIM)
  self.first_stage_remembered = zero_array(model3.LAPSE_INTERVAL_DIM)
  return self
end

function M3MatrixState:validate()
  local expected = {
    outcome_count = model3.OUTCOME_CELLS,
    outcome_success = model3.OUTCOME_CELLS,
    smoothing_count = model3.OUTCOME_CELLS,
    smoothing_value = model3.OUTCOME_CELLS,
    lapse_observed = model3.LAPSE_CELLS,
    lapse_remembered = model3.LAPSE_CELLS,
    first_stage_observed = model3.LAPSE_INTERVAL_DIM,
    first_stage_remembered = model3.LAPSE_INTERVAL_DIM,
  }
  for name, size in pairs(expected) do
    assert(#self[name] == size, name .. " must contain " .. size .. " cells")
  end
end

function M3MatrixState:to_dict()
  local out = {}
  for _, name in ipairs(M3_FIELDS) do
    local copy = {}
    for i, v in ipairs(self[name]) do copy[i] = v end
    out[name] = copy
  end
  return out
end

function M3MatrixState:from_dict(data)
  local obj = model3.new_matrix_state()
  for _, name in ipairs(M3_FIELDS) do
    local copy = {}
    for i, v in ipairs(data[name]) do copy[i] = v end
    obj[name] = copy
  end
  obj:validate()
  return obj
end

function M3MatrixState:clone()
  return self:from_dict(self:to_dict())
end

-- `cea290`: record the current review before M3 recomputes its slot.
function M3MatrixState:record_outcome(difficulty_idx, stability_idx,
                                      retrievability_idx, grade)
  local off = model3.matrix_cell_offset(difficulty_idx, stability_idx,
    retrievability_idx) + 1
  self.outcome_count[off] = self.outcome_count[off] + 1
  if grade >= 3 then
    self.outcome_success[off] = self.outcome_success[off] + 1
  end
end

-- The auxiliary `cea290` update used when a repetition stage is one.
function M3MatrixState:record_pre_lapse_outcome(previous_reps, previous_lapses,
                                                previous_r_idx, interval_idx,
                                                grade)
  interval_idx = math.max(1, math.min(36, interval_idx))
  if previous_reps ~= 1 then
    return
  end
  if previous_lapses > 0 then
    local stage = math.max(1, math.min(20, previous_lapses))
    previous_r_idx = math.max(1, math.min(20, previous_r_idx))
    local off = model3.lapse_cell_offset(previous_r_idx, stage, interval_idx) + 1
    self.lapse_observed[off] = self.lapse_observed[off] + 1
    if grade >= 3 then
      self.lapse_remembered[off] = self.lapse_remembered[off] + 1
    end
  else
    local off = interval_idx  -- interval_idx - 1 + 1 (1-based array)
    self.first_stage_observed[off] = self.first_stage_observed[off] + 1
    if grade >= 3 then
      self.first_stage_remembered[off] = self.first_stage_remembered[off] + 1
    end
  end
end

-- `cec1c0`: online mean update performed after `cea5a0` returns.
function M3MatrixState:record_smoothing_value(difficulty_idx, stability_idx,
                                              retrievability_idx, value)
  if value <= 0.0 or stability_idx <= 0 then
    return
  end
  local off = model3.matrix_cell_offset(difficulty_idx, stability_idx,
    retrievability_idx) + 1
  local count = self.smoothing_count[off]
  self.smoothing_value[off] = (
    self.smoothing_value[off] * count + value) / (count + 1)
  self.smoothing_count[off] = count + 1
end

-- ---------------------------------------------------------------------------
-- FUN_00cf73d0: stability-axis value lookup = ln(j) / ln(20). [C][BIN]
-- ---------------------------------------------------------------------------

function model3.stability_axis_value(j)
  return ln(j + 0.0) / ln(20.0)
end

-- ---------------------------------------------------------------------------
-- FUN_0097c2c0: weighted linear least-squares fit. [C][ASM][BIN]
-- ---------------------------------------------------------------------------

function model3.wls_regression(xs, ys, counts)
  local Sy, Sx, Sxx, Sxy, Sw = 0.0, 0.0, 0.0, 0.0, 0.0
  for i = 1, #xs do
    local x, y = xs[i], ys[i]
    local w = round_half_up(counts[i] + 0.0) + model3.WLS_EPS
    Sy = Sy + y * w
    Sx = Sx + x * w
    Sxx = Sxx + x * x * w
    Sxy = Sxy + x * y * w
    Sw = Sw + w
  end
  local xbar = Sx / Sw
  local slope = (Sxy / Sw - xbar * (Sy / Sw)) / (Sxx / Sw - xbar * xbar)
  local intercept = Sy / Sw - xbar * slope
  return slope, intercept
end

-- ---------------------------------------------------------------------------
-- FUN_00ce7e60: build the SInc row over the innermost axis, then regress.
-- [C][BIN] Returns slope, intercept, total_count.
-- ---------------------------------------------------------------------------

function model3.build_axis_and_fit(idx_a, idx_b, of_interval_matrix, of_count_matrix)
  local xs, ys, counts = {}, {}, {}
  local total_count = 0
  for j = 1, 20 do
    local axis = ln(j + 0.0) / ln(model3.AXIS_LOG_BASE)  -- FUN_00cf73d0
    local off = (idx_a - 1) * 441 + (idx_b - 1) * 21 + (j - 1) + 1
    local c = of_count_matrix[off]
    total_count = total_count + round_half_up(c + 0.0)
    local prior
    if c <= model3.COUNT_FLOOR then
      prior = axis * model3.PRIOR_A + model3.PRIOR_B
    else
      prior = of_interval_matrix[off] / c
    end
    local y
    if prior > model3.COUNT_FLOOR then y = ln(prior) else y = 0.0 end
    xs[#xs + 1] = axis
    ys[#ys + 1] = y
    counts[#counts + 1] = c
  end
  local slope, intercept = model3.wls_regression(xs, ys, counts)
  return slope, intercept, total_count
end

-- ---------------------------------------------------------------------------
-- FUN_00ce99a0: SInc interpolation. [C][BIN]
-- ---------------------------------------------------------------------------

function model3.sinc_interpolation(R, matrix_sinc, total_count)
  local w = model3.sigmoid_ratio(total_count, model3.SINC_K)
  return w * matrix_sinc + (model3.SINC_BASE - w) * R
end

-- ---------------------------------------------------------------------------
-- FUN_00af6e30: predicted post-review difficulty/stability blend -> [0,1].
-- [C][BIN]
-- ---------------------------------------------------------------------------

function model3.predicted_blend(old_interval, new_sinc, grade, reps, lapses)
  local recall
  if grade >= 3 then recall = 1.0 else recall = 0.0 end
  -- sign_flip(recall - new_sinc) = new_sinc - recall
  local target = (sign_flip(recall - new_sinc) + 0.1) * 9.0
  local mix_w = 0.2
  if reps == 2 and lapses == 0 then
    mix_w = 0.7
  end
  if recall == 1.0 and old_interval < target then
    mix_w = mix_w / 2.0
  end
  if recall == 0.0 and target < old_interval then
    mix_w = mix_w / 2.0
  end
  local out = mix_w * target + (1.0 - mix_w) * old_interval
  if out > 1.0 then out = 1.0 end
  if out < 0.0 then out = 0.0 end
  return out
end

-- ---------------------------------------------------------------------------
-- FUN_00ce9400: stability increase (3-way weighted blend). [C][BIN]
-- ---------------------------------------------------------------------------

function model3.stability_increase(old_interval, matrix_value, total_count,
                                   grade, new_S, pass_flag, fail_flag)
  local w_old = model3.SI_175
  local w_mat = model3.SI_100
  local w_count = 0.01   -- local_28 default
  local w_diff = model3.SI_W_FAIL
  if pass_flag then
    if old_interval <= new_S then
      local ratio = new_S / old_interval
      w_count = model3.sigmoid_ratio(ratio, model3.SI_K_PASS) * model3.SI_W_PASS
    end
    w_diff = model3.sigmoid_ratio(total_count, model3.SI_K_DIFF) * model3.SI_W_DIFF
  end
  if fail_flag then
    if new_S <= old_interval then
      local ratio = model3.SI_K_FAIL - new_S / old_interval
      w_count = model3.sigmoid_ratio(ratio, model3.SI_K_FAIL) * model3.SI_W_FAIL
    end
    w_diff = 1.0
  end
  return (matrix_value * (w_mat + w_diff) + old_interval * w_old
    + new_S * w_count) / (w_diff + w_mat + w_old + w_count)
end

-- ---------------------------------------------------------------------------
-- FUN_00ce8dd0: round ratio to a discrete set. [C][BIN]
-- ---------------------------------------------------------------------------

function model3.round_ratio(ratio, grade, pass_flag)
  if not pass_flag then
    -- narrow set
    if ratio > model3.ROUND_NARROW_HI then return 2.0 end
    if ratio <= model3.ROUND_NARROW_LO then return 0.5 end
    return ratio
  else
    -- wide set
    if ratio > model3.ROUND_WIDE_HI then return 20.0 end
    if ratio <= model3.ROUND_WIDE_LO then return 0.8 end
    return ratio
  end
end

-- ---------------------------------------------------------------------------
-- FUN_00ce33b0 / FUN_00ce3210: matrix-update prior and Bayesian update.
-- [C][BIN]
-- ---------------------------------------------------------------------------

function model3.matrix_update_prior(new_reps, new_S)
  local base = pow_f(new_S, model3.MU_POW_BASE)
  local e = exp(new_reps * model3.MU_MUL_EXP)
  return base * model3.MU_COEFF * e + model3.MU_ADD
end

function model3.matrix_update(old_S, reps_count, new_S, lookup_smoothed,
                              neighbor_count)
  local prior = model3.matrix_update_prior(reps_count, new_S)
  local w = model3.sigmoid_ratio(neighbor_count + 0.0, model3.MU_K)
  return (model3.MU_PRIOR_W - w) * prior + w * lookup_smoothed
end

-- ---------------------------------------------------------------------------
-- FUN_00ce1900: Bayesian prior / initial interval (lapse branch). [C][BIN]
-- ---------------------------------------------------------------------------

function model3.bayesian_prior_interval(D_blend, old_interval, R)
  local A = model3.BP_LO + (model3.BP_HI - model3.BP_LO) * (model3.BP_MID - D_blend)
  local B = pow_f(old_interval,
    model3.BP_POW_LO + D_blend * (model3.BP_POW_HI - model3.BP_POW_LO))
  local base = (A - model3.BP_MID) * B + model3.BP_MID
  local lin = D_blend * model3.BP_LIN_M + model3.BP_LIN_B
  if model3.BP_CLAMP < lin then
    lin = model3.BP_CLAMP
  end
  local out = base * model3.decay_transform(sign_flip(lin) * R)
  out = model3.round_ratio(out, 4, true)  -- wide set (grade>=3 path)
  return out
end

-- ---------------------------------------------------------------------------
-- FUN_00ce9190: Bayesian smoothing core. [C][BIN]
-- ---------------------------------------------------------------------------

function model3.bayesian_smoothing(measured, measurement_weight, cell_value,
                                   neighbor_value, neighbor_count)
  local cap = model3.BS_CAP
  if measurement_weight < model3.BS_CAP then
    cap = measurement_weight
  end
  local lo = measurement_weight * cell_value
  if lo < measurement_weight * neighbor_value then
    lo = measurement_weight * neighbor_value
  end
  if lo < measured then
    lo = measured + cap
  end
  local w = model3.sigmoid_ratio(neighbor_count + 0.0, model3.BS_K)
  local out = measured * ((neighbor_value + w * model3.BS_W * cell_value)
    / (w * model3.BS_W + model3.BS_CAP))
  if lo < out then
    out = lo
  end
  if out < model3.BS_FLOOR then
    out = model3.BS_FLOOR
  end
  return out
end

-- ---------------------------------------------------------------------------
-- FUN_00cf9070: forgetting-curve regression. [C][BIN]
-- ---------------------------------------------------------------------------

-- `cf74f0`: nonlinear elapsed-interval axis used by lapse matrices.
function model3.interval_axis_value(index)
  local powered = math.ceil(pow_f(model3.INTERVAL_AXIS_BASE,
    index - model3.INTERVAL_AXIS_SHIFT))
  return math.max(index, powered)
end

function model3.forgetting_curve_fit(successes, observations, prior_interval)
  prior_interval = prior_interval or 1.0
  local n = math.min(#successes, #observations, 35)
  local ratios = {}
  local total_success, total_observed = 0, 0
  for i = 1, n do
    local observed = observations[i]
    if observed <= 0 then
      ratios[#ratios + 1] = model3.CF_R_LO
    else
      ratios[#ratios + 1] = math.max(model3.CF_R_LO,
        successes[i] / observed)
      total_success = total_success + round_half_up(successes[i] + 0.0)
      total_observed = total_observed + round_half_up(observed + 0.0)
    end
  end

  if total_observed == 0 then
    return prior_interval
  end

  local overall = total_success / total_observed
  if overall > model3.CF_RATIO_TH then
    return prior_interval
  end
  overall = math.max(model3.CF_R_LO, math.min(model3.CF_R_HI, overall))

  local xs, ys = {}, {}
  for i = 1, 35 do
    xs[#xs + 1] = ln(model3.interval_axis_value(i) + 0.0)
  end
  for i = 1, 35 do
    if ratios[i] then
      ys[#ys + 1] = ln(ratios[i])
    else
      ys[#ys + 1] = ln(model3.CF_R_LO)
    end
  end
  local obs = {}
  for i = 1, 35 do
    obs[i] = observations[i] or 0
  end
  local slope, intercept = model3.wls_regression(xs, ys, obs)

  local log_hi = ln(model3.CF_R_HI)
  local log_lo = ln(model3.CF_R_LO)
  local log_target = ln(model3.CF_BASE)
  local prior_intercept = ln(pow_f(prior_interval, model3.CF_POW_EXP)
    * model3.CF_BASE)
  if log_hi < intercept then
    slope = slope * (log_target - log_hi) / (log_target - intercept)
    intercept = log_hi
  end
  if intercept < log_lo then
    intercept = log_lo
  end

  local minimum_slope = -0.001
  if model3.CF_BASE < overall then
    minimum_slope = (log_target - ln(overall)) / ln(model3.CF_YEAR)
  end
  if minimum_slope < slope then
    intercept = ln(overall)
    slope = minimum_slope
  end
  if slope < -3.0 then slope = -3.0 end

  local data_weight = model3.sigmoid_ratio(total_observed + 0.0, model3.CF_W_HI)
  slope = slope * data_weight + (-0.07) * (1.0 - data_weight)
  intercept = intercept * data_weight + prior_intercept * (1.0 - data_weight)
  local fitted = exp((log_target - intercept) / slope)
  local output_weight = model3.sigmoid_ratio(total_observed + 0.0, model3.CF_W_LO)
  return fitted * output_weight + prior_interval * (1.0 - output_weight)
end

function model3.lapse_cell_fit(r_idx, stage_idx, state)
  local successes, observations = {}, {}
  for interval_idx = 1, 35 do
    local off = model3.lapse_cell_offset(r_idx, stage_idx, interval_idx) + 1
    successes[#successes + 1] = state.lapse_remembered[off]
    observations[#observations + 1] = state.lapse_observed[off]
  end
  local total = 0
  for _, v in ipairs(observations) do total = total + v end
  return math.max(0.1, math.min(11.0,
    model3.forgetting_curve_fit(successes, observations, 1.0))), total
end

-- `ce2ca0`: center x16 plus four face-neighbors.
function model3.lapse_neighbor_lookup(retrievability, stage, state)
  local center_r = model3.r_index(retrievability)
  local center_stage = math.max(1, math.min(20, round_half_up(stage + 0.0)))
  local weighted = {}
  local offsets = {
    { 0, 0, 16 }, { -1, 0, 4 }, { 1, 0, 4 }, { 0, -1, 1 }, { 0, 1, 1 },
  }
  for _, o in ipairs(offsets) do
    local r = center_r + o[1]
    local s = center_stage + o[2]
    if 1 <= r and r <= 20 and 1 <= s and s <= 20 then
      local value, count = model3.lapse_cell_fit(r, s, state)
      weighted[#weighted + 1] = { value, count * o[3] }
    end
  end
  local total = 0
  for _, w in ipairs(weighted) do total = total + w[2] end
  if total == 0 then
    return weighted[1][1], 0
  end
  local acc = 0.0
  for _, w in ipairs(weighted) do acc = acc + w[1] * w[2] end
  return acc / total, total
end

-- ---------------------------------------------------------------------------
-- THE W3 MAIN FUNCTION — FUN_00cea5a0. [C][BIN]
-- opts: { t, reps, lapses, grade, D, S_old, old_interval, R,
--         interval_matrix, count_matrix, prev_S, of_interval_matrix,
--         of_count_matrix, state }
-- ---------------------------------------------------------------------------

function model3.w3_model_path(opts)
  local t, reps, lapses, grade = opts.t, opts.reps, opts.lapses, opts.grade
  local D, S_old, old_interval, R = opts.D, opts.S_old, opts.old_interval, opts.R
  local prev_S = opts.prev_S or 0.0

  local state = opts.state
  if state == nil then
    if opts.interval_matrix ~= nil or opts.count_matrix ~= nil then
      state = model3.new_matrix_state()
      state.outcome_count = opts.of_count_matrix or opts.count_matrix or state.outcome_count
      state.outcome_success = opts.of_interval_matrix or opts.interval_matrix or state.outcome_success
      state.smoothing_count = opts.count_matrix or state.smoothing_count
      state.smoothing_value = opts.interval_matrix or state.smoothing_value
    else
      state = model3.new_matrix_state()
    end
  end
  state:validate()

  -- 1. map the three axes to matrix indices
  local R_idx = model3.r_index(R)
  local S_idx = model3.s_index(S_old)
  local D_idx = model3.d_index(D)

  -- 2+3. SInc fit over the retrievability axis at (D_idx, S_idx)
  local slope, intercept, total_count = model3.build_axis_and_fit(
    D_idx, S_idx, state.outcome_success, state.outcome_count)
  local sinc_interval = model3.clamp_R(
    model3.decay_transform(slope * R + intercept))

  -- 4. blend SInc with R by data confidence (FUN_00ce99a0)
  local new_S_from_matrix = model3.clamp_R(
    model3.sinc_interpolation(R, sinc_interval, total_count + 0.0))

  -- 5. predicted post-review difficulty blend (FUN_00af6e30)
  local D_blend = model3.predicted_blend(D, new_S_from_matrix, grade, reps, lapses)

  -- 6. derive a stability from elapsed time and blended retrievability
  local estimated_stability = model3.clamp_S(
    (-math.log(0.9) * t) / (-ln(new_S_from_matrix)))

  -- 7. blend old/estimated/elapsed stability (FUN_00ce9400)
  local pass_flag = grade >= 3
  local fail_flag = grade < 3
  local new_S = model3.stability_increase(old_interval, estimated_stability,
    total_count + 0.0, grade, t, pass_flag, fail_flag)

  local raw_ratio = new_S / old_interval

  -- 8. rounded ratio (FUN_00ce8dd0), only if prev_S (param_10) > 0
  local rounded_ratio = -1.0
  if prev_S > model3.W3_WRONG_TH then
    rounded_ratio = new_S / prev_S
    rounded_ratio = model3.round_ratio(rounded_ratio, grade, pass_flag)
  end

  -- 9. choose pre-lapse-prior vs smoothing-matrix branch
  local matrix_entry
  if fail_flag and grade ~= 0xb then
    local stage = round_half_up(lapses + 0.0) + 1
    local neighbor_smoothed, neighbor_count = model3.lapse_neighbor_lookup(
      new_S_from_matrix, stage, state)
    matrix_entry = model3.matrix_update(D, stage + 0.0, new_S_from_matrix,
      neighbor_smoothed, neighbor_count)
    rounded_ratio = -1.0
  else
    local prior_iv = model3.bayesian_prior_interval(D_blend, old_interval, R)
    local new_D_idx = model3.d_index(D_blend)
    local off = model3.matrix_cell_offset(new_D_idx, S_idx, R_idx) + 1
    matrix_entry = model3.bayesian_smoothing(
      new_S, t, state.smoothing_value[off], prior_iv,
      state.smoothing_count[off])
  end

  return {
    S_new = matrix_entry,
    estimated_stability = estimated_stability,
    blended_stability = new_S,
    SInc_interval = sinc_interval,
    new_S_from_matrix = new_S_from_matrix,
    D_blend = D_blend,
    raw_ratio = raw_ratio,
    rounded_ratio = rounded_ratio,
    exp_decay_term = estimated_stability,
    matrix_entry = matrix_entry,
    indices = { R = R_idx, S = S_idx, D = D_idx,
      ["matrix_D"] = model3.d_index(D_blend) },
    total_count = total_count,
    prev_S_out = new_S,
  }
end

-- `cf7460`: map an elapsed interval to the 1..35 lapse-table axis.
function model3.interval_category(interval)
  interval = math.max(1, math.floor(interval))
  local category = round_half_up(ln(interval + 0.0)
    / ln(model3.INTERVAL_AXIS_BASE)) + 12
  category = math.min(interval, category)
  return math.max(1, math.min(35, category))
end

-- ---------------------------------------------------------------------------
-- stateful wrapper
-- ---------------------------------------------------------------------------

function model3.new_item_state()
  return {
    last_review_day = -1,
    previous_interval = 0,
    repetitions = 0,
    lapses = 0,
    stability = 1.0,
    difficulty = 0.5,
    previous_stability = -1.0,
    previous_stability_index = 0,
    previous_r_index = 0,
  }
end

-- opts: { commit = true, retrievability = nil }
function model3.model_3_stateful(item, matrices, today, grade, opts)
  opts = opts or {}
  local commit = opts.commit
  if commit == nil then commit = true end
  if grade < 0 or grade > 5 then
    error("grade must be in 0..5")
  end
  local working = commit and matrices or matrices:clone()
  local elapsed = 0
  if item.last_review_day >= 0 then
    elapsed = math.max(0, today - item.last_review_day)
  end
  local retrievability
  if opts.retrievability == nil then
    local base = item.previous_interval
    if base == 0 or base == nil then base = item.stability end
    base = math.max(1.0, base + 0.0)
    retrievability = model3.clamp_R(exp(ln(0.9) * elapsed / base))
  else
    retrievability = model3.clamp_R(opts.retrievability)
  end

  local repetitions, lapses
  if grade >= 3 then
    repetitions = math.min(65535, item.repetitions + 1)
    lapses = item.lapses
  else
    repetitions = 1
    local delta = 0
    if item.repetitions ~= 0 then delta = 1 end
    lapses = math.min(65535, item.lapses + delta)
  end

  local old_stability = model3.clamp_S(item.stability)
  local pre_d = model3.d_index(item.difficulty)
  local pre_s = model3.s_index(old_stability)
  local pre_r = model3.r_index(retrievability)

  -- `cec1c0` calls `cea290` before `ceb870`, so this review contributes to
  -- the forgetting-curve fit used to calculate its own M3 output.
  -- NOTE (0 is falsy in Python's `or`): a zero previous_r_index uses pre_r.
  local prev_r = item.previous_r_index
  if prev_r == nil or prev_r == 0 then prev_r = pre_r end
  working:record_outcome(pre_d, pre_s, pre_r, grade)
  working:record_pre_lapse_outcome(
    item.repetitions, item.lapses, prev_r,
    model3.interval_category(elapsed), grade)

  local output = model3.w3_model_path({
    t = math.max(elapsed + 0.0, 1.0), reps = repetitions, lapses = lapses,
    grade = grade, D = item.difficulty, S_old = old_stability,
    old_interval = old_stability, R = retrievability,
    prev_S = item.previous_stability, state = working,
  })

  -- The replay learner writes the returned entry into an online-mean table
  -- after scheduling, using the previous replay iteration's S bin.
  working:record_smoothing_value(
    pre_d, item.previous_stability_index, pre_r, output.matrix_entry)

  local next_item = {
    last_review_day = today,
    previous_interval = 0,
    repetitions = repetitions,
    lapses = lapses,
    stability = output.matrix_entry,
    difficulty = output.D_blend,
    previous_stability = old_stability,
    previous_stability_index = pre_s,
    previous_r_index = pre_r,
  }
  return {
    stability = output.matrix_entry,
    retrievability = retrievability,
    elapsed = elapsed,
    output = output,
    next_item = next_item,
    committed = commit,
  }
end

return model3
