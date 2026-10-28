-- A tool call's arguments checked against the tool's JSON Schema before it runs, as pi-ai's validateToolArguments
-- does: the subset tools are written in (type, properties, required, enum, items, anyOf, minimum, maximum,
-- additionalProperties = false). A number sent as a string, or a boolean as "true", is coerced, since models do
-- that; anything else wrong is an error naming the path, which the model reads as the tool's result and corrects.
--
--   validate.arguments(tool, args) -> args (coerced) | raises "Validation failed for tool x: ..."
--   validate.check(schema, value) -> value, nil | nil, "path: what is wrong"
local json = require("pi.json")

local M = {}

local function is_array(v)
  if type(v) ~= "table" then return false end
  local n = 0
  for _ in pairs(v) do n = n + 1 end
  for i = 1, n do if v[i] == nil then return false end end
  return true
end

local coerce = {
  number = function(v) if type(v) == "string" then return tonumber(v) end return v end,
  integer = function(v) if type(v) == "string" then return tonumber(v) end return v end,
  boolean = function(v) if v == "true" then return true elseif v == "false" then return false end return v end,
}

local function fits(t, v)
  if t == "string" then return type(v) == "string"
  elseif t == "number" then return type(v) == "number"
  elseif t == "integer" then return type(v) == "number" and v == math.floor(v)
  elseif t == "boolean" then return type(v) == "boolean"
  elseif t == "array" then return is_array(v)
  elseif t == "object" then return type(v) == "table" and (next(v) == nil or not is_array(v))
  elseif t == "null" then return v == nil or v == json.null end
  return true
end

local check

local function one_type(schema, v, path)
  local types = type(schema.type) == "table" and schema.type or { schema.type }
  for _, t in ipairs(types) do
    local c = coerce[t] and coerce[t](v) or v
    if fits(t, c) then return c end
  end
  return nil, path .. ": expected " .. table.concat(types, " or ") .. ", got " .. (v == json.null and "null" or type(v))
end

function check(schema, v, path)
  path = path or "root"
  if type(schema) ~= "table" then return v end
  if schema.anyOf or schema.oneOf then
    local errs = {}
    for _, s in ipairs(schema.anyOf or schema.oneOf) do
      local got, err = check(s, v, path)
      if not err then return got end
      errs[#errs + 1] = err
    end
    return nil, table.concat(errs, "; or ")
  end
  if v == nil then return nil, path .. ": is required" end
  if schema.type then
    local got, err = one_type(schema, v, path)
    if err then return nil, err end
    v = got
  end
  if schema.enum then
    local ok = false
    for _, e in ipairs(schema.enum) do if e == v then ok = true end end
    if not ok then return nil, path .. ": must be one of " .. json.encode(schema.enum) end
  end
  if schema.const ~= nil and v ~= schema.const then return nil, path .. ": must be " .. json.encode(schema.const) end
  if type(v) == "number" then
    if schema.minimum and v < schema.minimum then return nil, path .. ": must be at least " .. schema.minimum end
    if schema.maximum and v > schema.maximum then return nil, path .. ": must be at most " .. schema.maximum end
  end
  if type(v) == "table" and schema.items and is_array(v) then
    for i, item in ipairs(v) do
      local got, err = check(schema.items, item, path .. "[" .. i .. "]")
      if err then return nil, err end
      v[i] = got
    end
  end
  if type(v) == "table" and schema.properties then
    for _, k in ipairs(schema.required or {}) do
      if v[k] == nil then return nil, path .. "." .. k .. ": is required" end
    end
    for k, s in pairs(schema.properties) do
      if v[k] ~= nil then
        local got, err = check(s, v[k], path .. "." .. k)
        if err then return nil, err end
        v[k] = got
      end
    end
    if schema.additionalProperties == false then
      for k in pairs(v) do
        if not schema.properties[k] then return nil, path .. "." .. tostring(k) .. ": is not allowed" end
      end
    end
  end
  return v
end

M.check = check

function M.arguments(tool, args)
  if not tool.parameters then return args or {} end
  local got, err = check(tool.parameters, args or {}, "root")
  if err then error("Validation failed for tool " .. tool.name .. ": " .. err, 0) end
  return got
end

return M
