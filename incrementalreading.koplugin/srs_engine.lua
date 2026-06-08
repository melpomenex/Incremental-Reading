-- SM-20 Spaced Repetition Engine — Lua port
-- Ported from sm20-re/sm20_reference.py
-- Uses the V2 algorithm with Bayesian smoothing.

local math = math
local floor = math.floor
local log = math.log
local max = math.max
local min = math.min

local STABILITY_POWER = 2.90396936502257

local V2 = {
    stability_scale_max = 9.29,
    stability_scale_min = 1.3,
    anchor = 1.0,
    rep_power_offset = -0.08,
    rep_power_coeff = -0.31,
    base_offset = 1.04,
    base_bias = 0.07,
    penalty_slope = -1.88,
    penalty_intercept = 1.58,
    penalty_clamp = 600.0,
}

local INIT = {
    stability_scale_max = 15.0,
    stability_scale_min = 3.0,
    anchor = 1.0,
    rep_power_offset = -0.08,
    rep_power_coeff = -0.35,
    base_sub = 1.0,
    base_add = 1.0,
    penalty_slope = -2.0,
    penalty_intercept = 2.25,
    penalty_clamp = 600.0,
}

local BAYES = {
    prior_weight = 500.0,
    target_weight_scale = 10.0,
    neighbor_weight_denom = 1000.0,
    cube_weight = 3.0,
    neutral = 1.0,
}

local STABILITY_LOWER = -1.0
local STABILITY_CAP = 0.7
local STABILITY_MAX = 44530.0

local MATRIX_DIM = 21
local MATRIX_SIZE = MATRIX_DIM * MATRIX_DIM * MATRIX_DIM
local MATRIX_STRIDE_R = MATRIX_DIM * MATRIX_DIM
local MATRIX_STRIDE_S = MATRIX_DIM

local SM20Engine = {}

-------------------------------------------------------------------------------
-- Low-level helpers
-------------------------------------------------------------------------------

local function exp2_clamped(x)
    x = max(-38.0, min(38.0, x))
    return 2.0 ^ x
end

local function sigmoid_weight(x, y)
    local s = x + y
    if s == 0.0 then return 0.0 end
    return x / s
end

local function clamp(v, lo, hi)
    if v < lo then return lo end
    if v > hi then return hi end
    return v
end

-------------------------------------------------------------------------------
-- Stability pre-transform
-------------------------------------------------------------------------------

local function stability_pretransform(s)
    if s ~= s then return STABILITY_MAX end -- NaN
    if s == math.huge or s == -math.huge then return STABILITY_MAX end
    if s <= STABILITY_LOWER then return s end
    if s < STABILITY_CAP then return STABILITY_CAP end
    if s <= STABILITY_MAX then return s end
    return STABILITY_MAX
end

-------------------------------------------------------------------------------
-- Index conversions
-------------------------------------------------------------------------------

local function difficulty_to_index(d)
    if d < 0.0 then return 10 end
    return min(10, floor(d * 19.0) + 1)
end

local function stability_to_index(s)
    s = stability_pretransform(s)
    local diff = s - 2.0
    if diff < 0.0 then diff = 0.0 end
    local result = diff ^ (1.0 / STABILITY_POWER)
    return clamp(floor(result) + 1, 1, 20)
end

local function stability_to_transformed(s_idx)
    return (s_idx - 1) ^ STABILITY_POWER + 2.0
end

local function retrievability_to_index(r)
    return clamp(floor(2.0 ^ (r * 20.0)), 0, 20)
end

local function difficulty_to_fraction(d_idx)
    return d_idx / 20.0
end

local function repetition_to_fraction(r)
    return (r - 1) / 19.0
end

-------------------------------------------------------------------------------
-- Rounding
-------------------------------------------------------------------------------

local function apply_rounding(interval, flags)
    local upper, lower
    if flags >= 4 or (flags % 4 >= 2) then
        upper, lower = 20.0, 0.8
    else
        upper, lower = 2.0, 0.5
    end
    if interval > upper then return upper end
    if interval <= lower and interval ~= lower then return lower end
    return interval
end

-------------------------------------------------------------------------------
-- Interval formulas
-------------------------------------------------------------------------------

local function interval_v2(rep_fraction, stability_transformed, difficulty_fraction)
    local c = V2
    local scale = c.stability_scale_min
        + (c.stability_scale_max - c.stability_scale_min) * (c.anchor - rep_fraction)
    local power = c.rep_power_offset + rep_fraction * (c.rep_power_coeff - c.rep_power_offset)
    local base = (scale - c.base_offset) * (stability_transformed ^ power) + c.base_bias
    local penalty = min(c.penalty_clamp, rep_fraction * c.penalty_slope + c.penalty_intercept)
    local exponent = (-penalty) * difficulty_fraction
    return base * exp2_clamped(exponent)
end

local function interval_initial(rep_fraction, stability_transformed, difficulty_fraction)
    local c = INIT
    local scale = c.stability_scale_min
        + (c.stability_scale_max - c.stability_scale_min) * (c.anchor - rep_fraction)
    local power = c.rep_power_offset + rep_fraction * (c.rep_power_coeff - c.rep_power_offset)
    local base = (scale - c.base_sub) * (stability_transformed ^ power) + c.base_add
    local penalty = min(c.penalty_clamp, rep_fraction * c.penalty_slope + c.penalty_intercept)
    local exponent = (-penalty) * difficulty_fraction
    local result = base * exp2_clamped(exponent)
    result = apply_rounding(result, 4)
    return max(1.0, result)
end

-------------------------------------------------------------------------------
-- Matrix index helper
-------------------------------------------------------------------------------

local function matrix_flat_index(r, s, d)
    return r * MATRIX_STRIDE_R + s * MATRIX_STRIDE_S + d
end

-------------------------------------------------------------------------------
-- Bayesian core
-------------------------------------------------------------------------------

local function bayesian_smooth(r_idx, s_idx, d_idx, interval_matrix, count_matrix)
    local b = BAYES

    local rep_fraction = r_idx / 19.0
    local stab_transformed = (max(s_idx, 0)) ^ STABILITY_POWER + 2.0
    local diff_fraction = (d_idx + 1) / 20.0

    local prior = interval_initial(rep_fraction, stab_transformed, diff_fraction)

    local target_flat = matrix_flat_index(r_idx, s_idx, d_idx) + 1
    local target_interval = interval_matrix[target_flat] or 0.0
    local target_count = count_matrix[target_flat] or 0

    local neighbor_sum = 0.0
    local neighbor_count = 0

    local r_lo = max(0, r_idx - 1)
    local r_hi = min(MATRIX_DIM - 1, r_idx + 1)
    local s_lo = max(0, s_idx - 1)
    local s_hi = min(MATRIX_DIM - 1, s_idx + 1)
    local d_lo = max(0, d_idx - 1)
    local d_hi = min(MATRIX_DIM - 1, d_idx + 1)

    for nr = r_lo, r_hi do
        for ns = s_lo, s_hi do
            for nd = d_lo, d_hi do
                if nr * ns * nd == 0 then goto continue end
                local n_flat = matrix_flat_index(nr, ns, nd) + 1
                local c = count_matrix[n_flat] or 0
                if c > 0 then
                    neighbor_sum = neighbor_sum + (interval_matrix[n_flat] or 0.0) * c
                    neighbor_count = neighbor_count + c
                end
                ::continue::
            end
        end
    end

    local tw = sigmoid_weight(target_count, b.prior_weight) * b.target_weight_scale
    local nw = sigmoid_weight(neighbor_count, b.neighbor_weight_denom)

    local total = neighbor_count + 1
    local avg = (target_interval + neighbor_sum) / total

    local numerator = prior + target_interval * tw + avg * nw * b.cube_weight
    local denominator = tw + b.neutral + nw * b.cube_weight

    if denominator == 0.0 then return prior end
    return numerator / denominator
end

-------------------------------------------------------------------------------
-- Grade mapping
-------------------------------------------------------------------------------

local GRADE_QUALITY = {
    again = 0.05,
    hard  = 0.60,
    good  = 0.78,
    easy  = 0.92,
}

local SUCCESS_MULTIPLIER = {
    again = 1.0,
    hard  = 0.85,
    good  = 1.0,
    easy  = 1.15,
}

-------------------------------------------------------------------------------
-- Main engine API
-------------------------------------------------------------------------------

function SM20Engine:initCard()
    return {
        stability  = 2.0,
        difficulty = 0.5,
        repetition = 1,
    }
end

function SM20Engine:review(card, grade_name, interval_matrix, count_matrix)
    local quality = GRADE_QUALITY[grade_name] or 0.78
    local stability = stability_pretransform(card.stability)
    local difficulty = card.difficulty
    local repetition = card.repetition

    local new_stability
    local new_difficulty = clamp(difficulty + (0.7 - quality) * 0.18, 0.0, 1.0)
    local new_repetition

    if grade_name == "again" then
        new_repetition = 1
        local decayed = max(0.5, stability * 0.35)
        new_stability = clamp(decayed / 1.15, 0.5, 3.0)
    else
        new_repetition = clamp(repetition + 1, 1, 20)

        local d_idx = clamp(difficulty_to_index(difficulty) - 1, 0, 19)
        local s_idx = clamp(stability_to_index(stability) - 1, 0, 19)
        local r_idx = clamp(repetition - 1, 0, 19)

        local rep_frac = repetition_to_fraction(repetition)
        local stab_xform = stability_to_transformed(stability_to_index(stability))
        local diff_frac = difficulty_to_fraction(difficulty_to_index(difficulty))

        local sinc = interval_v2(rep_frac, stab_xform, diff_frac)

        if interval_matrix and count_matrix then
            local target_flat = matrix_flat_index(r_idx, s_idx, d_idx) + 1
            local target_count = count_matrix[target_flat] or 0
            if target_count > 0 then
                sinc = bayesian_smooth(r_idx, s_idx, d_idx, interval_matrix, count_matrix)
            end
        end

        local base_stability = stability * sinc
        local mult = SUCCESS_MULTIPLIER[grade_name] or 1.0
        new_stability = clamp(base_stability * mult, 1.0, STABILITY_MAX)
    end

    local new_interval = new_stability

    return {
        card_id        = card.id,
        grade          = quality,
        prev_stability = stability,
        new_stability  = new_stability,
        prev_interval  = card.stability,
        new_interval   = new_interval,
        new_difficulty = new_difficulty,
        new_repetition = new_repetition,
        elapsed_days   = card.stability,
        next_review_offset_days = new_interval,
    }
end

function SM20Engine:recordIntoMatrix(card, result, interval_matrix, count_matrix)
    if not interval_matrix or not count_matrix then return end

    local stability = stability_pretransform(card.stability)
    local difficulty = card.difficulty
    local repetition = card.repetition

    local d_idx = clamp(difficulty_to_index(difficulty) - 1, 0, 19)
    local s_idx = clamp(stability_to_index(stability) - 1, 0, 19)
    local r_idx = clamp(repetition - 1, 0, 19)

    local flat = matrix_flat_index(r_idx, s_idx, d_idx) + 1
    local old_count = count_matrix[flat] or 0
    local old_interval = interval_matrix[flat] or 0.0

    count_matrix[flat] = old_count + 1
    interval_matrix[flat] = (old_interval * old_count + result.new_interval) / (old_count + 1)
end

return SM20Engine
