-- Algorithm Arena weight adaptation — FUN_00af40d0, ported 1:1 from
-- sm20/arena.py (caller FUN_00ce4470's dataflow). The blend weights adapt on
-- every committed review where M3 produced a prediction; diagnostics
-- accumulators mirror the Python module's opt-in LSRM fields.

local math = math
local weights_mod = require("sm20.weights")

local arena = {}

-- === FUN_00af40d0 constants — all [BIN] ===
arena.ADAPT_LEARNING_RATE = 0.0317   -- _DAT_00af44c8
arena.ADAPT_CLAMP_LO = -0.5          -- DAT_00af44b8
arena.ADAPT_CLAMP_HI = 0.5           -- DAT_00af44c0
arena.ADAPT_TARGET_SUM = 100.0       -- _DAT_00af4518

-- Per-weight clamps (lo, hi), slots M1..M5 (PA2/PA15/PA19/PA20/PAF).
arena.ADAPT_WEIGHT_CLAMPS = {
  { 0.1, 30.0 },
  { 2.0, 50.0 },
  { 25.0, 99.9 },
  { 15.0, 95.0 },
  { 0.1, 45.0 },
}

-- Caller branch guards — DAT_00ce5c58 [BIN].
arena.ADAPT_REPS_THRESHOLD = 1e-8
arena.ADAPT_R3_THRESHOLD = 1e-8

-- Diagnostics-only constants (not from the binary).
arena.METRIC_DECAY = 0.995
arena.PRED_LO = 0.01
arena.PRED_HI = 0.99
arena.MIN_METRIC_COUNT = 10.0

local DEFAULT_WEIGHTS = weights_mod.DEFAULT_WEIGHTS

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

local function is_finite(x)
  return x == x and x ~= math.huge and x ~= -math.huge
end

-- R = 0.9^(elapsed/S), clamped to the diagnostic band.
function arena.recall_prediction(stability, elapsed_days)
  local s = math.max(stability, 0.01)
  local e = elapsed_days
  if e < 0.0 then e = 0.0 end
  return clamp(0.9 ^ (e / s), arena.PRED_LO, arena.PRED_HI)
end

local function squared_error(p, recalled)
  local outcome = recalled and 1.0 or 0.0
  return (outcome - p) ^ 2
end

-- Per-model signed prediction error: outcome - R_i (slots M1..M5).
function arena.compute_model_errors(r, recalled)
  -- r: array of 5 pre-review retrievability predictions
  local outcome = recalled and 1.0 or 0.0
  local errors = {}
  for i = 1, 5 do
    errors[i] = outcome - r[i]
  end
  return errors
end

-- FUN_00af40d0: adapt ensemble weights from per-model prediction errors.
-- Mutates and returns the `weights` array in place.
function arena.adapt_weights(weights, model_errors)
  if #weights ~= 5 or #model_errors ~= 5 then
    error("adapt_weights requires 5 weights and 5 errors")
  end

  local mean = 0.0
  for i = 1, 5 do mean = mean + model_errors[i] end
  mean = mean / 5.0
  for i = 1, 5 do
    local adjustment = clamp(
      mean - model_errors[i], arena.ADAPT_CLAMP_LO, arena.ADAPT_CLAMP_HI)
    local factor = math.exp(adjustment * arena.ADAPT_LEARNING_RATE)
    weights[i] = weights[i] * factor
    local bounds = arena.ADAPT_WEIGHT_CLAMPS[i]
    weights[i] = clamp(weights[i], bounds[1], bounds[2])
  end

  local total = 0.0
  for i = 1, 5 do total = total + weights[i] end
  if total <= 0.0 then
    -- Defensive: if all weights collapse to zero, restore defaults.
    for i = 1, 5 do weights[i] = DEFAULT_WEIGHTS[i] end
    return weights
  end
  for i = 1, 5 do
    weights[i] = (weights[i] / total) * arena.ADAPT_TARGET_SUM
  end
  return weights
end

-- ---------------------------------------------------------------------------
-- ArenaState: live weights plus opt-in diagnostics
-- ---------------------------------------------------------------------------

local ArenaState = {}
ArenaState.__index = ArenaState
arena.ArenaState = ArenaState

function ArenaState.new()
  local self = setmetatable({}, ArenaState)
  local w = {}
  for i = 1, 5 do w[i] = DEFAULT_WEIGHTS[i] end
  self.weights = w
  self.decayed_sse = { 0.0, 0.0, 0.0, 0.0, 0.0 }
  self.decayed_blend_sse = 0.0
  self.decayed_sm19_sse = 0.0
  self.decayed_count = 0.0
  self.total_scored = 0
  return self
end

-- to_dict omits nil fields; all fields here are always present. Key order
-- mirrors the Python dataclass field order (irrelevant for comparison).
function ArenaState:to_dict()
  return {
    weights = { self.weights[1], self.weights[2], self.weights[3],
      self.weights[4], self.weights[5] },
    decayed_sse = { self.decayed_sse[1], self.decayed_sse[2],
      self.decayed_sse[3], self.decayed_sse[4], self.decayed_sse[5] },
    decayed_blend_sse = self.decayed_blend_sse,
    decayed_sm19_sse = self.decayed_sm19_sse,
    decayed_count = self.decayed_count,
    total_scored = self.total_scored,
  }
end

function ArenaState:from_dict(data)
  local obj = ArenaState.new()
  for i = 1, 5 do obj.weights[i] = data.weights[i] end
  for i = 1, 5 do obj.decayed_sse[i] = data.decayed_sse[i] end
  obj.decayed_blend_sse = data.decayed_blend_sse
  obj.decayed_sm19_sse = data.decayed_sm19_sse
  obj.decayed_count = data.decayed_count
  obj.total_scored = data.total_scored
  return obj
end

-- Sanitize state loaded from storage (older builds / corrupt rows).
function ArenaState:sanitized()
  local finite = true
  local total = 0.0
  for i = 1, 5 do
    if not is_finite(self.weights[i]) or self.weights[i] < 0.0 then
      finite = false
    end
    total = total + self.weights[i]
  end
  if not finite or total <= 0.0 then
    for i = 1, 5 do self.weights[i] = DEFAULT_WEIGHTS[i] end
  end
  if not is_finite(self.decayed_count) or self.decayed_count < 0.0 then
    for i = 1, 5 do self.decayed_sse[i] = 0.0 end
    self.decayed_blend_sse = 0.0
    self.decayed_sm19_sse = 0.0
    self.decayed_count = 0.0
  end
  return self
end

-- Score one committed review and adapt the weights (the binary's path).
-- slot_stabilities: the five models' stability outputs at the *previous*
-- review. repetition_count defaults to 1.0 in Python; the plugin passes the
-- item's prior repetition count.
function ArenaState:observe(slot_stabilities, elapsed_days, recalled,
                            repetition_count)
  repetition_count = repetition_count or 1.0
  if repetition_count <= arena.ADAPT_REPS_THRESHOLD then
    return
  end
  if elapsed_days <= 0.0 then
    return
  end
  for i = 1, 5 do
    if not is_finite(slot_stabilities[i]) then
      return
    end
  end

  -- Reconstruct each model's pre-review retrievability R_i = 0.9^(t/S).
  local preds = {}
  for i = 1, 5 do
    preds[i] = arena.recall_prediction(slot_stabilities[i], elapsed_days)
  end
  local r3 = preds[3]
  if r3 <= arena.ADAPT_R3_THRESHOLD then
    return
  end

  local errors = arena.compute_model_errors(preds, recalled)

  -- Opt-in R-Metric diagnostics (computed BEFORE the weight update so the
  -- blend loss reflects the weights that actually scheduled this review).
  local sses = {}
  for i = 1, 5 do
    sses[i] = squared_error(preds[i], recalled)
  end
  local w_sum = 0.0
  for i = 1, 5 do w_sum = w_sum + self.weights[i] end
  local blend_pred
  if w_sum > 0.0 then
    local acc = 0.0
    for i = 1, 5 do
      acc = acc + self.weights[i] * preds[i]
    end
    blend_pred = clamp(acc / w_sum, arena.PRED_LO, arena.PRED_HI)
  else
    blend_pred = preds[3]
  end
  for i = 1, 5 do
    self.decayed_sse[i] = self.decayed_sse[i] * arena.METRIC_DECAY + sses[i]
  end
  self.decayed_blend_sse = self.decayed_blend_sse * arena.METRIC_DECAY
    + squared_error(blend_pred, recalled)
  self.decayed_sm19_sse = self.decayed_sm19_sse * arena.METRIC_DECAY + sses[3]
  self.decayed_count = self.decayed_count * arena.METRIC_DECAY + 1.0
  self.total_scored = self.total_scored + 1

  -- Decoded weight update: FUN_00af40d0.
  arena.adapt_weights(self.weights, errors)
end

return arena
