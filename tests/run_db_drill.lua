-- Upgrade drill: build an old-engine database fixture, run the migration,
-- drive a 10-review canonical session through the facade, reopen, and check
-- persistence + post-lapse behavior + Arena adaptation.
--
-- Uses tests/stub/ (sqlite3-CLI-backed lua-ljsqlite3, datastorage, device)
-- so no KOReader installation is required. Run: lua5.1 tests/run_db_drill.lua

local script = arg and arg[0] or "tests/run_db_drill.lua"
local root = script:match("^(.*)tests[/\\]run_db_drill%.lua$") or "./"
if root == "" then root = "./" end

local tmpdir = "/tmp/sm20_db_drill_" .. string.format("%d_%d", os.time(),
  math.floor(os.clock() * 100000))
os.execute('mkdir -p "' .. tmpdir .. '"')

package.preload["datastorage"] = function()
  return { getSettingsDir = function() return tmpdir end }
end
package.preload["device"] = function()
  return { canUseWAL = function() return false end }
end

package.path = root .. "tests/stub/?.lua;" .. root .. "tests/stub/?/init.lua;"
  .. root .. "incrementalreading.koplugin/?.lua;" .. package.path

local dbpath = tmpdir .. "/incremental_reading.sqlite3"

local pass, fail = 0, 0
local function check(name, cond, detail)
  if cond then
    pass = pass + 1
    print("  ok  " .. name)
  else
    fail = fail + 1
    print("FAIL  " .. name .. (detail and ("  [" .. tostring(detail) .. "]") or ""))
  end
end

local function run_sql_file(path, file)
  os.execute(string.format('sqlite3 -batch -bail "%s" < "%s"', path, file))
end

-- ---------------------------------------------------------------------------
-- 1. fixture: old-engine database (schema version 20260530)
-- ---------------------------------------------------------------------------

local fixture = tmpdir .. "/fixture.sql"
local f = io.open(fixture, "w")
f:write([[
CREATE TABLE cards (
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
CREATE TABLE reviews (
    id              INTEGER PRIMARY KEY AUTOINCREMENT,
    card_id         INTEGER NOT NULL,
    reviewed_at     TEXT NOT NULL DEFAULT (datetime('now','localtime')),
    grade           REAL NOT NULL,
    prev_stability  REAL NOT NULL,
    new_stability   REAL NOT NULL,
    prev_interval   REAL NOT NULL,
    new_interval    REAL NOT NULL,
    elapsed_days    REAL NOT NULL
);
CREATE TABLE interval_matrix (
    r_idx INTEGER NOT NULL, s_idx INTEGER NOT NULL, d_idx INTEGER NOT NULL,
    value REAL NOT NULL, PRIMARY KEY (r_idx, s_idx, d_idx)
);
CREATE TABLE count_matrix (
    r_idx INTEGER NOT NULL, s_idx INTEGER NOT NULL, d_idx INTEGER NOT NULL,
    value INTEGER NOT NULL, PRIMARY KEY (r_idx, s_idx, d_idx)
);
INSERT INTO cards (id, text, stability, difficulty, repetition, next_review) VALUES
  (1, 'alpha established', 12.5, 0.42, 5, datetime('now', '-1 day')),
  (2, 'beta overdue',      3.2,  0.55, 3, datetime('now', '-5 days')),
  (3, 'gamma fresh',       2.0,  0.5,  1, datetime('now', '-1 hour'));
INSERT INTO reviews (card_id, grade, prev_stability, new_stability,
                     prev_interval, new_interval, elapsed_days) VALUES
  (1, 0.78, 2.0, 5.0,  2.0, 5.0,  2.0),
  (1, 0.78, 5.0, 8.0,  5.0, 8.0,  5.0),
  (1, 0.05, 8.0, 1.0,  8.0, 1.0,  9.0),  -- old "again" = lapse
  (1, 0.78, 1.0, 12.5, 1.0, 12.5, 1.0),
  (2, 0.05, 2.0, 1.0,  2.0, 1.0,  2.0),
  (2, 0.78, 1.0, 3.2,  1.0, 3.2,  1.5),
  (2, 0.92, 1.0, 3.2,  1.0, 3.2,  1.0);
INSERT INTO interval_matrix VALUES (0, 0, 0, 13.822076);
INSERT INTO count_matrix VALUES (0, 0, 0, 3);
PRAGMA user_version=20260530;
]])
f:close()
run_sql_file(dbpath, fixture)

local function read_scalar(sql)
  local p = io.popen(string.format('sqlite3 -batch "%s" "%s"', dbpath, sql))
  local out = p:read("*a")
  p:close()
  return (out:gsub("%s+$", ""))
end

local next_review_before = read_scalar("SELECT next_review FROM cards WHERE id = 1;")

print("== 1. migration ==")
local db = require("database")  -- require-time init runs the migration

check("new columns added",
  read_scalar("SELECT COUNT(*) FROM pragma_table_info('cards') WHERE name IN ('srs_state','lapses','last_reviewed_at','interval_days');") == "4")
check("old matrix tables left in place",
  read_scalar("SELECT COUNT(*) FROM sqlite_master WHERE name IN ('interval_matrix','count_matrix');") == "2")
check("user_version bumped", read_scalar("PRAGMA user_version;") == "20260915")
check("due dates preserved",
  read_scalar("SELECT next_review FROM cards WHERE id = 1;") == next_review_before)
check("lapses derived from old again-grades",
  read_scalar("SELECT lapses FROM cards WHERE id = 1;") == "1"
    and read_scalar("SELECT lapses FROM cards WHERE id = 2;") == "1"
    and read_scalar("SELECT lapses FROM cards WHERE id = 3;") == "0")
check("srs_state backfilled",
  read_scalar("SELECT COUNT(*) FROM cards WHERE srs_state IS NOT NULL;") == "3")

local state_mod = require("sm20.state")
local json = require("sm20.json")
local srs1 = state_mod.item_from_dict(
  json.decode(read_scalar("SELECT srs_state FROM cards WHERE id = 1;")))
check("migrated canonical state maps old fields",
  srs1.repetition == 4 and srs1.stability == 12.5 and srs1.difficulty == 0.42
    and srs1.lapses == 1,
  string.format("rep=%s stab=%s diff=%s lapses=%s",
    srs1.repetition, srs1.stability, srs1.difficulty, srs1.lapses))
check("last_reviewed_at recovered from due date",
  tonumber(read_scalar("SELECT last_reviewed_at FROM cards WHERE id = 1;")) ~= nil)

-- ---------------------------------------------------------------------------
-- 2. session A: 10 canonical reviews through the facade
-- ---------------------------------------------------------------------------

print("== 2. review session ==")
local SM20Engine = require("srs_engine")

local coll_dict = db:loadCollectionState()
check("no collection state before first session", coll_dict == nil)
local collection = SM20Engine.newCollectionState()

local due = db:getDueCards()
check("three cards due", #due == 3, "got " .. #due)

local card1, card2, card3 = due[1], due[2], due[3]

-- preview determinism + no state mutation
local snap1 = json.encode(state_mod.item_to_dict(SM20Engine.decodeCardSRS(card1)))
local p1 = SM20Engine:preview(card1, "good", collection)
local p2 = SM20Engine:preview(card1, "good", collection)
check("previews deterministic", p1.next_review_offset_days == p2.next_review_offset_days)
check("preview leaves state untouched",
  json.encode(state_mod.item_to_dict(SM20Engine.decodeCardSRS(card1))) == snap1)

-- grading plan: includes first review (gamma), post-lapse on established
-- cards, and explicit elapsed days so repeat reviews within one session
-- simulate reviews on later days (the canonical arena adaptation is guarded
-- by elapsed > 0, which a zero-elapsed same-instant review would skip)
local plan = {
  { card1, "good", nil },   -- elapsed from migrated last_reviewed_at (~13d)
  { card2, "easy", nil },   -- ~8d overdue
  { card3, "good", nil },   -- first review of a fresh card
  { card1, "again", 13.0 }, -- post-lapse path: established item, failing grade
  { card2, "again", 6.0 },  -- post-lapse path
  { card3, "hard", 1.0 },
  { card1, "good", 2.0 },
  { card3, "easy", 3.0 },
  { card2, "good", 1.0 },
  { card3, "good", 5.0 },
}

local pending = {}
local post_lapse_intervals = {}
local grade_ok = true
local sim_time = {}  -- per-card simulated wall clock (seconds)
for i, step in ipairs(plan) do
  local card, grade_name, elapsed = step[1], step[2], step[3]
  local opts
  if elapsed ~= nil then
    local base = sim_time[card.id] or card.last_reviewed_at or os.time()
    local t = base + elapsed * 86400
    sim_time[card.id] = t
    opts = { elapsed_days = elapsed, today = math.floor(t / 86400) }
  end
  local result = SM20Engine:review(card, grade_name, collection, opts)
  -- keep the simulated clock ahead of the facade's real-time mirror
  if sim_time[card.id] then
    card.last_reviewed_at = sim_time[card.id]
  end
  local g = result.grade
  if g ~= 1 and g ~= 3 and g ~= 4 and g ~= 5 then grade_ok = false end
  if grade_name == "again" and i >= 4 then
    post_lapse_intervals[#post_lapse_intervals + 1] = result.new_interval
  end
  result.next_review_date = os.date("!%Y-%m-%d %H:%M:%S",
    math.floor(result.last_reviewed_at + result.next_review_offset_days * 86400))
  pending[#pending + 1] = result
end

check("grades stored as SuperMemo integers {1,3,4,5}", grade_ok)
check("post-lapse intervals within 1..11 days",
  #post_lapse_intervals == 2
    and post_lapse_intervals[1] >= 1 and post_lapse_intervals[1] <= 11
    and post_lapse_intervals[2] >= 1 and post_lapse_intervals[2] <= 11,
  table.concat(post_lapse_intervals, ","))

db:flushReviews(pending)
db:saveCollectionState(SM20Engine.collectionToDict(collection))

check("ten reviews logged",
  read_scalar("SELECT COUNT(*) FROM reviews;") == "17")  -- 7 old + 10 new
check("new grades are integer-valued",
  read_scalar("SELECT COUNT(*) FROM reviews WHERE grade IN (1,3,4,5);") == "10")
check("cards carry srs_state and interval",
  read_scalar("SELECT COUNT(*) FROM cards WHERE srs_state IS NOT NULL AND interval_days > 0;") == "3")
check("last_reviewed_at stamped",
  read_scalar("SELECT COUNT(*) FROM cards WHERE last_reviewed_at IS NOT NULL;") == "3")

local w = collection.arena.weights
local wsum = w[1] + w[2] + w[3] + w[4] + w[5]
check("arena weights sum to 100", math.abs(wsum - 100.0) < 1e-9, wsum)
local defaults = require("sm20.weights").DEFAULT_WEIGHTS
local moved = false
for i = 1, 5 do
  if math.abs(w[i] - defaults[i]) > 1e-6 then moved = true end
end
check("arena weights adapted away from defaults", moved,
  string.format("%.3f,%.3f,%.3f,%.3f,%.3f", w[1], w[2], w[3], w[4], w[5]))

-- ---------------------------------------------------------------------------
-- 3. session B: reopen and verify persistence
-- ---------------------------------------------------------------------------

print("== 3. reopen ==")
local coll_dict2 = db:loadCollectionState()
check("collection state persisted", coll_dict2 ~= nil)
local collection2 = SM20Engine.collectionFromDict(coll_dict2)
local w2 = collection2.arena.weights
local w2sum = w2[1] + w2[2] + w2[3] + w2[4] + w2[5]
check("reloaded weights sum to 100", math.abs(w2sum - 100.0) < 1e-9, w2sum)
local reloaded_same = true
for i = 1, 5 do
  if math.abs(w2[i] - w[i]) > 1e-9 then reloaded_same = false end
end
check("reloaded weights match session A", reloaded_same)

local due2 = db:getDueCards()
check("cards rescheduled into the future", #due2 == 0, "due: " .. #due2)

-- the persisted per-card state decodes and advanced
local srs1b = state_mod.item_from_dict(
  json.decode(read_scalar("SELECT srs_state FROM cards WHERE id = 1;")))
-- card1's session: pass (rep 4->5), lapse (rep -> 1), pass (rep -> 2)
check("persisted card state reflects the canonical lapse flow",
  srs1b.repetition == 2 and srs1b.interval > 0 and srs1b.lapses == 2,
  string.format("rep %s -> %s, interval %s, lapses %s",
    srs1.repetition, srs1b.repetition, srs1b.interval, srs1b.lapses))
check("persisted slot predictions survive for arena scoring",
  srs1b.slot_stabilities ~= nil and #srs1b.slot_stabilities == 5)

-- simulate a later review: the persisted state is decoded fresh and the
-- reloaded collection schedules it (today advanced past the session's
-- simulated day-stamps)
local elapsed_probe = 2.0
local probe_card = { last_reviewed_at = os.time() - elapsed_probe * 86400,
  srs_state = read_scalar("SELECT srs_state FROM cards WHERE id = 2;") }
local probe = SM20Engine:preview(probe_card, "good", collection2,
  { elapsed_days = elapsed_probe, today = SM20Engine.today() + 30 })
check("post-reopen preview schedules via reloaded collection",
  probe.next_review_offset_days >= 1, probe.next_review_offset_days)

os.execute('rm -rf "' .. tmpdir .. '"')

print(string.format("\n%s: %d passed, %d failed",
  fail == 0 and "DRILL PASSED" or "DRILL FAILED", pass, fail))
os.exit(fail == 0 and 0 or 1)
