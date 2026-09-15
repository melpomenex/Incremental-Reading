local DataStorage = require("datastorage")
local Device = require("device")
local SQ3 = require("lua-ljsqlite3/init")

local sm20_state = require("sm20.state")
local sm20_json = require("sm20.json")

local db_location = DataStorage:getSettingsDir() .. "/incremental_reading.sqlite3"

local function serializeTable(val)
    if type(val) == "table" then
        local parts = {}
        for k, v in pairs(val) do
            table.insert(parts, string.format("%s=%s", k, tostring(v)))
        end
        return "TABLE:" .. table.concat(parts, ";")
    end
    return val
end

local function deserializeTable(val)
    if type(val) == "string" and val:sub(1, 6) == "TABLE:" then
        local t = {}
        for pair in val:sub(7):gmatch("([^;]+)") do
            local k, v = pair:match("([^=]+)=([^=]+)")
            if k and v then
                if tonumber(v) then
                    t[k] = tonumber(v)
                elseif v == "true" then
                    t[k] = true
                elseif v == "false" then
                    t[k] = false
                else
                    t[k] = v
                end
            end
        end
        return t
    end
    return val
end

-- Canonical-engine schema version. The previous version (20260530) stored a
-- simplified SM-20 state (stability/difficulty/repetition plus the old
-- interval/count matrix tables); this version adds the full per-item SRS
-- state (JSON), the shared collection state, and the fields the canonical
-- pipeline needs.
local DB_SCHEMA_VERSION = 20260915

local DB = {}

local SCHEMA = [[
    CREATE TABLE IF NOT EXISTS cards (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        text          TEXT NOT NULL,
        book_title    TEXT NOT NULL DEFAULT '',
        file_path     TEXT NOT NULL DEFAULT '',
        xpointer      TEXT DEFAULT NULL,
        page          INTEGER DEFAULT NULL,
        chapter       TEXT NOT NULL DEFAULT '',
        created_at    TEXT NOT NULL DEFAULT (datetime('now','localtime')),
        stability     REAL NOT NULL DEFAULT 2.0,
        difficulty    REAL NOT NULL DEFAULT 0.5,
        repetition    INTEGER NOT NULL DEFAULT 1,
        next_review   TEXT NOT NULL DEFAULT (datetime('now','localtime')),
        suspended     INTEGER NOT NULL DEFAULT 0,
        lapses        INTEGER NOT NULL DEFAULT 0,
        last_reviewed_at INTEGER DEFAULT NULL,
        interval_days REAL NOT NULL DEFAULT 0,
        srs_state     TEXT DEFAULT NULL
    );
    CREATE INDEX IF NOT EXISTS idx_cards_next_review ON cards(next_review);
    CREATE INDEX IF NOT EXISTS idx_cards_file_path ON cards(file_path);

    CREATE TABLE IF NOT EXISTS reviews (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        card_id         INTEGER NOT NULL,
        reviewed_at     TEXT NOT NULL DEFAULT (datetime('now','localtime')),
        grade           REAL NOT NULL,
        prev_stability  REAL NOT NULL,
        new_stability   REAL NOT NULL,
        prev_interval   REAL NOT NULL,
        new_interval    REAL NOT NULL,
        elapsed_days    REAL NOT NULL,
        FOREIGN KEY (card_id) REFERENCES cards(id) ON DELETE CASCADE
    );
    CREATE INDEX IF NOT EXISTS idx_reviews_card_id ON reviews(card_id);

    CREATE TABLE IF NOT EXISTS collection_state (
        id              INTEGER PRIMARY KEY CHECK (id = 1),
        state           TEXT NOT NULL
    );
]]

-- The old engine's interval_matrix/count_matrix tables are intentionally NOT
-- created or dropped: on upgraded databases they are left in place, unused,
-- so rolling back to the previous plugin version stays possible. Fresh
-- installs never get them.

-- ---------------------------------------------------------------------------
-- UTC helpers (timestamps in this plugin are UTC, os.date "!..." format)
-- ---------------------------------------------------------------------------

-- Howard Hinnant's days_from_civil: days since 1970-01-01, timezone-free.
local function days_from_civil(y, m, d)
    if m <= 2 then y = y - 1 end
    local era = math.floor(y / 400)
    local yoe = y - era * 400
    local mp = m + (m > 2 and -3 or 9)
    local doy = math.floor((153 * mp + 2) / 5) + d - 1
    local doe = yoe * 365 + math.floor(yoe / 4) - math.floor(yoe / 100) + doy
    return era * 146097 + doe - 719468
end

-- "YYYY-MM-DD HH:MM:SS" (UTC) -> epoch seconds; nil on parse failure.
local function parse_utc(text)
    if type(text) ~= "string" then return nil end
    local y, mo, d, h, mi, s = text:match("^(%d%d%d%d)-(%d%d)-(%d%d) (%d%d):(%d%d):(%d%d)$")
    if not y then
        y, mo, d = text:match("^(%d%d%d%d)-(%d%d)-(%d%d)")
        if not y then return nil end
        h, mi, s = 0, 0, 0
    end
    return days_from_civil(tonumber(y), tonumber(mo), tonumber(d)) * 86400
        + tonumber(h) * 3600 + tonumber(mi) * 60 + tonumber(s)
end

local function openDB()
    return SQ3.open(db_location)
end

-- ---------------------------------------------------------------------------
-- migration to the canonical engine
-- ---------------------------------------------------------------------------

local function column_exists(conn, table_name, column)
    local stmt = conn:prepare("PRAGMA table_info(" .. table_name .. ");")
    local row = stmt:step()
    while row do
        if row[2] == column then
            stmt:close()
            return true
        end
        row = stmt:step()
    end
    stmt:close()
    return false
end

-- Build the canonical per-item state for a card scheduled by the old engine.
-- repetition is 1-based there (fresh card = 1) and 0-based in the canonical
-- package, so it shifts by one; sub-model states start from canonical
-- defaults seeded with the migrated counters. last_review_day (the day-stamp
-- used by M1/M2/M3) comes from the recovered last-review epoch when known.
local function migrated_srs_state(stability, difficulty, repetition, lapses,
                                  last_reviewed_at)
    local s = sm20_state.new_item_state()
    s.stability = stability
    s.difficulty = difficulty
    s.repetition = math.max(0, repetition - 1)
    s.lapses = lapses
    s.interval = stability
    local prev_interval = math.max(1, math.floor(stability + 0.5))
    local last_review_day = -1
    if last_reviewed_at then
        last_review_day = math.floor(last_reviewed_at / 86400)
    end
    s.m1_state.repetitions = s.repetition
    s.m1_state.lapses = lapses
    s.m1_state.previous_interval = prev_interval
    s.m1_state.last_review_day = last_review_day
    s.m2_state.repetitions = s.repetition
    s.m2_state.lapses = lapses
    s.m2_state.previous_interval = prev_interval
    s.m2_state.last_review_day = last_review_day
    s.m3_state.repetitions = s.repetition
    s.m3_state.lapses = lapses
    s.m3_state.previous_interval = prev_interval
    s.m3_state.last_review_day = last_review_day
    s.m3_state.stability = stability
    s.m3_state.difficulty = difficulty
    return sm20_json.encode(sm20_state.item_to_dict(s))
end

local function migrate_to_canonical(conn)
    if column_exists(conn, "cards", "srs_state") then
        return  -- already migrated
    end
    conn:exec("BEGIN TRANSACTION;")
    conn:exec("ALTER TABLE cards ADD COLUMN srs_state TEXT DEFAULT NULL;")
    conn:exec("ALTER TABLE cards ADD COLUMN lapses INTEGER NOT NULL DEFAULT 0;")
    conn:exec("ALTER TABLE cards ADD COLUMN last_reviewed_at INTEGER DEFAULT NULL;")
    conn:exec("ALTER TABLE cards ADD COLUMN interval_days REAL NOT NULL DEFAULT 0;")

    -- Backfill: derive canonical state from the old engine's columns. The
    -- old grade scale stored "again" as 0.05 (the only failing grade), so
    -- lapses = reviews with grade < 0.3.
    local rows = conn:exec("SELECT id, stability, difficulty, repetition, next_review FROM cards;")
    if rows and rows[1] then
        local ids, stab, diff, rep, next_rev = rows[1], rows[2], rows[3], rows[4], rows[5]
        for i = 1, #ids do
            local card_id = tonumber(ids[i])
            local stability = tonumber(stab[i]) or 2.0
            local difficulty = tonumber(diff[i]) or 0.5
            local repetition = tonumber(rep[i]) or 1
            local lapses_stmt = conn:prepare(
                "SELECT COUNT(*) FROM reviews WHERE card_id = ? AND grade < 0.3;")
            lapses_stmt:bind(card_id)
            local lrow = lapses_stmt:step()
            local lapses = lrow and tonumber(lrow[1]) or 0
            lapses_stmt:close()

            -- Old engine scheduled next_review = last_review + stability
            -- days; recover the review instant from that.
            local last_reviewed_at
            local due_epoch = parse_utc(next_rev[i])
            if due_epoch then
                last_reviewed_at = math.floor(due_epoch - stability * 86400)
            end

            local srs_state = migrated_srs_state(stability, difficulty,
                repetition, lapses, last_reviewed_at)

            local upd = conn:prepare([[
                UPDATE cards SET srs_state = ?, lapses = ?, last_reviewed_at = ?,
                                  interval_days = ?
                WHERE id = ?;
            ]])
            upd:bind(srs_state, lapses, last_reviewed_at, stability, card_id)
            upd:step()
            upd:close()
        end
    end
    conn:exec("COMMIT;")
end

function DB:init()
    local conn = openDB()
    if Device:canUseWAL() then
        conn:exec("PRAGMA journal_mode=WAL;")
    else
        conn:exec("PRAGMA journal_mode=TRUNCATE;")
    end
    conn:exec(SCHEMA)
    local db_version = tonumber(conn:rowexec("PRAGMA user_version;"))
    if db_version > 0 and db_version < DB_SCHEMA_VERSION then
        pcall(migrate_to_canonical, conn)
        conn:exec(string.format("PRAGMA user_version=%d;", DB_SCHEMA_VERSION))
    elseif db_version == 0 then
        conn:exec(string.format("PRAGMA user_version=%d;", DB_SCHEMA_VERSION))
    end
    -- Migrate NULL/empty/broken dates (broken on Android by SQLite's localtime modifier) to Lua UTC now
    local now = os.date("!%Y-%m-%d %H:%M:%S")
    conn:exec(string.format("UPDATE cards SET next_review = '%s' WHERE next_review IS NULL OR next_review = '' OR next_review LIKE '%%localtime%%';", now))
    conn:exec(string.format("UPDATE cards SET created_at = '%s' WHERE created_at IS NULL OR created_at = '' OR created_at LIKE '%%localtime%%';", now))
    conn:close()
end

function DB:insertCard(text, book_title, file_path, xpointer, page, chapter)
    local conn = openDB()
    local stmt = conn:prepare([[
        INSERT INTO cards (text, book_title, file_path, xpointer, page, chapter, created_at, next_review)
        VALUES (?, ?, ?, ?, ?, ?, ?, ?);
    ]])
    local now = os.date("!%Y-%m-%d %H:%M:%S")
    local ser_xpointer = serializeTable(xpointer)
    stmt:bind(text, book_title, file_path, ser_xpointer, page, chapter, now, now)
    stmt:step()
    stmt:close()
    conn:close()
end

function DB:getDueCards()
    local conn = openDB()
    local stmt = conn:prepare([[
        SELECT id, text, book_title, file_path, xpointer, page, chapter,
               stability, difficulty, repetition, next_review,
               lapses, last_reviewed_at, interval_days, srs_state
        FROM cards
        WHERE next_review <= ? AND suspended = 0
        ORDER BY next_review ASC;
    ]])
    stmt:bind(os.date("!%Y-%m-%d %H:%M:%S"))
    local results = {}
    local row = stmt:step()
    while row do
        table.insert(results, {
            id          = tonumber(row[1]),
            text        = row[2],
            book_title  = row[3],
            file_path   = row[4],
            xpointer    = deserializeTable(row[5]),
            page        = tonumber(row[6]),
            chapter     = row[7],
            stability   = tonumber(row[8]) or 2.0,
            difficulty  = tonumber(row[9]) or 0.5,
            repetition  = tonumber(row[10]) or 1,
            next_review = row[11],
            lapses      = tonumber(row[12]) or 0,
            last_reviewed_at = row[13] and tonumber(row[13]) or nil,
            interval_days = tonumber(row[14]) or 0,
            srs_state   = row[15],
        })
        row = stmt:step()
    end
    stmt:close()
    conn:close()
    return results
end

function DB:recordReview(card_id, grade, prev_stability, new_stability, prev_interval, new_interval, elapsed_days)
    local conn = openDB()
    local stmt = conn:prepare([[
        INSERT INTO reviews (card_id, grade, prev_stability, new_stability, prev_interval, new_interval, elapsed_days)
        VALUES (?, ?, ?, ?, ?, ?, ?);
    ]])
    stmt:bind(card_id, grade, prev_stability, new_stability, prev_interval, new_interval, elapsed_days)
    stmt:step()
    stmt:close()
    conn:close()
end

-- Kept for API compatibility with older call sites.
function DB:updateCardSRS(card_id, stability, difficulty, repetition, next_review)
    local conn = openDB()
    local stmt = conn:prepare([[
        UPDATE cards SET stability = ?, difficulty = ?, repetition = ?, next_review = ?
        WHERE id = ?;
    ]])
    stmt:bind(stability, difficulty, repetition, next_review, card_id)
    stmt:step()
    stmt:close()
    conn:close()
end

function DB:updateCardText(card_id, new_text)
    local conn = openDB()
    local stmt = conn:prepare([[
        UPDATE cards SET text = ?
        WHERE id = ?;
    ]])
    stmt:bind(new_text, card_id)
    stmt:step()
    stmt:close()
    conn:close()
end

function DB:setCardSuspended(card_id, suspended)
    suspended = suspended and 1 or 0
    local conn = openDB()
    local stmt = conn:prepare([[
        UPDATE cards SET suspended = ?
        WHERE id = ?;
    ]])
    stmt:bind(suspended, card_id)
    stmt:step()
    stmt:close()
    conn:close()
end

function DB:getDueCount()
    local conn = openDB()
    local stmt = conn:prepare([[
        SELECT COUNT(*) FROM cards
        WHERE next_review <= ? AND suspended = 0;
    ]])
    stmt:bind(os.date("!%Y-%m-%d %H:%M:%S"))
    local row = stmt:step()
    local count = row and tonumber(row[1]) or 0
    stmt:close()
    conn:close()
    return count or 0
end

function DB:deleteCard(card_id)
    local conn = openDB()
    conn:exec("DELETE FROM reviews WHERE card_id = " .. tonumber(card_id) .. ";")
    conn:exec("DELETE FROM cards WHERE id = " .. tonumber(card_id) .. ";")
    conn:close()
end

function DB:getAllCards()
    local conn = openDB()
    local stmt = conn:prepare([[
        SELECT id, text, book_title, file_path, xpointer, page, chapter,
               stability, difficulty, repetition, next_review, suspended,
               interval_days, lapses
        FROM cards
        ORDER BY book_title ASC, id ASC;
    ]])
    local results = {}
    local row = stmt:step()
    while row do
        table.insert(results, {
            id          = tonumber(row[1]),
            text        = row[2],
            book_title  = row[3],
            file_path   = row[4],
            xpointer    = deserializeTable(row[5]),
            page        = tonumber(row[6]),
            chapter     = row[7],
            stability   = tonumber(row[8]) or 2.0,
            difficulty  = tonumber(row[9]) or 0.5,
            repetition  = tonumber(row[10]) or 1,
            next_review = row[11],
            suspended   = tonumber(row[12]) == 1,
            interval_days = tonumber(row[13]) or 0,
            lapses      = tonumber(row[14]) or 0,
        })
        row = stmt:step()
    end
    stmt:close()
    conn:close()
    return results
end

-- ---------------------------------------------------------------------------
-- collection state (M2 optimizer, M3 matrices, Arena weights)
-- ---------------------------------------------------------------------------

-- Returns the decoded collection state dict, or nil when none is stored or
-- the stored blob is unreadable (callers start from canonical defaults).
function DB:loadCollectionState()
    local conn = openDB()
    local ok, result = pcall(function()
        local stmt = conn:prepare("SELECT state FROM collection_state WHERE id = 1;")
        local row = stmt:step()
        stmt:close()
        if not row or not row[1] or row[1] == "" then return nil end
        return sm20_json.decode(row[1])
    end)
    conn:close()
    if ok then return result end
    return nil
end

function DB:saveCollectionState(state_dict)
    local conn = openDB()
    pcall(function()
        local stmt = conn:prepare([[
            INSERT OR REPLACE INTO collection_state (id, state) VALUES (1, ?);
        ]])
        stmt:bind(sm20_json.encode(state_dict))
        stmt:step()
        stmt:close()
    end)
    conn:close()
end

-- ---------------------------------------------------------------------------
-- batched review flush
-- ---------------------------------------------------------------------------

function DB:flushReviews(pending_reviews)
    if not pending_reviews or #pending_reviews == 0 then return end
    local conn = openDB()
    conn:exec("BEGIN TRANSACTION;")
    local review_stmt = conn:prepare([[
        INSERT INTO reviews (card_id, grade, prev_stability, new_stability, prev_interval, new_interval, elapsed_days)
        VALUES (?, ?, ?, ?, ?, ?, ?);
    ]])
    local card_stmt = conn:prepare([[
        UPDATE cards SET stability = ?, difficulty = ?, repetition = ?, next_review = ?,
                          lapses = ?, last_reviewed_at = ?, interval_days = ?, srs_state = ?
        WHERE id = ?;
    ]])
    for _, r in ipairs(pending_reviews) do
        review_stmt:bind(r.card_id, r.grade, r.prev_stability, r.new_stability,
                         r.prev_interval, r.new_interval, r.elapsed_days)
        review_stmt:step()
        review_stmt:clearbind():reset()
        card_stmt:bind(r.new_stability, r.new_difficulty, r.new_repetition,
                       r.next_review_date, r.new_lapses or 0,
                       r.last_reviewed_at, r.new_interval, r.srs_state,
                       r.card_id)
        card_stmt:step()
        card_stmt:clearbind():reset()
    end
    conn:exec("COMMIT;")
    review_stmt:close()
    card_stmt:close()
    conn:close()
end

function DB:isDuplicate(text, file_path, xpointer)
    local conn = openDB()
    local ser_xpointer = serializeTable(xpointer)
    local stmt
    if ser_xpointer then
        stmt = conn:prepare(
            "SELECT COUNT(*) FROM cards WHERE text = ? AND file_path = ? AND xpointer = ?;")
        stmt:bind(text, file_path, ser_xpointer)
    else
        stmt = conn:prepare(
            "SELECT COUNT(*) FROM cards WHERE text = ? AND file_path = ?;")
        stmt:bind(text, file_path)
    end
    local row = stmt:step()
    local count = row and tonumber(row[1]) or 0
    stmt:close()
    conn:close()
    return count > 0
end

function DB:resetDatabase()
    local conn = openDB()
    conn:exec("DROP TABLE IF EXISTS cards;")
    conn:exec("DROP TABLE IF EXISTS reviews;")
    conn:exec("DROP TABLE IF EXISTS interval_matrix;")
    conn:exec("DROP TABLE IF EXISTS count_matrix;")
    conn:exec("DROP TABLE IF EXISTS collection_state;")
    conn:exec("PRAGMA user_version=0;")
    conn:close()
    self:init()
end

function DB:getStatistics()
    local conn = openDB()
    local total_cards = tonumber(conn:rowexec("SELECT COUNT(*) FROM cards;")) or 0
    local stmt = conn:prepare([[
        SELECT COUNT(*) FROM cards
        WHERE next_review <= ? AND suspended = 0;
    ]])
    stmt:bind(os.date("!%Y-%m-%d %H:%M:%S"))
    local row = stmt:step()
    local due_today = row and tonumber(row[1]) or 0
    stmt:close()
    local total_reviews = tonumber(conn:rowexec("SELECT COUNT(*) FROM reviews;")) or 0
    local avg_interval = tonumber(conn:rowexec(
        "SELECT COALESCE(AVG(interval_days), 0) FROM cards WHERE interval_days > 0;"
    )) or 0

    local mature_cards = tonumber(conn:rowexec(
        "SELECT COUNT(*) FROM cards WHERE stability >= 21.0;"
    )) or 0

    -- Streak: consecutive days (ending today or yesterday) with >= 1 review
    local streak = 0
    local rows
    if conn.exec then
        rows = conn:exec(
            "SELECT DISTINCT substr(reviewed_at, 1, 10) AS d FROM reviews ORDER BY d DESC;"
        )
    end
    if rows and rows[1] then
        local today_str     = os.date("!%Y-%m-%d", os.time())
        local yesterday_str = os.date("!%Y-%m-%d", os.time() - 86400)
        local seen = {}
        for _, d in ipairs(rows[1]) do
            seen[d] = true
        end
        local cursor = today_str
        if not seen[today_str] then
            cursor = yesterday_str
        end
        while seen[cursor] do
            streak = streak + 1
            local y, m, d = cursor:match("^(%d+)-(%d+)-(%d+)$")
            local prev = os.date("!%Y-%m-%d",
                os.time({ year = tonumber(y), month = tonumber(m), day = tonumber(d), hour = 12 }) - 86400)
            cursor = prev
        end
    end

    conn:close()
    return {
        total_cards   = total_cards,
        due_today     = due_today,
        total_reviews = total_reviews,
        retention     = nil,  -- not tracked by the DB layer (computed by callers if needed)
        avg_interval  = avg_interval,
        mature_cards  = mature_cards,
        streak        = streak,
    }
end

DB:init()

return DB
