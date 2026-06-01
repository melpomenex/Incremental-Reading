local DataStorage = require("datastorage")
local Device = require("device")
local SQ3 = require("lua-ljsqlite3/init")
local Util = require("ffi/util")

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
local DB_SCHEMA_VERSION = 20260530

local UFACTOR = {
    13.822076, 8.212571, 6.056511, 4.879609, 4.126662,
    3.598557, 3.205138, 2.899285, 2.653822, 2.451912,
    2.282528, 2.138131, 2.013379, 1.904376, 1.808207,
    1.722649, 1.645970, 1.576804, 1.514055, 1.456836,
}

local MATRIX_DIM = 21
local MATRIX_SIZE = MATRIX_DIM * MATRIX_DIM * MATRIX_DIM -- 9261

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
        suspended     INTEGER NOT NULL DEFAULT 0
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

    CREATE TABLE IF NOT EXISTS interval_matrix (
        r_idx    INTEGER NOT NULL,
        s_idx    INTEGER NOT NULL,
        d_idx    INTEGER NOT NULL,
        value    REAL NOT NULL,
        PRIMARY KEY (r_idx, s_idx, d_idx)
    );

    CREATE TABLE IF NOT EXISTS count_matrix (
        r_idx    INTEGER NOT NULL,
        s_idx    INTEGER NOT NULL,
        d_idx    INTEGER NOT NULL,
        value    INTEGER NOT NULL,
        PRIMARY KEY (r_idx, s_idx, d_idx)
    );
]]

local function openDB()
    return SQ3.open(db_location)
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
    if db_version == 0 then
        self:seedMatrix(conn)
        conn:exec(string.format("PRAGMA user_version=%d;", DB_SCHEMA_VERSION))
    end
    -- Migrate NULL/empty/broken dates (broken on Android by SQLite's localtime modifier) to Lua UTC now
    local now = os.date("!%Y-%m-%d %H:%M:%S")
    conn:exec(string.format("UPDATE cards SET next_review = '%s' WHERE next_review IS NULL OR next_review = '' OR next_review LIKE '%%localtime%%';", now))
    conn:exec(string.format("UPDATE cards SET created_at = '%s' WHERE created_at IS NULL OR created_at = '' OR created_at LIKE '%%localtime%%';", now))
    conn:close()
end

function DB:seedMatrix(conn)
    for r = 0, MATRIX_DIM - 2 do -- 0..19
        for d = 0, 19 do
            local val = UFACTOR[d + 1]
            conn:exec(string.format(
                "INSERT OR IGNORE INTO interval_matrix (r_idx, s_idx, d_idx, value) VALUES (%d, %d, %d, %.6f);",
                r, r, d, val))
        end
    end
    conn:exec("INSERT OR IGNORE INTO count_matrix SELECT r_idx, s_idx, d_idx, 0 FROM interval_matrix;")
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
               stability, difficulty, repetition, next_review
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
               stability, difficulty, repetition, next_review
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
        })
        row = stmt:step()
    end
    stmt:close()
    conn:close()
    return results
end

function DB:flushReviews(pending_reviews)
    if not pending_reviews or #pending_reviews == 0 then return end
    local conn = openDB()
    conn:exec("BEGIN TRANSACTION;")
    local review_stmt = conn:prepare([[
        INSERT INTO reviews (card_id, grade, prev_stability, new_stability, prev_interval, new_interval, elapsed_days)
        VALUES (?, ?, ?, ?, ?, ?, ?);
    ]])
    local card_stmt = conn:prepare([[
        UPDATE cards SET stability = ?, difficulty = ?, repetition = ?, next_review = ?
        WHERE id = ?;
    ]])
    for _, r in ipairs(pending_reviews) do
        review_stmt:bind(r.card_id, r.grade, r.prev_stability, r.new_stability,
                         r.prev_interval, r.new_interval, r.elapsed_days)
        review_stmt:step()
        review_stmt:clearbind():reset()
        card_stmt:bind(r.new_stability, r.new_difficulty, r.new_repetition,
                       r.next_review_date, r.card_id)
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
    local avg_interval = tonumber(conn:rowexec([[
        SELECT COALESCE(AVG(stability), 0) FROM cards WHERE stability > 0;
    ]])) or 0
    conn:close()
    return {
        total_cards   = total_cards,
        due_today     = due_today,
        total_reviews = total_reviews,
        avg_interval  = avg_interval,
    }
end

function DB:loadIntervalMatrix()
    local conn = openDB()
    local interval_matrix = {}
    local count_matrix = {}
    for i = 1, MATRIX_SIZE do
        interval_matrix[i] = 0.0
        count_matrix[i] = 0
    end
    local stmt = conn:prepare([[
        SELECT im.r_idx, im.s_idx, im.d_idx, im.value, COALESCE(cm.value, 0)
        FROM interval_matrix im
        LEFT JOIN count_matrix cm ON im.r_idx = cm.r_idx AND im.s_idx = cm.s_idx AND im.d_idx = cm.d_idx;
    ]])
    local row = stmt:step()
    while row do
        local r, s, d = row[1], row[2], row[3]
        local flat = r * MATRIX_DIM * MATRIX_DIM + s * MATRIX_DIM + d + 1
        interval_matrix[flat] = row[4]
        count_matrix[flat] = row[5]
        row = stmt:step()
    end
    stmt:close()
    conn:close()
    return interval_matrix, count_matrix
end

function DB:saveIntervalMatrix(interval_matrix, count_matrix)
    local conn = openDB()
    conn:exec("BEGIN TRANSACTION;")
    local del_iv = conn:prepare("DELETE FROM interval_matrix;")
    del_iv:step()
    del_iv:close()
    local del_ct = conn:prepare("DELETE FROM count_matrix;")
    del_ct:step()
    del_ct:close()
    local iv_stmt = conn:prepare("INSERT INTO interval_matrix (r_idx, s_idx, d_idx, value) VALUES (?, ?, ?, ?);")
    local ct_stmt = conn:prepare("INSERT INTO count_matrix (r_idx, s_idx, d_idx, value) VALUES (?, ?, ?, ?);")
    for r = 0, MATRIX_DIM - 1 do
        for s = 0, MATRIX_DIM - 1 do
            for d = 0, MATRIX_DIM - 1 do
                local flat = r * MATRIX_DIM * MATRIX_DIM + s * MATRIX_DIM + d + 1
                local iv = interval_matrix[flat]
                local ct = count_matrix[flat]
                if iv and iv ~= 0 then
                    iv_stmt:bind(r, s, d, iv)
                    iv_stmt:step()
                    iv_stmt:clearbind():reset()
                    ct_stmt:bind(r, s, d, ct or 0)
                    ct_stmt:step()
                    ct_stmt:clearbind():reset()
                end
            end
        end
    end
    iv_stmt:close()
    ct_stmt:close()
    conn:exec("COMMIT;")
    conn:close()
end

DB:init()

return DB
