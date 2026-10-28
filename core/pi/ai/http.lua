-- One HTTP POST through the host's fetch, shared by the providers. pi.lua names no host: the host supplies
--
--   host = { fetch = fn(req) -> res, now? = fn() -> seconds, sleep? = fn(seconds) }
--   req  = { method, url, headers, body, timeout, on_data? }      res = { status, body }
--
-- fetch may raise for a network failure or a timeout. With on_data the host hands the body over a chunk at a time
-- as it arrives (a streamed reply) and still returns the whole body.
--
-- A transient failure (no answer, 429, 5xx) is tried three times, a second and then three apart; any other status
-- is final, and so is a 429 that says a daily or plan limit is spent (waiting does not bring it back). The error
-- raised is { message, status, spent, record }; the record is what a log may keep (service, url, status, tries,
-- seconds), never the headers, so never the key.
local json = require("pi.json")

local M = {}

local function transient(status)
  return status == nil or status == 429 or status >= 500
end

-- The error message a service put in its body, if it put one there.
function M.reason(body)
  local ok, v = pcall(json.decode, body or "")
  if ok and type(v) == "table" then
    local e = type(v.error) == "table" and (v.error.message or v.error.code) or v.error or v.detail or v.message
    if type(e) == "table" then e = json.encode(e) end
    if e ~= nil then return tostring(e):sub(1, 300) end
  end
  return (body or ""):sub(1, 200)
end

-- whether a 429's body says a limit is spent until later, not a moment's load
function M.spent(body)
  local r = M.reason(body):lower()
  return (r:find("limit reached", 1, true) or r:find("quota", 1, true) or r:find("usage limit", 1, true)
    or r:find("resets at", 1, true)) ~= nil
end

local function failure(message, record)
  return setmetatable({ message = message, status = record.status, spent = record.spent, record = record },
    { __tostring = function(e) return e.message end })
end

-- POST payload as JSON to url with headers. Returns the decoded reply (or, with on_data, the raw body) and the
-- record. waits defaults to { 1, 3 }; a test passes {} to try once.
function M.post(host, service, url, headers, payload, opts)
  opts = opts or {}
  local h = { ["Content-Type"] = "application/json" }
  for k, v in pairs(headers or {}) do h[k] = v end
  local req = { method = "POST", url = url, timeout = opts.timeout or 120, headers = h, body = json.encode(payload),
    on_data = opts.on_data }
  local record = { service = service, url = url, tries = 0 }
  local t0 = host.now and host.now()
  local waits = opts.waits or { 1, 3 }
  local last
  for try = 1, #waits + 1 do
    record.tries = try
    local ok, res = pcall(host.fetch, req)
    local status = ok and res.status or nil
    record.status = status
    if status and status >= 200 and status < 300 then
      if t0 then record.seconds = host.now() - t0 end
      if opts.on_data then return res.body, record end
      return json.decode(res.body), record
    end
    last = ok and (service .. " answered " .. status .. ": " .. M.reason(res.body))
      or (service .. " unreachable: " .. tostring(res))
    if status == 429 and M.spent(res.body) then record.spent = true break end
    if not transient(status) then break end
    if opts.aborted and opts.aborted() then break end
    if waits[try] and host.sleep then host.sleep(waits[try]) end
  end
  if t0 then record.seconds = host.now() - t0 end
  error(failure(last, record), 0)
end

return M
