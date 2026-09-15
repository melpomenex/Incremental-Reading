-- Shared numerics for the sm20 Lua port.
--
-- Pure Lua 5.1 (no bit library, no goto) so the same code runs under
-- LuaJIT (KOReader), plain lua5.1 (test harness), and later Luas.
--
-- Contents:
--   * py_round      - Python 3 round(): round-half-to-even, returns an integer
--                     valued number. Every Python `round()` in the canonical
--                     package (which Delphi's banker's Round matches) goes
--                     through this.
--   * 32-bit helpers - mulmod32/xor32/and32 in exact double arithmetic
--                     (all intermediates stay below 2^53).
--   * CPythonRandom - CPython's random.Random: MT19937 seeded exactly like
--                     `random.Random(0)` (init_by_array with key {0}), with
--                     CPython's random() (two draws -> 53-bit float). M2's
--                     capped-U-bin tail fix consumes this stream.

local floor = math.floor

local num = {}

-- ---------------------------------------------------------------------------
-- rounding
-- ---------------------------------------------------------------------------

-- Python 3 round(x) for floats: round-half-to-even. Exact binary halves hit
-- the tie branch; values like 2.675 (binary 2.674999...) take the normal
-- path, matching Python.
function num.py_round(x)
  local f = floor(x)
  local diff = x - f
  if diff > 0.5 then return f + 1 end
  if diff < 0.5 then return f end
  if f % 2 == 0 then return f end
  return f + 1
end

-- ---------------------------------------------------------------------------
-- exact 32-bit arithmetic in doubles
-- ---------------------------------------------------------------------------

local TWO32 = 4294967296.0
local SIX5536 = 65536.0

num.TWO32 = TWO32

-- (a * b) mod 2^32, exact for a, b in [0, 2^32).
function num.mulmod32(a, b)
  a = a % TWO32
  b = b % TWO32
  local ah = floor(a / SIX5536)
  local al = a - ah * SIX5536
  local bh = floor(b / SIX5536)
  local bl = b - bh * SIX5536
  -- the ah*bh term vanishes mod 2^32; keep the low 16 bits of the mid term
  local mid = (ah * bl + al * bh) % SIX5536
  return (mid * SIX5536 + al * bl) % TWO32
end

-- a XOR b for a, b in [0, 2^32).
function num.xor32(a, b)
  local r, bit_v = 0.0, 1.0
  for _ = 1, 32 do
    if (a % 2) ~= (b % 2) then r = r + bit_v end
    a = floor(a / 2)
    b = floor(b / 2)
    bit_v = bit_v * 2
  end
  return r
end

-- a AND b for a, b in [0, 2^32).
function num.and32(a, b)
  local r, bit_v = 0.0, 1.0
  for _ = 1, 32 do
    if a % 2 == 1 and b % 2 == 1 then r = r + bit_v end
    a = floor(a / 2)
    b = floor(b / 2)
    bit_v = bit_v * 2
  end
  return r
end

-- ---------------------------------------------------------------------------
-- CPython Random (MT19937)
-- ---------------------------------------------------------------------------

local MT_N = 624
local MT_M = 397
local MT_MATRIX_A = 2567483615        -- 0x9908b0df
local MT_UPPER = 2147483648.0         -- 0x80000000
local MT_LOWER = 2147483647.0         -- 0x7fffffff
local MT_MASK_B = 2636928640.0        -- 0x9d2c5680 (tempering)
local MT_MASK_C = 4022730752.0        -- 0xefc60000 (tempering)

local CPythonRandom = {}
CPythonRandom.__index = CPythonRandom

local function init_genrand(self, s)
  local mt = self.mt
  mt[0] = s % TWO32
  for i = 1, MT_N - 1 do
    local prev = mt[i - 1]
    mt[i] = (num.mulmod32(1812433253, num.xor32(prev, floor(prev / 1073741824.0))) + i) % TWO32
  end
  self.index = MT_N
end

local function init_by_array(self, key, key_length)
  local mt = self.mt
  init_genrand(self, 19650218)
  local i, j = 1, 0
  local k = math.max(MT_N, key_length)
  while k > 0 do
    local prev = mt[i - 1]
    mt[i] = (num.xor32(mt[i],
      num.mulmod32(1664525, num.xor32(prev, floor(prev / 1073741824.0))))
      + key[j] + j) % TWO32
    i = i + 1
    j = j + 1
    if i >= MT_N then mt[0] = mt[MT_N - 1]; i = 1 end
    if j >= key_length then j = 0 end
    k = k - 1
  end
  for _ = 0, MT_N - 2 do
    local prev = mt[i - 1]
    mt[i] = (num.xor32(mt[i],
      num.mulmod32(1566083941, num.xor32(prev, floor(prev / 1073741824.0))))
      - i) % TWO32
    i = i + 1
    if i >= MT_N then mt[0] = mt[MT_N - 1]; i = 1 end
  end
  mt[0] = MT_UPPER
  self.index = MT_N
end

function CPythonRandom.new(seed)
  local self = setmetatable({ mt = {}, index = MT_N }, CPythonRandom)
  -- CPython random_seed(int): |seed| split into 32-bit little-endian words;
  -- seed 0 yields the single-word key {0}.
  local key
  if seed == 0 then
    key = { [0] = 0.0 }
    init_by_array(self, key, 1)
  else
    error("CPythonRandom: only seed 0 is implemented (canonical usage)")
  end
  return self
end

function CPythonRandom:_twist()
  local mt = self.mt
  for i = 0, MT_N - 1 do
    local y = num.and32(mt[i], MT_UPPER) + num.and32(mt[(i + 1) % MT_N], MT_LOWER)
    local v = mt[(i + MT_M) % MT_N]
    v = num.xor32(v, floor(y / 2))
    if y % 2 == 1 then v = num.xor32(v, MT_MATRIX_A) end
    mt[i] = v
  end
  self.index = 0
end

function CPythonRandom:next_uint32()
  if self.index >= MT_N then
    self:_twist()
  end
  local y = self.mt[self.index]
  self.index = self.index + 1
  y = num.xor32(y, floor(y / 2048.0))                              -- y >> 11
  y = num.xor32(y, num.and32((y * 128.0) % TWO32, MT_MASK_B))      -- (y<<7) & 0x9d2c5680
  y = num.xor32(y, num.and32((y * 32768.0) % TWO32, MT_MASK_C))    -- (y<<15) & 0xefc60000
  y = num.xor32(y, floor(y / 262144.0))                            -- y >> 18
  return y
end

-- CPython random_random(): two tempered draws assembled into [0, 1).
function CPythonRandom:random()
  local a = floor(self:next_uint32() / 32.0)   -- >> 5
  local b = floor(self:next_uint32() / 64.0)   -- >> 6
  return (a * 67108864.0 + b) * (1.0 / 9007199254740992.0)
end

num.CPythonRandom = CPythonRandom

return num
