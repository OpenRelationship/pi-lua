-- Server-sent events as they come: bytes cut anywhere (inside a line or an event) in, one call per event out.
--
--   local r = sse.reader(function(event, data) ... end)   event is the `event:` name or "message"
--   r:feed(chunk)                                          data is the event's `data:` lines joined by "\n"
--   r:finish()                                             flushes an event the stream did not end with a blank line
local M = {}
local R = {}
R.__index = R

function M.reader(on_event)
  return setmetatable({ on_event = on_event, pending = "", data = nil, event = nil }, R)
end

local function dispatch(self)
  if self.data then self.on_event(self.event or "message", self.data) end
  self.data, self.event = nil, nil
end

local function line(self, l)
  if l == "" then return dispatch(self) end
  if l:sub(1, 1) == ":" then return end
  local field, value = l:match("^([^:]*):%s?(.*)$")
  if not field then field, value = l, "" end
  if field == "data" then
    self.data = self.data and (self.data .. "\n" .. value) or value
  elseif field == "event" then
    self.event = value
  end
end

function R:feed(chunk)
  self.pending = self.pending .. (chunk or ""):gsub("\r", "")
  while true do
    local nl = self.pending:find("\n", 1, true)
    if not nl then break end
    local l = self.pending:sub(1, nl - 1)
    self.pending = self.pending:sub(nl + 1)
    line(self, l)
  end
  return self
end

function R:finish()
  if self.pending ~= "" then line(self, self.pending); self.pending = "" end
  dispatch(self)
  return self
end

return M
