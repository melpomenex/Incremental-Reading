-- M1 — SM-2 legacy scheduler, ported 1:1 from sm20/model1.py
-- (decoded from FUN_00d43e00; constants byte-extracted [BIN]).

local math = math
local num = require("sm20.num")

local model1 = {}

-- Default retrievability target at FI=10 [BIN] (PTR_DAT_01125aa0 @ FI=10).
model1.TARGET_R = 0.9

function model1.new_item_state()
  return {
    last_review_day = -1,
    previous_interval = 0,
    repetitions = 0,
    lapses = 0,
  }
end

function model1.new_history_point(factor, stability)
  return { factor = factor, stability = stability }
end

-- FUN_00d43e00 lines 45-63: fresh (history-less) A-factor. [C][BIN]
-- reps < 3 -> 2.5; else pow(prev_interval/6, 1/(reps-2)) clamped [1.3, 2.5],
-- upper clamp first (matching the binary's order).
function model1._fresh_factor(previous_interval, repetitions)
  if repetitions < 3 then
    return 2.5
  end
  local value = (previous_interval / 6.0) ^ (1.0 / (repetitions - 2))
  if value > 2.5 then value = 2.5 end
  if value < 1.3 then value = 1.3 end
  return value
end

-- FUN_00a62080 GetUsedInterval. [C][ASM] today - last_review_day, floored at
-- 1; values < -1 are a fatal error in the binary (raised here).
function model1._used_interval(today, last_review_day)
  local used = today - last_review_day
  if used < -1 then
    error("UsedInterval < -1")
  end
  if used < 1 then
    return 1
  end
  return used
end

-- FUN_00d43e00 lines 152-168: grade-dependent factor adjustment [C][BIN],
-- applied for grades 3,4,5 only.
function model1._adjust_factor_for_grade(factor, grade)
  if grade < 3 then
    return factor
  end
  local distance = 5.0 - grade
  local adjustment = 0.1 - distance * (distance * 0.02 + 0.08)
  local value = factor + adjustment
  if value > 2.5 then value = 2.5 end
  if value < 1.3 then value = 1.3 end
  return value
end

-- FUN_00d43e00 M1 interval path for one review. [C][BIN]
-- history: nil, or { factor = .., stability = .. } (last replay record).
-- target_r: retrievability target (default 0.9 @ FI=10).
function model1.model_1(item, today, grade, history, target_r)
  target_r = target_r or model1.TARGET_R
  if grade < 0 or grade > 5 then
    error("grade must be in 0..5")
  end

  -- Used interval: only computed when previous_interval (+0x26) is non-zero.
  local used
  if item.previous_interval ~= 0 then
    used = model1._used_interval(today, item.last_review_day)
  else
    used = 1
  end

  -- Factor + stability (FUN_00d43e00:44-96).
  local factor, stability
  if history then
    factor = history.factor
    stability = history.stability
  else
    factor = model1._fresh_factor(item.previous_interval, item.repetitions)
    if item.repetitions >= 2 and item.previous_interval >= 1 then
      stability = item.previous_interval + 0.0
    else
      stability = 1.0
    end
  end
  if stability <= 0.0 then
    stability = 1.0
  end

  -- Repetitions + lapse update (FUN_00d43e00:97-124).
  local repetitions, lapses
  if grade >= 3 then
    repetitions = math.min(65535, item.repetitions + 1)
    lapses = item.lapses
  else
    repetitions = 1
    if item.repetitions == 0 then lapses = 0 else lapses = math.min(65535, item.lapses + 1) end
  end

  -- Retrievability: target_r ^ (used / stability) (FUN_00d43e00:128).
  local retrievability = math.exp(math.log(target_r) * used / stability)

  -- Interval (FUN_00d43e00:130-149); round via cvtsd2si (round-to-even).
  local interval
  if repetitions == 1 then
    interval = 1
  elseif repetitions == 2 then
    interval = math.max(6, used)
  else
    local candidate = math.max(used + 0.0, used * factor)
    interval = num.py_round(candidate)
  end

  local adjusted_factor = model1._adjust_factor_for_grade(factor, grade)

  -- Stored retrievability at item[+0x127] (FUN_00d43e00:169-186).
  local stored_retrievability
  if history == nil then
    if item.previous_interval < 1 then
      stored_retrievability = 0.85  -- immediate 0x3feb333333333333 [BIN]
    else
      stored_retrievability = math.exp(
        math.log(target_r) * used / item.previous_interval)
    end
  else
    stored_retrievability = retrievability
  end

  local next_item = {
    last_review_day = today,
    previous_interval = 0,
    repetitions = repetitions,
    lapses = lapses,
  }
  return {
    interval = interval,
    used_interval = used,
    base_factor = factor,
    grade_adjusted_factor = adjusted_factor,
    retrievability = retrievability,
    stored_retrievability = stored_retrievability,
    repetitions = repetitions,
    lapses = lapses,
    next_item = next_item,
    next_history = { factor = adjusted_factor, stability = interval + 0.0 },
  }
end

return model1
