-- JSON for the model ports, in portable Lua (no utf8 library, no FFI).
--
--   json.encode(value) -> text      json.decode(text) -> value
--
-- Objects are written with their keys sorted, so the same request is always
-- the same bytes: the prompt cache matches on bytes. A table is an array when
-- its keys are exactly 1..n; an empty table is an object unless marked with
-- json.array({}). JSON null decodes to json.null inside arrays (so lengths
-- hold) and is dropped from objects.
local M = {}

M.null = setmetatable({}, { __tostring = function() return "null" end })
local array_mt = { __jsontype = "array" }

function M.array(t)
  return setmetatable(t or {}, array_mt)
end

local escapes = { ['"'] = '\\"', ["\\"] = "\\\\", ["\b"] = "\\b", ["\f"] = "\\f",
  ["\n"] = "\\n", ["\r"] = "\\r", ["\t"] = "\\t" }

local function encode_string(s)
  return '"' .. s:gsub('[%c"\\]', function(c)
    return escapes[c] or ("\\u%04x"):format(c:byte())
  end) .. '"'
end

local function is_array(t)
  if getmetatable(t) == array_mt then return true end
  local n = 0
  for _ in pairs(t) do n = n + 1 end
  if n == 0 then return false end
  for i = 1, n do
    if t[i] == nil then return false end
  end
  return true
end

local encode

local function encode_table(t, seen)
  assert(not seen[t], "json: cannot encode a cycle")
  seen[t] = true
  local out = {}
  if is_array(t) then
    for i = 1, #t do out[i] = encode(t[i], seen) end
    seen[t] = nil
    return "[" .. table.concat(out, ",") .. "]"
  end
  local keys = {}
  for k in pairs(t) do
    assert(type(k) == "string", "json: object keys must be strings, got " .. type(k))
    keys[#keys + 1] = k
  end
  table.sort(keys)
  for i, k in ipairs(keys) do out[i] = encode_string(k) .. ":" .. encode(t[k], seen) end
  seen[t] = nil
  return "{" .. table.concat(out, ",") .. "}"
end

function encode(v, seen)
  local t = type(v)
  if v == nil or v == M.null then return "null" end
  if t == "boolean" then return tostring(v) end
  if t == "string" then return encode_string(v) end
  if t == "number" then
    assert(v == v and v ~= math.huge and v ~= -math.huge, "json: cannot encode " .. tostring(v))
    if v == math.floor(v) and math.abs(v) < 2 ^ 53 then return ("%d"):format(v) end
    for digits = 14, 16 do
      local text = ("%." .. digits .. "g"):format(v)
      if tonumber(text) == v then return text end
    end
    return ("%.17g"):format(v)
  end
  if t == "table" then return encode_table(v, seen) end
  error("json: cannot encode a " .. t)
end

function M.encode(v)
  return encode(v, {})
end

-- Decoding ------------------------------------------------------------------

local function utf8_char(cp)
  if cp < 0x80 then return string.char(cp) end
  if cp < 0x800 then
    return string.char(0xC0 + math.floor(cp / 0x40), 0x80 + cp % 0x40)
  end
  if cp < 0x10000 then
    return string.char(0xE0 + math.floor(cp / 0x1000), 0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
  end
  return string.char(0xF0 + math.floor(cp / 0x40000), 0x80 + math.floor(cp / 0x1000) % 0x40,
    0x80 + math.floor(cp / 0x40) % 0x40, 0x80 + cp % 0x40)
end

local unescape = { b = "\b", f = "\f", n = "\n", r = "\r", t = "\t", ['"'] = '"', ["\\"] = "\\", ["/"] = "/" }

local function fail(i, what)
  error(("json: %s at byte %d"):format(what, i), 0)
end

local function skip(s, i)
  return s:find("[^ \t\r\n]", i) or #s + 1
end

local value

local function read_string(s, i)
  local out, j = {}, i + 1
  while true do
    local k = s:find('["\\]', j)
    if not k then fail(i, "unterminated string") end
    out[#out + 1] = s:sub(j, k - 1)
    if s:sub(k, k) == '"' then return table.concat(out), k + 1 end
    local c = s:sub(k + 1, k + 1)
    if c == "u" then
      local cp = tonumber(s:sub(k + 2, k + 5), 16)
      if not cp then fail(k, "bad \\u escape") end
      j = k + 6
      if cp >= 0xD800 and cp <= 0xDBFF and s:sub(j, j + 1) == "\\u" then
        local lo = tonumber(s:sub(j + 2, j + 5), 16)
        if lo and lo >= 0xDC00 and lo <= 0xDFFF then
          cp = 0x10000 + (cp - 0xD800) * 0x400 + (lo - 0xDC00)
          j = j + 6
        end
      end
      out[#out + 1] = utf8_char(cp)
    elseif unescape[c] then
      out[#out + 1] = unescape[c]
      j = k + 2
    else
      fail(k, "bad escape")
    end
  end
end

local function read_array(s, i)
  local out, n = M.array({}), 0
  i = skip(s, i + 1)
  if s:sub(i, i) == "]" then return out, i + 1 end
  while true do
    local v
    v, i = value(s, i)
    n = n + 1
    out[n] = v == nil and M.null or v
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "]" then return out, i + 1 end
    if c ~= "," then fail(i, "expected , or ]") end
    i = skip(s, i + 1)
  end
end

local function read_object(s, i)
  local out = {}
  i = skip(s, i + 1)
  if s:sub(i, i) == "}" then return out, i + 1 end
  while true do
    if s:sub(i, i) ~= '"' then fail(i, "expected a key") end
    local k, v
    k, i = read_string(s, i)
    i = skip(s, i)
    if s:sub(i, i) ~= ":" then fail(i, "expected :") end
    v, i = value(s, skip(s, i + 1))
    if v ~= M.null then out[k] = v end
    i = skip(s, i)
    local c = s:sub(i, i)
    if c == "}" then return out, i + 1 end
    if c ~= "," then fail(i, "expected , or }") end
    i = skip(s, i + 1)
  end
end

local literals = { ["true"] = true, ["false"] = false, ["null"] = M.null }

function value(s, i)
  local c = s:sub(i, i)
  if c == "{" then return read_object(s, i) end
  if c == "[" then return read_array(s, i) end
  if c == '"' then return read_string(s, i) end
  local num = s:match("^-?%d+%.?%d*[eE]?[-+]?%d*", i)
  if num and num ~= "" and num ~= "-" then return tonumber(num), i + #num end
  for word, v in pairs(literals) do
    if s:sub(i, i + #word - 1) == word then return v, i + #word end
  end
  fail(i, "unexpected character")
end

function M.decode(s)
  local v, i = value(s, skip(s, 1))
  if skip(s, i) <= #s then fail(i, "trailing text") end
  return v
end

return M
