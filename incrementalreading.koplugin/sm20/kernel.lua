-- M4 — SM-20-proper FSRS review kernel (35-parameter), ported 1:1 from
-- sm20/kernel.py (decoded from sm20.exe; FUN_00af9420 and callees).
-- See the Python module's docstrings for the full provenance ([C]/[ASM]/[BIN]).

local math = math
local num = require("sm20.num")

local kernel = {}

-- 35 doubles at VA 0x10cad90, byte-extracted from the binary's .data [BIN].
kernel.P = {
  0.9286298950420208,   -- [0]  expert1 power-law base
  347.85204578386566,   -- [1]  mixture weight: S denominator (w1/w2 time term)
  0.30270230764837086,  -- [2]  mixture weight: D denominator for w1
  0.4078726801204931,   -- [3]  mixture weight: D denominator for w2
  767.8438603670941,    -- [4]  mixture weight: S denominator for w3
  7.894742385544259,    -- [5]  init_s default (unused)
  4.08242569493503,     -- [6]  init_s[0]
  1.996431220980246,    -- [7]  init_s[1]
  9.170585471775675,    -- [8]  init_s[2]
  1.1425608073008684,   -- [9]  init_s[3]
  17.65771045770738,    -- [10] init_s[4]
  77.77877780253718,    -- [11] init_s[5]
  0.5921926894783989,   -- [12] init_d default
  0.6895479373487655,   -- [13] init_d[0]
  0.6472785530963361,   -- [14] init_d[1]
  0.4208423230793679,   -- [15] init_d[2]
  0.5186353666458963,   -- [16] init_d[3]
  0.27244747048223983,  -- [17] init_d[4]
  0.3261492383691367,   -- [18] init_d[5]
  1.680034668443124,    -- [19] lapse stability: base scale
  5.928185533585771,    -- [20] lapse stability: S weight denominator
  2.0150955428514656,   -- [21] lapse stability: S multiplier
  0.2555216135743039,   -- [22] lapse stability: retrov denominator
  1.9926553104343092,   -- [23] lapse stability: retrov multiplier
  95.04137758278812,    -- [24] difficulty update: S weight denominator
  42.21989471200275,    -- [25] recall stability: blend high (easy items)
  3.1089639864486682,   -- [26] recall stability: blend low (hard items)
  1.3558071518966488,   -- [27] recall stability: base factor
  0.9250460852489478,   -- [28] recall stability: hard bonus base
  0.8538692150895362,   -- [29] recall stability: hard bonus weight
  0.9559110660552212,   -- [30] recall stability: hard bonus ratio denom
  -0.6915519353695037,  -- [31] recall stability: time exponent
  1.0037797256248404,   -- [32] recall stability: recall signal D coefficient
  1.393910494789472,    -- [33] recall stability: recall signal offset
  0.12374729387559685,  -- [34] recall stability: grade multiplier
}

local P = kernel.P

kernel.DAT_ZERO = 0.0
kernel.DAT_ONE = 1.0
kernel.DAT_0_9 = 0.9
kernel.DAT_2_0 = 2.0
kernel.DAT_ONE_SHIFT = 1.0
kernel.DAT_NEG0 = -0.0
kernel.DAT_DECAY = 0.10536051565782628   -- ln(10/9)

kernel.LN_2 = math.log(2.0)
kernel.LN_09 = math.log(0.9)
kernel.LOG2_09 = kernel.LN_09 / kernel.LN_2

kernel.MIN_INTERVAL = 1
kernel.MAX_INTERVAL = 44530
kernel.MIN_CLAMP = 0.7

-- ---------------------------------------------------------------------------
-- low-level helpers
-- ---------------------------------------------------------------------------

-- FUN_00af8a80: x / (x + y); 0.0 if x + y == 0. [C]
function kernel.sigmoid_ratio(x, y)
  local s = x + y
  if s == 0.0 then return 0.0 end
  return x / s
end

-- FUN_0040b0e0: Delphi Exp() = e^x, overflow-clamped. [C]
function kernel.delphi_exp(x)
  if x > 709.0 then return math.huge end
  if x < -745.0 then return 0.0 end
  return math.exp(x)
end

-- FUN_0040c140: Delphi Ln() = natural log. [C]
function kernel.delphi_ln(x)
  return math.log(x)
end

-- FUN_00477180 / FUN_004772a0: Delphi pow(base, exp). [C]
function kernel.delphi_pow(base, exp)
  if base > 0.0 then
    return kernel.delphi_exp(exp * kernel.delphi_ln(base))
  end
  return 0.0
end

-- XOR with -0.0 = IEEE-754 sign-bit negation. [C]
function kernel.sign_flip(value)
  return -value
end

function kernel.clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- ---------------------------------------------------------------------------
-- experts (the three forgetting curves in the mixture)
-- ---------------------------------------------------------------------------

-- FUN_00af8ac0: power-law forgetting curve. [C]
function kernel.expert1(p0, t, S)
  if not (0.0 < p0 and 0.0 < S) then
    return 0.0
  end
  local exp_pow = kernel.delphi_ln(p0 / kernel.DAT_0_9) / kernel.delphi_ln(kernel.DAT_2_0)
  local ratio = S / (S + t)
  return p0 * kernel.delphi_pow(ratio, exp_pow)
end

-- FUN_00af8bb0: shifted power-law forgetting. [C]
function kernel.expert2(t, S)
  if S <= 0.0 then return 0.0 end
  local shifted = t / S + kernel.DAT_ONE_SHIFT
  if not (0.0 < shifted) then return 0.0 end
  return kernel.delphi_pow(shifted, kernel.LOG2_09)
end

-- FUN_00af8c90: exponential forgetting. [C]
function kernel.expert3(t, S)
  if not (0.0 < S) then return 0.0 end
  local ratio = t / S
  return kernel.delphi_exp(kernel.sign_flip(ratio) * kernel.DAT_DECAY)
end

-- FUN_00af8d00: 3-expert weighted average -> retrievability proxy A. [C]
function kernel.expert_mixture(t, S, D)
  local e1 = kernel.expert1(P[1], t, S)   -- P[0]
  local e2 = kernel.expert2(t, S)
  local e3 = kernel.expert3(t, S)

  local s_weight = kernel.sigmoid_ratio(S, P[2])    -- P[1]
  local d_weight1 = kernel.sigmoid_ratio(D, P[3])   -- P[2]
  local d_weight2 = kernel.sigmoid_ratio(D, P[4])   -- P[3]
  local s_weight3 = kernel.sigmoid_ratio(S, P[5])   -- P[4]

  local w1 = ((kernel.DAT_ONE - s_weight) + d_weight1) / kernel.DAT_2_0
  local w2 = ((kernel.DAT_ONE - s_weight) + d_weight2) / kernel.DAT_2_0
  local w3 = s_weight3

  local w_sum = w1 + w2 + w3
  if w_sum ~= 0.0 then
    return (w1 * e1 + w2 * e2 + w3 * e3) / w_sum
  end
  return 0.0
end

-- ---------------------------------------------------------------------------
-- difficulty / stability updates
-- ---------------------------------------------------------------------------

-- FUN_00af90f0: difficulty update. [C]
function kernel.difficulty_update(D, S, A, grade)
  local w = kernel.sigmoid_ratio(S, P[25])            -- P[24]
  local target
  if grade > 2 then target = kernel.DAT_ONE else target = 0.0 end
  local D_new = w * D + (kernel.DAT_ONE - w) * (D - (target - A))
  return kernel.clamp(D_new, 0.0, 1.0)
end

-- FUN_00af9010: stability update for lapse (grade < 3). [C]
function kernel.lapse_stability(D, S, A)
  local base = (kernel.DAT_ONE - D) * P[20] + kernel.DAT_ONE   -- P[19]
  local w = kernel.sigmoid_ratio(S, P[21])                     -- P[20]
  local mult = w * P[22] + kernel.DAT_ONE                      -- P[21]
  local retro = kernel.sigmoid_ratio(kernel.DAT_ONE - A, P[23]) -- P[22]
  return base * mult + retro * P[24] + kernel.DAT_ONE          -- P[23]
end

-- FUN_00af91f0: stability update for successful recall (grade >= 3). [C]
function kernel.recall_stability(D, S, A, t, grade)
  local S_min = S
  if t > S then S_min = t end

  local hard_bonus
  if t < S and S > 0.0 then
    local t_over_S = t / S
    hard_bonus = P[29] + P[30] * kernel.sigmoid_ratio(t_over_S, P[31])  -- P[28..30]
  else
    hard_bonus = kernel.DAT_ONE
  end

  local time_factor
  if S_min > 0.0 then
    time_factor = kernel.delphi_pow(S_min, P[32])   -- P[31]
  else
    time_factor = 0.0
  end

  local inner_rs = P[33] * (kernel.DAT_ONE - D) + P[34]   -- P[32], P[33]
  local recall_signal = kernel.delphi_exp(kernel.sign_flip(inner_rs) * A)

  local grade_factor = (grade - 4) * P[35] + kernel.DAT_ONE   -- P[34]

  local blend = P[27] + (kernel.DAT_ONE - D) * (P[26] - P[27])  -- P[26], P[25]

  local inner = P[28] + (blend - P[28]) * time_factor * recall_signal * grade_factor  -- P[27]
  return S_min * hard_bonus * inner
end

-- ---------------------------------------------------------------------------
-- review kernel — main entry point (FUN_00af9420)
-- ---------------------------------------------------------------------------

function kernel.review_kernel(t, grade, D, S)
  local A = kernel.expert_mixture(t, S, D)
  local D_new = kernel.difficulty_update(D, S, A, grade)
  local S_new
  if grade < 3 then
    S_new = kernel.lapse_stability(D_new, S, A)
  else
    S_new = kernel.recall_stability(D_new, S, A, t, grade)
  end
  local ratio
  if S > 0.0 then ratio = S_new / S else ratio = 0.0 end
  return { S_new = S_new, D_new = D_new, A = A, ratio = ratio }
end

-- ---------------------------------------------------------------------------
-- item initialization (FUN_00ceb590 + FUN_00af8ed0 + FUN_00af8f70)
-- ---------------------------------------------------------------------------

-- 1-based table: init_s[g+1] = P[6+g], init_d[g+1] = P[13+g].
local INIT_S = { P[7], P[8], P[9], P[10], P[11], P[12] }
local INIT_D = { P[14], P[15], P[16], P[17], P[18], P[19] }

function kernel.init_new_item(grade)
  local g = kernel.clamp(grade, 0, 5)
  return { S = INIT_S[g + 1], D = INIT_D[g + 1] }
end

-- Stability to interval: clamp to [0.7, 44530], round, floor at 1. [C]
function kernel.compute_interval(S_new)
  local raw = math.max(kernel.MIN_CLAMP, math.min(kernel.MAX_INTERVAL, S_new))
  local iv = num.py_round(raw)
  if iv < kernel.MIN_INTERVAL then return kernel.MIN_INTERVAL end
  return iv
end

return kernel
