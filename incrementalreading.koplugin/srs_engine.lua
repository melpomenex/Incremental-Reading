-- SM-20 Spaced Repetition Engine — plugin facade over the canonical port.
--
-- The scheduling math lives in sm20/ (the 1:1 Lua port of the canonical
-- sm20/ Python package: five models, Algorithm Arena ensemble, finalization
-- pipeline, runtime weight adaptation). This facade maps the plugin's
-- four-button UI onto SuperMemo grades 0-5 and adapts the persistence
-- representation (per-card state, collection state, elapsed days).

local pipeline = require("sm20.pipeline")
local state_mod = require("sm20.state")
local sm20_json = require("sm20.json")

local math = math

local SM20Engine = {}

-- Four-button UI -> SuperMemo grade (0-5; <3 = lapse). Grade 1 =
-- "incorrect, recalled with difficulty" — the conventional fail mapping.
-- Grades 0 and 2 are unused by this UI.
SM20Engine.GRADE_TO_SM = {
    again = 1,
    hard  = 3,
    good  = 4,
    easy  = 5,
}

-- Default forgetting index (percent), matching the canonical default.
SM20Engine.DEFAULT_FI = 10

-------------------------------------------------------------------------------
-- Collection state
-------------------------------------------------------------------------------

function SM20Engine.newCollectionState()
    return state_mod.new_collection_state()
end

-- Decode a collection state dict loaded from the database; corrupt rows
-- fall back to canonical defaults rather than breaking the session.
function SM20Engine.collectionFromDict(dict)
    local ok, coll = pcall(state_mod.collection_from_dict, dict)
    if ok then
        coll.arena:sanitized()
        return coll
    end
    return state_mod.new_collection_state()
end

function SM20Engine.collectionToDict(collection)
    return state_mod.collection_to_dict(collection)
end

-------------------------------------------------------------------------------
-- Per-card state
-------------------------------------------------------------------------------

-- Decode a card's persisted SRS state. Fresh or unreadable rows get a fresh
-- canonical state (never-reviewed semantics).
function SM20Engine.decodeCardSRS(card)
    if card.srs then return card.srs end
    if card.srs_state and card.srs_state ~= "" then
        local ok, dict = pcall(sm20_json.decode, card.srs_state)
        if ok then
            local ok2, s = pcall(state_mod.item_from_dict, dict)
            if ok2 then
                card.srs = s
                return s
            end
        end
    end
    local s = state_mod.new_item_state()
    card.srs = s
    return s
end

-- Kept for API compatibility with older call sites.
function SM20Engine.initCard()
    return state_mod.new_item_state()
end

-------------------------------------------------------------------------------
-- Time inputs (design D7)
-------------------------------------------------------------------------------

-- Days since the card's last committed review (0 for never-reviewed cards).
function SM20Engine.elapsedDays(card, now)
    now = now or os.time()
    if card.last_reviewed_at then
        local elapsed = (now - card.last_reviewed_at) / 86400.0
        if elapsed < 0.0 then elapsed = 0.0 end
        return elapsed
    end
    return 0.0
end

-- Day counter for the M1/M2/M3 day-stamped state: days since the Unix epoch.
function SM20Engine.today()
    return math.floor(os.time() / 86400)
end

-------------------------------------------------------------------------------
-- Review & preview
-------------------------------------------------------------------------------

-- opts (all optional): { today, elapsed_days, card_state, fi }
-- Runs a COMMITTED review: mutates the card's SRS state and the collection
-- state (Arena weights, M2 optimizer, M3 matrices) and returns the row the
-- batched flush persists.
function SM20Engine:review(card, grade_name, collection, opts)
    opts = opts or {}
    local grade = SM20Engine.GRADE_TO_SM[grade_name] or 4
    local state = opts.card_state or SM20Engine.decodeCardSRS(card)
    local now = os.time()
    local elapsed_days = opts.elapsed_days
    if elapsed_days == nil then
        elapsed_days = SM20Engine.elapsedDays(card, now)
    end
    local today = opts.today or SM20Engine.today()
    local fi = opts.fi or SM20Engine.DEFAULT_FI

    local prev_stability = state.stability
    local prev_interval = state.interval
    if prev_interval == 0.0 then prev_interval = card.interval_days or 0.0 end

    local res = pipeline.review(state, grade, elapsed_days, fi, collection,
        today, { commit = true })
    card.srs = state
    -- mirror the persisted row so same-session re-reviews and the UI see
    -- fresh values
    card.last_reviewed_at = now
    card.stability = res.stability
    card.difficulty = res.difficulty
    card.repetition = state.repetition
    card.lapses = state.lapses
    card.interval_days = res.interval

    return {
        card_id        = card.id,
        grade          = grade,               -- integer SuperMemo grade
        prev_stability = prev_stability,
        new_stability  = res.stability,
        prev_interval  = prev_interval,
        new_interval   = res.interval,
        elapsed_days   = elapsed_days,
        new_difficulty = res.difficulty,
        new_repetition = state.repetition,
        new_lapses     = state.lapses,
        last_reviewed_at = now,
        next_review_offset_days = res.interval,
        srs_state      = sm20_json.encode(state_mod.item_to_dict(state)),
    }
end

-- Read-only preview: the deterministic finalized interval for each grade.
-- Never mutates the card or collection state (pipeline commit=false).
function SM20Engine:preview(card, grade_name, collection, opts)
    opts = opts or {}
    local grade = SM20Engine.GRADE_TO_SM[grade_name] or 4
    local state = opts.card_state or SM20Engine.decodeCardSRS(card)
    local elapsed_days = opts.elapsed_days
    if elapsed_days == nil then
        elapsed_days = SM20Engine.elapsedDays(card)
    end
    local today = opts.today or SM20Engine.today()
    local fi = opts.fi or SM20Engine.DEFAULT_FI

    local res = pipeline.review(state, grade, elapsed_days, fi, collection,
        today, { commit = false })
    return {
        next_review_offset_days = res.interval,
    }
end

-------------------------------------------------------------------------------
-- Formatting
-------------------------------------------------------------------------------

-- Compact human-readable interval, e.g. "10m", "5h", "3d", "2w", "1mo", "1y".
function SM20Engine.formatInterval(days)
    days = tonumber(days)
    if days == nil or days ~= days then return "?" end -- NaN guard
    if days < 0 then days = 0 end
    if days < 1 / 60 then return "<1m" end
    if days < 1 then
        local hours = math.floor(days * 24 + 0.5)
        if hours < 1 then return "<1h" end
        return hours .. "h"
    end
    if days < 30 then
        return math.floor(days + 0.5) .. "d"
    end
    if days < 365 then
        return math.floor(days / 30 + 0.5) .. "mo"
    end
    return string.format("%.1fy", days / 365)
end

return SM20Engine
