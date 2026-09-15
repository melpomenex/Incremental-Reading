-- Test stub for KOReader's lua-ljsqlite3 binding, backed by the sqlite3 CLI.
--
-- Implements the subset of the ljsqlite3 API used by database.lua:
--   conn:exec(sql)   -> column-major arrays for the final SELECT (if any)
--   conn:rowexec(sql)-> first field of the first row (string) or nil
--   conn:prepare(sql)-> stmt with :bind(...), :step(), :reset(), :clearbind(),
--                       :close(); step returns the next row array or nil
--
-- Statements are executed by piping SQL through `sqlite3 -batch -bail` in
-- list mode with an unlikely separator; NULL reads back as an empty string
-- (callers already treat "" and nil alike on these columns). Transactions
-- span separate CLI processes, so they do not group atomically — fine for
-- the drill, which only checks outcomes, not atomicity.

local SEP = "|@|"

local M = {}

local function esc_value(v)
  if v == nil then return "NULL" end
  local t = type(v)
  if t == "number" then
    return string.format("%.17g", v)
  end
  if t == "boolean" then
    return v and "1" or "0"
  end
  local s = tostring(v)
  return "'" .. s:gsub("'", "''") .. "'"
end

local function substitute(sql, params)
  if not params then return sql end
  local i = 0
  return (sql:gsub("?", function()
    i = i + 1
    return esc_value(params[i])
  end))
end

local function split_line(line)
  local fields = {}
  local start = 1
  while true do
    local s, e = line:find(SEP, start, true)
    if not s then
      fields[#fields + 1] = line:sub(start)
      break
    end
    fields[#fields + 1] = line:sub(start, s - 1)
    start = e + 1
  end
  return fields
end

local Drill = {
  tmp_count = 0,
  err_log = {},
}

local function strip_transactions(sql)
  -- BEGIN/COMMIT cannot span CLI processes; every invocation autocommits,
  -- so transaction statements are dropped (outcomes are identical for the
  -- drill; atomicity is not under test)
  return (sql:gsub("BEGIN TRANSACTION%s*;", ""):gsub("COMMIT%s*;", "")
    :gsub("BEGIN%s*;", ""))
end

function Drill.run(db_path, sql, with_header)
  sql = strip_transactions(sql)
  Drill.tmp_count = Drill.tmp_count + 1
  local n = Drill.tmp_count
  local sqlfile = db_path .. ".sql" .. n
  local outfile = db_path .. ".out" .. n
  local errfile = db_path .. ".err" .. n
  local f = io.open(sqlfile, "w")
  f:write(sql)
  f:write("\n;")
  f:close()
  os.execute(string.format(
    'sqlite3 -batch -bail -separator "%s" %s "%s" < "%s" > "%s" 2> "%s"',
    SEP, with_header and "-header" or "", db_path, sqlfile, outfile, errfile))
  local ef = io.open(errfile, "r")
  local err = ef and ef:read("*a") or ""
  if ef then ef:close() end
  os.remove(sqlfile)
  os.remove(errfile)
  if err ~= "" then
    Drill.err_log[#Drill.err_log + 1] = err
    error("sqlite stub error: " .. err)
  end
  local rows = {}
  local of = io.open(outfile, "r")
  if of then
    for line in of:lines() do
      rows[#rows + 1] = line
    end
    of:close()
  end
  os.remove(outfile)
  return rows
end

local Stmt = {}
Stmt.__index = Stmt

function Stmt:bind(...)
  self.params = { ... }
  return self
end

function Stmt:clearbind()
  self.params = nil
  return self
end

function Stmt:reset()
  self.rows = nil
  self.cursor = nil
  return self
end

function Stmt:step()
  if not self.rows then
    local lines = Drill.run(self.db_path,
      substitute(self.sql, self.params), true)
    -- first line is the header (column names); remaining lines are data
    self.rows = {}
    for i = 2, #lines do
      self.rows[#self.rows + 1] = split_line(lines[i])
    end
    self.cursor = 0
  end
  self.cursor = self.cursor + 1
  local row = self.rows[self.cursor]
  if row == nil then
    return nil
  end
  -- ljsqlite3 returns 1-based positional values; empty string stays as-is
  return row
end

function Stmt:close()
  self.rows = nil
end

local Conn = {}
Conn.__index = Conn

function Conn:exec(sql)
  local lines = Drill.run(self.path, sql, false)
  if #lines == 0 then
    return nil
  end
  -- parse row-major lines, then transpose to column-major arrays
  local rows = {}
  for _, line in ipairs(lines) do
    rows[#rows + 1] = split_line(line)
  end
  local ncols = #rows[1]
  local cols = {}
  for c = 1, ncols do
    local col = {}
    for r = 1, #rows do
      col[r] = rows[r][c]
    end
    cols[c] = col
  end
  return cols
end

function Conn:rowexec(sql)
  local lines = Drill.run(self.path, sql, false)
  if lines[1] then
    return split_line(lines[1])[1]
  end
  return nil
end

function Conn:prepare(sql)
  return setmetatable({ db_path = self.path, sql = sql }, Stmt)
end

function Conn:close() end

function M.open(path)
  return setmetatable({ path = path }, Conn)
end

M._drill = Drill

return M
