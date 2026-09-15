-- Per-item / per-collection state for the sm20 Lua port, ported 1:1 from
-- sm20/state.py. Plain tables; serialization via item_to_dict /
-- collection_to_dict (nil-valued fields are omitted, matching the Python
-- asdict-then-JSON view where None keys are dropped by the vector emitter).

local model1 = require("sm20.model1")
local model2 = require("sm20.model2")
local model3 = require("sm20.model3")
local arena_mod = require("sm20.arena")

local state = {}

-- ---------------------------------------------------------------------------
-- SM20State — per-item DSR scheduling state
-- ---------------------------------------------------------------------------

-- stability/difficulty are the M4 kernel's DSR state (the values persisted
-- between reviews), matching the canonical package.
function state.new_item_state()
  return {
    stability = 1.0,
    difficulty = 0.5,
    repetition = 0,
    lapses = 0,
    interval = 0.0,
    -- Scheduling-family markers item[+0xb7]/[+0xb9] — per-review scratch in
    -- the binary; persisted only because the binary keeps them in the item
    -- record. The pipeline never reads them across reviews.
    post_lapse_family = 0,
    lapse_ordinal = 0,
    -- The five models' stability outputs persisted at the last committed
    -- review (M1..M5 slot order), scored by ArenaState.observe at the NEXT
    -- review. nil until the item's first committed review.
    slot_stabilities = nil,
    m1_state = model1.new_item_state(),
    m1_history = nil,
    m2_state = model2.new_item_state(),
    m3_state = model3.new_item_state(),
  }
end

local ITEM_FIELDS = {
  "stability", "difficulty", "repetition", "lapses", "interval",
  "post_lapse_family", "lapse_ordinal",
  "slot_stabilities", "m1_history",
}

function state.item_to_dict(s)
  local out = {}
  for _, k in ipairs(ITEM_FIELDS) do
    local v = s[k]
    if v ~= nil then
      if k == "slot_stabilities" then
        local copy = {}
        for i = 1, #v do copy[i] = v[i] end
        out.slot_stabilities = copy
      elseif k == "m1_history" then
        out.m1_history = { factor = v.factor, stability = v.stability }
      else
        out[k] = v
      end
    end
  end
  out.m1_state = model1.new_item_state()
  for k, v in pairs(s.m1_state) do out.m1_state[k] = v end
  out.m2_state = model2.new_item_state()
  for k, v in pairs(s.m2_state) do out.m2_state[k] = v end
  out.m3_state = model3.new_item_state()
  for k, v in pairs(s.m3_state) do out.m3_state[k] = v end
  return out
end

function state.item_from_dict(d)
  local s = state.new_item_state()
  for _, k in ipairs(ITEM_FIELDS) do
    if d[k] ~= nil then
      if k == "slot_stabilities" then
        local copy = {}
        for i = 1, #d.slot_stabilities do copy[i] = d.slot_stabilities[i] end
        s.slot_stabilities = copy
      elseif k == "m1_history" then
        s.m1_history = { factor = d.m1_history.factor,
          stability = d.m1_history.stability }
      else
        s[k] = d[k]
      end
    end
  end
  for k, v in pairs(d.m1_state or {}) do s.m1_state[k] = v end
  for k, v in pairs(d.m2_state or {}) do s.m2_state[k] = v end
  for k, v in pairs(d.m3_state or {}) do s.m3_state[k] = v end
  return s
end

-- ---------------------------------------------------------------------------
-- SM20CollectionState — collection-wide state shared across items
-- ---------------------------------------------------------------------------

function state.new_collection_state()
  return {
    m2_optimizer = model2.ClassicM2Optimizer.new(),
    m3_matrices = model3.new_matrix_state(),
    arena = arena_mod.ArenaState.new(),
    m4_params = nil,  -- optional kernel parameter override (unused)
  }
end

function state.collection_to_dict(c)
  local out = {
    m2_optimizer = c.m2_optimizer:to_dict(),
    m3_matrices = c.m3_matrices:to_dict(),
    arena = c.arena:to_dict(),
  }
  if c.m4_params ~= nil then
    local copy = {}
    for i, v in ipairs(c.m4_params) do copy[i] = v end
    out.m4_params = copy
  end
  return out
end

function state.collection_from_dict(d)
  local c = state.new_collection_state()
  c.m2_optimizer = model2.ClassicM2Optimizer.from_dict(nil, d.m2_optimizer)
  c.m3_matrices = model3.new_matrix_state():from_dict(d.m3_matrices)
  c.arena = arena_mod.ArenaState.from_dict(nil, d.arena)
  if d.m4_params ~= nil then
    local copy = {}
    for i, v in ipairs(d.m4_params) do copy[i] = v end
    c.m4_params = copy
  end
  return c
end

return state
