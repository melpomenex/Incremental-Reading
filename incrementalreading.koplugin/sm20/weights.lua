-- Algorithm Arena weights — compile-time defaults, ported from
-- sm20/weights.py (FUN_00af4580, [ASM][BIN], live-confirmed).

local weights = {}

-- Slot order matches the item struct offsets in the binary:
-- M1 SM-2 (+0x73), M2 SM-15 (+0x77), M3 SM-19 (+0x7b), M4 SM-20 (+0x83),
-- M5 FSRS (+0x8b).
weights.MODEL_NAMES = { "SM-2", "SM-15", "SM-19", "SM-20", "FSRS" }

-- FUN_00af4580 compile-time defaults [ASM][BIN].
weights.DEFAULT_WEIGHTS = { 6.0, 14.0, 45.0, 25.0, 10.0 }

weights.WEIGHT_SUM = 100.0

-- The runtime adaptation machinery lives in sm20/arena.lua; this module is
-- just the layer-1 defaults (plus names).

return weights
