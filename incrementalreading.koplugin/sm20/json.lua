-- JSON codec for persisting sm20 scheduling state.
--
-- Prefers KOReader's bundled rapidjson when present; otherwise falls back to
-- a small pure-Lua 5.1 encoder/decoder. Handles exactly the state shapes the
-- engine produces: nested arrays of finite numbers, strings, booleans, and
-- objects with string keys. nil-valued object members are omitted on encode
-- and stored as absent on decode (JSON null is skipped), matching the
-- engine's to_dict convention.

local json = {}

local has_rapidjson, RapidJson = pcall(require, "rapidjson")
json.using_rapidjson = has_rapidjson

-- ---------------------------------------------------------------------------
-- pure-Lua fallback
-- ---------------------------------------------------------------------------

local function encode_value(v, out)
  local tv = type(v)
  if tv == "nil" then
    out[#out + 1] = "null"
  elseif tv == "boolean" then
    out[#out + 1] = v and "true" or "false"
  elseif tv == "number" then
    if v ~= v or v == math.huge or v == -math.huge then
      error("cannot encode non-finite number")
    end
    if v % 1 == 0 and math.abs(v) < 1e15 then
      out[#out + 1] = string.format("%d", v)
    else
      -- %.17g always round-trips a double through strtod
      out[#out + 1] = string.format("%.17g", v)
    end
  elseif tv == "string" then
    local s = v:gsub('[%c"\\]', function(c)
      local map = { ['"'] = '\\"', ['\\'] = '\\\\', ['\n'] = '\\n',
        ['\t'] = '\\t', ['\r'] = '\\r', ['\b'] = '\\b', ['\f'] = '\\f' }
      local m = map[c]
      if m then return m end
      return string.format("\\u%04x", string.byte(c))
    end)
    out[#out + 1] = '"' .. s .. '"'
  elseif tv == "table" then
    -- array if it has a positive length and no string keys
    local is_array = (#v > 0)
    if is_array then
      for k in pairs(v) do
        if type(k) ~= "number" then is_array = false break end
      end
    end
    if is_array then
      out[#out + 1] = "["
      for i = 1, #v do
        if i > 1 then out[#out + 1] = "," end
        encode_value(v[i], out)
      end
      out[#out + 1] = "]"
    else
      out[#out + 1] = "{"
      local first = true
      -- deterministic member order: sorted keys
      local keys = {}
      for k in pairs(v) do keys[#keys + 1] = k end
      table.sort(keys, function(a, b) return tostring(a) < tostring(b) end)
      for _, k in ipairs(keys) do
        local val = v[k]
        if val ~= nil then  -- omit nil members
          if not first then out[#out + 1] = "," end
          first = false
          encode_value(tostring(k), out)
          out[#out + 1] = ":"
          encode_value(val, out)
        end
      end
      out[#out + 1] = "}"
    end
  else
    error("cannot encode value of type " .. tv)
  end
end

-- ---------------------------------------------------------------------------
-- decoder (fallback path; also used to test rapidjson independence)
-- ---------------------------------------------------------------------------

local Decoder = {}
Decoder.__index = Decoder

function Decoder.new(s)
  return setmetatable({ s = s, i = 1 }, Decoder)
end

function Decoder:peek()
  return self.s:sub(self.i, self.i)
end

function Decoder:skip_ws()
  while self.i <= #self.s do
    local c = self.s:sub(self.i, self.i)
    if c == " " or c == "\t" or c == "\n" or c == "\r" then
      self.i = self.i + 1
    else
      break
    end
  end
end

function Decoder:expect(c)
  if self:peek() ~= c then
    error(string.format("json decode: expected %q at offset %d", c, self.i))
  end
  self.i = self.i + 1
end

function Decoder:parse_value()
  self:skip_ws()
  local c = self:peek()
  if c == "{" then return self:parse_object() end
  if c == "[" then return self:parse_array() end
  if c == '"' then return self:parse_string() end
  if c == "t" then
    self.i = self.i + 4
    return true
  end
  if c == "f" then
    self.i = self.i + 5
    return false
  end
  if c == "n" then
    self.i = self.i + 4
    return nil
  end
  return self:parse_number()
end

function Decoder:parse_object()
  self:expect("{")
  local obj = {}
  self:skip_ws()
  if self:peek() == "}" then
    self.i = self.i + 1
    return obj
  end
  while true do
    self:skip_ws()
    local key = self:parse_string()
    self:skip_ws()
    self:expect(":")
    local value = self:parse_value()
    if value ~= nil then  -- JSON null -> member absent
      obj[key] = value
    end
    self:skip_ws()
    local c = self:peek()
    if c == "," then
      self.i = self.i + 1
    elseif c == "}" then
      self.i = self.i + 1
      break
    else
      error(string.format("json decode: bad object at offset %d", self.i))
    end
  end
  return obj
end

function Decoder:parse_array()
  self:expect("[")
  local arr = {}
  self:skip_ws()
  if self:peek() == "]" then
    self.i = self.i + 1
    return arr
  end
  while true do
    arr[#arr + 1] = self:parse_value()
    self:skip_ws()
    local c = self:peek()
    if c == "," then
      self.i = self.i + 1
    elseif c == "]" then
      self.i = self.i + 1
      break
    else
      error(string.format("json decode: bad array at offset %d", self.i))
    end
  end
  return arr
end

function Decoder:parse_string()
  self:expect('"')
  local parts = {}
  while true do
    local c = self.s:sub(self.i, self.i)
    if c == "" then
      error("json decode: unterminated string")
    elseif c == '"' then
      self.i = self.i + 1
      break
    elseif c == "\\" then
      self.i = self.i + 1
      local e = self.s:sub(self.i, self.i)
      self.i = self.i + 1
      local map = { ['"'] = '"', ['\\'] = '\\', ['/'] = '/', ['n'] = '\n',
        ['t'] = '\t', ['r'] = '\r', ['b'] = '\b', ['f'] = '\f' }
      if map[e] then
        parts[#parts + 1] = map[e]
      elseif e == "u" then
        local hex = self.s:sub(self.i, self.i + 3)
        self.i = self.i + 4
        parts[#parts + 1] = string.char(tonumber(hex, 16))
      else
        error("json decode: bad escape \\" .. e)
      end
    else
      parts[#parts + 1] = c
      self.i = self.i + 1
    end
  end
  return table.concat(parts)
end

function Decoder:parse_number()
  local start = self.i
  while self.i <= #self.s do
    local c = self.s:sub(self.i, self.i)
    if c:find("^[-+%.eE%d]$") then
      self.i = self.i + 1
    else
      break
    end
  end
  local text = self.s:sub(start, self.i - 1)
  if text == "" then
    error(string.format("json decode: bad number at offset %d", start))
  end
  return tonumber(text)
end

-- ---------------------------------------------------------------------------
-- public API
-- ---------------------------------------------------------------------------

function json.encode(value)
  if has_rapidjson then
    return RapidJson.encode(value)
  end
  local out = {}
  encode_value(value, out)
  return table.concat(out)
end

function json.decode(text)
  if has_rapidjson then
    return RapidJson.decode(text)
  end
  local dec = Decoder.new(text)
  local value = dec:parse_value()
  dec:skip_ws()
  if dec.i <= #dec.s then
    error("json decode: trailing data")
  end
  return value
end

return json
