-- Algorithm Arena ensemble blend — FUN_00cf4d50, ported from
-- sm20/ensemble.py. Weighted average of the five competitor models'
-- stability outputs. [C][BIN]

local num = require("sm20.num")
local weights_mod = require("sm20.weights")

local ensemble = {}

local ENSEMBLE_THRESHOLD = 0.0  -- DAT_00cf4e78 — weight-sum <= this -> M3

-- weights: table of 5 numbers, or nil for the compile-time defaults.
function ensemble.ensemble_stability(m1, m2, m3, m4, m5, w)
  local w1, w2, w3, w4, w5
  if w then
    w1, w2, w3, w4, w5 = w[1], w[2], w[3], w[4], w[5]
  else
    local d = weights_mod.DEFAULT_WEIGHTS
    w1, w2, w3, w4, w5 = d[1], d[2], d[3], d[4], d[5]
  end
  local total = w1 + w2 + w3 + w4 + w5
  if total <= ENSEMBLE_THRESHOLD then
    return m3  -- default = slot +0x7b (M3), matching FUN_00cf4d50
  end
  -- M1 and M2 are stored as int32 in the item struct, so they are rounded
  -- before weighting (matching (double)*(int*)(item+0x73/0x77)).
  local n = w1 * num.py_round(m1) + w2 * num.py_round(m2)
    + w3 * m3 + w4 * m4 + w5 * m5
  return n / total
end

return ensemble
