-- M5 — analytic stability model (FSRS slot), ported 1:1 from sm20/model5.py.
-- Orchestrator FUN_00ce71b0 -> ce6490/ce6960/ce68e0/ce66a0/ce6530; all
-- constants [BIN] from param block 0x10e8e90.

local math = math

local model5 = {}

local function clamp(v, lo, hi)
  if v < lo then return lo end
  if v > hi then return hi end
  return v
end

-- idx: grade<3 -> 1, ==3 -> 2, ==4 -> 3, else -> 4 (1-based table below)
local DEPTH = { 1.0, 2.0, 3.0, 4.0 }

function model5.model_5(t, grade, S_old)
  local retrov = ((t / S_old) * 0.2345679012 + 1.0) ^ -0.5
  local idx
  if grade < 3 then
    idx = 1
  elseif grade == 3 then
    idx = 2
  elseif grade == 4 then
    idx = 3
  else
    idx = 4
  end
  local scale = clamp((7.1949 - math.exp(0.5345 * 3.0)) + 1.0, 1.0, 10.0)
  local depth = -1.4604 * (DEPTH[idx] - 3.0)
  local blend = S_old + depth * (10.0 - S_old) / 9.0
  local S_new = clamp(0.0046 * scale + 0.9954 * blend, 1.0, 10.0)
  if idx == 1 then  -- forgot
    -- ce66a0(D_new, S, retrov): D_new for the ^-0.11 base, S for (x+1)^0.29605
    local product = (
      (S_new ^ -0.11)
      * (((S_old + 1) ^ 0.29605) - 1)
      * math.exp(2.2698 * (1 - retrov))
      * 1.9395
    )
    return clamp(product, 0.1, S_old)
  end
  local gate1 = idx == 2 and 0.2315 or 1.0  -- remembered
  local gate2 = idx == 4 and 2.9898 or 1.0
  local inner = (
    (11 - S_new)
    * (S_old ^ -0.1192)
    * (math.exp(1.01925 * (1 - retrov)) - 1)
    * gate1
    * gate2
    * math.exp(1.54575)
    + 1.0
  )
  return S_old * inner
end

return model5
