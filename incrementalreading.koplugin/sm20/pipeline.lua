-- SM-20 end-to-end review -> interval pipeline, ported 1:1 from
-- sm20/pipeline.py: the 5-model ensemble + finalization that produces the
-- final due-date interval (FUN_00cf5b50 and callees). See the Python module
-- for the full decoded provenance and the post-lapse timing analysis.

local math = math
local num = require("sm20.num")
local arena_mod = require("sm20.arena")
local ensemble_mod = require("sm20.ensemble")
local kernel = require("sm20.kernel")
local model1 = require("sm20.model1")
local model2 = require("sm20.model2")
local model3 = require("sm20.model3")
local model5 = require("sm20.model5")

local pipeline = {}

-- Finalization constants — FUN_00cf5b50 [BIN]
pipeline.FI_ONE = 1.0
pipeline.FI_DIV = 100.0
pipeline.FORGET_BASE = 0.9
pipeline.CLAMP_HI = 44530.0
pipeline.CLAMP_LO = 0.7
pipeline.INT_HI = 44530
pipeline.INT_LO = 1

-- Dispersal — FUN_00cf5100 [C][ASM][BIN]
pipeline.DISP_BASE = 1.0
pipeline.DISP_EXP_A = -0.191
pipeline.DISP_MULT_A = 0.76
pipeline.DISP_EXP_B = -0.42
pipeline.DISP_MULT_B = 3.0
pipeline.DISP_RAND_EXP = 1.6
pipeline.DISP_THRESH = 0.5

-- Post-lapse — FUN_00ce2fe0 [C][BIN]
pipeline.PL_DIV = 100.0
pipeline.PL_SCALE = -5.0
pipeline.PL_TARGET = 9.0
pipeline.PL_JITTER = 0.2
pipeline.PL_LO = 1.0
pipeline.PL_HI = 11.0

-- Minimum-growth guard — FUN_00cf4b90 [C][BIN]
pipeline.MG_USED_MAX = 1461
pipeline.MG_POW_USED_MAX = 70
pipeline.MG_POW_EXP = -0.1
pipeline.MG_POW_MULT = 1.7
pipeline.MG_FLOOR = 1.1
pipeline.MG_ROUND_ADD = 0.5

pipeline.DEFAULT_FI = 10

local py_round = num.py_round

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- ---------------------------------------------------------------------------
-- DelphiLCG — the binary's PRNG (Borland/Delphi LCG), FUN_0040a300/350/390.
-- Default seed 0 (Delphi's documented RandSeed before Randomize), so the
-- stream is reproducible; see the Python docstring for the live-seed notes.
-- ---------------------------------------------------------------------------

local DelphiLCG = {}
DelphiLCG.__index = DelphiLCG
pipeline.DelphiLCG = DelphiLCG

DelphiLCG.MULT = 0x08088405              -- [BIN] FUN_0040a350 multiplier
local LCG_ONE_OVER_2_32 = 1.0 / 4294967296.0  -- exactly 1/2^32

function DelphiLCG.new(seed)
  seed = seed or 0
  local self = setmetatable({}, DelphiLCG)
  -- RandSeed = seed ^ (seed >> 32), stored as uint32
  self.state = num.xor32(seed % num.TWO32, math.floor(seed / num.TWO32)) % num.TWO32
  return self
end

-- Next uint32 step, returned as a double in [0, 1). FUN_0040a390.
function DelphiLCG:random()
  self.state = (num.mulmod32(self.state, DelphiLCG.MULT) + 1) % num.TWO32
  return self.state * LCG_ONE_OVER_2_32
end

-- Delphi RandG: Box-Muller using two LCG draws. FUN_00ce2830. [C]
-- mean + cos(2*pi*r1) * sqrt(-2*ln(r2)) * stddev; r1 drawn first.
function DelphiLCG:gauss(mean, stddev)
  mean = mean or 0.0
  stddev = stddev or 1.0
  local r1 = self:random()
  local r2 = self:random()
  return mean + math.cos(2.0 * math.pi * r1)
    * math.sqrt(-2.0 * math.log(r2)) * stddev
end

-- ---------------------------------------------------------------------------
-- finalization pieces
-- ---------------------------------------------------------------------------

-- ln(1 - FI/100) / ln(0.9). FI = requested forgetting index. [BIN]
function pipeline.retention_factor(fi)
  return math.log(pipeline.FI_ONE - fi / pipeline.FI_DIV)
    / math.log(pipeline.FORGET_BASE)
end

-- FUN_00cf5100: interval-scaled stochastic day-spread. [C][ASM][BIN]
function pipeline.dispersal(adjusted, rng)
  if rng == nil then
    rng = DelphiLCG.new(0)
  end
  local d_shrink = pipeline.DISP_BASE - (adjusted ^ pipeline.DISP_EXP_A) * pipeline.DISP_MULT_A
  local d_grow = (adjusted ^ pipeline.DISP_EXP_B) * pipeline.DISP_MULT_B + pipeline.DISP_BASE
  local p = rng:random() ^ pipeline.DISP_RAND_EXP
  local factor
  if rng:random() <= pipeline.DISP_THRESH then
    factor = d_grow - pipeline.DISP_BASE
  else
    factor = d_shrink - pipeline.DISP_BASE
  end
  return adjusted + factor * p * adjusted
end

-- FUN_00ce2fe0: post-lapse curve toward target=9, clamped [1, 11]. [C][BIN]
-- x = the element's priority percent (item[+0x16]); always applies the
-- +/-20% Gaussian jitter in the binary.
function pipeline.post_lapse(adjusted, x, rng)
  if rng == nil then
    rng = DelphiLCG.new(0)
  end
  local xr = clamp(x / pipeline.PL_DIV, 0.0, 1.0)
  local f = 1.0 - math.exp(xr * pipeline.PL_SCALE)
  local base = adjusted + f * (pipeline.PL_TARGET - adjusted)
  base = base + base * pipeline.PL_JITTER * rng:gauss(0.0, 1.0)
  return clamp(base, pipeline.PL_LO, pipeline.PL_HI)
end

-- FUN_00cf4b90: minimum interval-growth ratio for pass reviews. [C][BIN]
--     used < 70:    floor = max(1.7 * used**-0.1, 1.1)
--     used < 1461:  floor = 1.1
--     used >= 1461: no guard
function pipeline.min_growth_guard(interval, used_interval)
  local used = math.max(1, used_interval)  -- FUN_00cf5b50:54 floors +0x2a at 1
  if used >= pipeline.MG_USED_MAX then
    return interval
  end
  local floor_ratio = pipeline.MG_FLOOR
  if used < pipeline.MG_POW_USED_MAX then
    floor_ratio = (used ^ pipeline.MG_POW_EXP) * pipeline.MG_POW_MULT
  end
  if floor_ratio < pipeline.MG_FLOOR then
    floor_ratio = pipeline.MG_FLOOR
  end
  if interval / used < floor_ratio then
    interval = py_round(used * floor_ratio + pipeline.MG_ROUND_ADD)
    if interval > pipeline.INT_HI then interval = pipeline.INT_HI end
  end
  return interval
end

-- FUN_00cf5b50: ensemble stability -> integer due-date interval. [C][BIN]
-- opts: { post_lapse_mode, post_lapse_x, disperse, rng, used_interval,
--         min_growth } — defaults mirror the Python keyword defaults.
function pipeline.finalize(ensemble_val, fi, opts)
  opts = opts or {}
  local post_lapse_mode = opts.post_lapse_mode or false
  local post_lapse_x = opts.post_lapse_x or 0.0
  local disperse = opts.disperse or false
  local used_interval = opts.used_interval or 1
  local min_growth = opts.min_growth or false

  local adjusted = pipeline.retention_factor(fi) * ensemble_val
  local raw
  if post_lapse_mode then
    raw = pipeline.post_lapse(adjusted, post_lapse_x, opts.rng)
  elseif disperse then
    raw = pipeline.dispersal(adjusted, opts.rng)
  else
    raw = adjusted
  end
  raw = clamp(raw, pipeline.CLAMP_LO, pipeline.CLAMP_HI)
  local interval = clamp(py_round(raw), pipeline.INT_LO, pipeline.INT_HI)
  if min_growth then
    interval = pipeline.min_growth_guard(interval, used_interval)
  end
  return { adjusted = adjusted, raw = raw, interval = interval }
end

-- ---------------------------------------------------------------------------
-- review — the full SM-20 pipeline for a single item
-- ---------------------------------------------------------------------------

-- opts: { commit = false, disperse = false, rng = nil, pure_m4 = false,
--         post_lapse_mode = nil, post_lapse_x = 0.0 }
function pipeline.review(state, grade, elapsed_days, fi, collection, today, opts)
  opts = opts or {}
  local commit = opts.commit or false
  local pure_m4 = opts.pure_m4 or false
  if grade < 0 then grade = 0 elseif grade > 5 then grade = 5 end
  local t = elapsed_days

  -- Pre-review repetition/lapse counters (the binary's item[+0x22]/[+0x24]).
  local pre_reps = state.m3_state.repetitions
  local pre_lapses = state.m3_state.lapses

  -- M4: SM-20-proper 35-param kernel (default weight 25%)
  local kernel_out = kernel.review_kernel(t, grade, state.difficulty, state.stability)
  local m4 = kernel_out.S_new

  -- M5: FSRS analytic (default weight 10%)
  local m5 = model5.model_5(t, grade, state.stability)

  -- M1: legacy scheduler (default weight 6%)
  local m1_review = model1.model_1(state.m1_state, today, grade, state.m1_history)
  local m1 = m1_review.interval + 0.0

  -- M2: classic SM-15/16 scheduler (default weight 14%)
  local m2_review = model2.model_2(state.m2_state, collection.m2_optimizer,
    today, grade, { forgetting_index = fi, commit = commit, rng = opts.rng })
  local m2 = m2_review.stability + 0.0

  -- M3: SM-19 raw matrix scheduler (default weight 45%)
  local m3_review = model3.model_3_stateful(state.m3_state, collection.m3_matrices,
    today, grade, { commit = commit })
  local m3 = m3_review.stability

  local slot_stabilities = { m1, m2, m3, m4, m5 }

  -- Ensemble: Algorithm Arena blend (adaptive weights) or pure M4.
  local ensemble_val
  if pure_m4 then
    ensemble_val = m4
  else
    ensemble_val = ensemble_mod.ensemble_stability(
      m1, m2, m3, m4, m5, collection.arena.weights)
  end

  -- Adapt weights on commit (FUN_00ce4470 -> FUN_00af40d0): score the
  -- predictions issued at the item's PREVIOUS review. Runs after the blend
  -- so this review schedules with the pre-update weights.
  if commit and state.slot_stabilities ~= nil then
    collection.arena:observe(state.slot_stabilities, elapsed_days, grade >= 3,
      pre_reps + 0.0)
  end

  -- Scheduling-family markers (FUN_00ce7380), written on EVERY review from
  -- the current grade + PRE-review counters, then read by the finalizer in
  -- the SAME pass (per-review scratch):
  --   lapse: family = 1, ordinal = 0 if pre_reps == 0 else pre_lapses + 1
  --   pass:  family = pre_reps + 1, ordinal = pre_lapses
  -- Post-lapse trigger: ordinal != 0 and family == 1. Min-growth: family > 1.
  local family, ordinal
  if grade < 3 then
    family = 1
    if pre_reps == 0 then ordinal = 0 else ordinal = math.min(65535, pre_lapses + 1) end
  else
    family = math.min(65535, pre_reps + 1)
    ordinal = math.min(65535, pre_lapses)
  end
  local post_lapse_mode = opts.post_lapse_mode
  if post_lapse_mode == nil then
    post_lapse_mode = (ordinal ~= 0 and family == 1)
  end

  local fin = pipeline.finalize(ensemble_val, fi, {
    post_lapse_mode = post_lapse_mode,
    post_lapse_x = opts.post_lapse_x or 0.0,
    disperse = opts.disperse or false,
    rng = commit and opts.rng or nil,
    used_interval = m1_review.used_interval,
    min_growth = family > 1,
  })

  if commit then
    m1_review.next_item.previous_interval = fin.interval
    m1_review.next_history.stability = fin.interval + 0.0
    m2_review.next_item.previous_interval = fin.interval
    m3_review.next_item.previous_interval = fin.interval
    state.m1_state = m1_review.next_item
    state.m1_history = m1_review.next_history
    state.m2_state = m2_review.next_item
    state.m3_state = m3_review.next_item
    state.stability = kernel_out.S_new
    state.difficulty = kernel_out.D_new
    state.repetition = m3_review.next_item.repetitions
    state.lapses = m3_review.next_item.lapses
    -- Persist this review's dispatch markers and model outputs so the next
    -- review can score each competitor's prediction (FUN_00ce4470 dataflow).
    state.post_lapse_family = family
    state.lapse_ordinal = ordinal
    state.slot_stabilities = slot_stabilities
    state.interval = fin.interval + 0.0
  end

  return {
    interval = fin.interval,
    stability = kernel_out.S_new,
    difficulty = kernel_out.D_new,
    retrievability = kernel_out.A,
    ensemble = ensemble_val,
    slot_stabilities = slot_stabilities,
    fi_factor = pipeline.retention_factor(fi),
    adjusted = fin.adjusted,
  }
end

-- result_to_dict: the review result is already a plain table with exactly
-- the SM20ReviewResult fields; shallow-copy for snapshot comparisons.
function pipeline.result_to_dict(res)
  return {
    interval = res.interval,
    stability = res.stability,
    difficulty = res.difficulty,
    retrievability = res.retrievability,
    ensemble = res.ensemble,
    slot_stabilities = {
      res.slot_stabilities[1], res.slot_stabilities[2],
      res.slot_stabilities[3], res.slot_stabilities[4],
      res.slot_stabilities[5],
    },
    fi_factor = res.fi_factor,
    adjusted = res.adjusted,
  }
end

-- ---------------------------------------------------------------------------
-- next_interval — stateless convenience entry point (quick lookups; M1/M2/M3
-- stand-ins use the M4 kernel value). opts: { m3_fresh, post_lapse_mode,
-- post_lapse_x, disperse, rng, weights, pure_m4 }
-- ---------------------------------------------------------------------------

function pipeline.next_interval(t, grade, S, D, fi, opts)
  opts = opts or {}
  fi = fi or pipeline.DEFAULT_FI
  local kernel_out = kernel.review_kernel(t, grade, D, S)
  local m4 = kernel_out.S_new
  local m5 = model5.model_5(t, grade, S)
  local m3
  if opts.m3_fresh then
    -- mirrors the Python m3_fresh branch: empty (zero-filled) matrices
    -- stand in for a fresh collection
    local zeros_i, zeros_c = {}, {}
    for i = 1, model3.OUTCOME_CELLS do
      zeros_i[i] = 0.0
      zeros_c[i] = 0
    end
    local out = model3.w3_model_path({
      t = t, reps = 5, lapses = 1, grade = grade, D = D, S_old = S,
      old_interval = math.max(1.0, S), R = 0.9,
      interval_matrix = zeros_i, count_matrix = zeros_c,
      prev_S = S,
    })
    m3 = out.S_new
  else
    m3 = m4
  end
  local m1 = m4
  local m2 = m4

  local ensemble_val
  if opts.pure_m4 then
    ensemble_val = m4
  else
    ensemble_val = ensemble_mod.ensemble_stability(m1, m2, m3, m4, m5, opts.weights)
  end
  local fin = pipeline.finalize(ensemble_val, fi, {
    post_lapse_mode = opts.post_lapse_mode or false,
    post_lapse_x = opts.post_lapse_x or 0.0,
    disperse = opts.disperse or false,
    rng = opts.rng,
  })
  return {
    interval = fin.interval,
    S_new = m4,
    D_new = kernel_out.D_new,
    A = kernel_out.A,
    models = { M1 = m1, M2 = m2, M3 = m3, M4 = m4, M5 = m5 },
    ensemble = ensemble_val,
    fi_factor = pipeline.retention_factor(fi),
    adjusted = fin.adjusted,
  }
end

return pipeline
