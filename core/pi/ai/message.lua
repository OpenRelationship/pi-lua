-- The assistant message a provider builds as its reply streams, in pi's shape, and the events it emits on the way.
--
--   message = { role = "assistant", content = { block... }, api, provider, model, usage, stopReason, errorMessage?,
--               timestamp }
--   block   = { type = "text", text } | { type = "thinking", thinking, signature? }
--           | { type = "toolCall", id, name, arguments }
--   stopReason = "stop" | "length" | "toolUse" | "error" | "aborted"   (errorStatus: the HTTP status of a refused call)
--
-- Events (on_event(e)), as pi-ai names them: start; text_start, text_delta, text_end; thinking_start, thinking_delta,
-- thinking_end; toolcall_start, toolcall_delta, toolcall_end; then done or error. Each carries partial, the
-- message so far; a delta event carries contentIndex and delta.
--
--   local b = message.builder(model, on_event)
--   b:start()   b:text(key, piece)   b:thinking(key, piece, signature?)   b:tool(key, id?, name?, args_piece?)
--   b:close(key)   b:usage(u)   b:done(stop_reason) -> message   b:fail(err, aborted?) -> message
--
-- key names a block in the provider's own terms (an index, "text"); a new key opens a new block.
local json = require("pi.json")

local M = {}
local B = {}
B.__index = B

function M.usage()
  return { input = 0, output = 0, cacheRead = 0, cacheWrite = 0, totalTokens = 0,
    cost = { input = 0, output = 0, cacheRead = 0, cacheWrite = 0, total = 0 } }
end

-- the cost of a usage at the model's prices, in dollars per million tokens
function M.cost(model, u)
  local p = model.cost or {}
  local c = u.cost
  c.input = (p.input or 0) * u.input / 1e6
  c.output = (p.output or 0) * u.output / 1e6
  c.cacheRead = (p.cacheRead or 0) * u.cacheRead / 1e6
  c.cacheWrite = (p.cacheWrite or 0) * u.cacheWrite / 1e6
  c.total = c.input + c.output + c.cacheRead + c.cacheWrite
  return c
end

function M.builder(model, on_event)
  local msg = { role = "assistant", content = {}, api = model.api, provider = model.provider, model = model.id,
    usage = M.usage(), stopReason = "stop" }
  return setmetatable({ model = model, msg = msg, emit = on_event or function() end, open = {}, args = {} }, B)
end

function B:start()
  self.msg.timestamp = self.model.now and self.model.now() or os.time() * 1000
  self.emit({ type = "start", partial = self.msg })
end

local function block(self, key, kind, init)
  local i = self.open[key]
  if i and self.msg.content[i].type == kind then return i, self.msg.content[i] end
  if i then self:close(key) end
  local b = init
  b.type = kind
  self.msg.content[#self.msg.content + 1] = b
  i = #self.msg.content
  self.open[key] = i
  local start = kind == "toolCall" and "toolcall_start" or (kind .. "_start")
  self.emit({ type = start, contentIndex = i, partial = self.msg })
  return i, b
end

function B:text(key, piece)
  local i, b = block(self, key, "text", { text = "" })
  if piece and piece ~= "" then
    b.text = b.text .. piece
    self.emit({ type = "text_delta", contentIndex = i, delta = piece, partial = self.msg })
  end
end

function B:thinking(key, piece, signature)
  local i, b = block(self, key, "thinking", { thinking = "" })
  if signature then b.signature = (b.signature or "") .. signature end
  if piece and piece ~= "" then
    b.thinking = b.thinking .. piece
    self.emit({ type = "thinking_delta", contentIndex = i, delta = piece, partial = self.msg })
  end
end

function B:tool(key, id, name, piece)
  local i, b = block(self, key, "toolCall", { id = id or "", name = name or "", arguments = {} })
  if id and id ~= "" then b.id = id end
  if name and name ~= "" then b.name = name end
  if piece and piece ~= "" then
    self.args[i] = (self.args[i] or "") .. piece
    local ok, v = pcall(json.decode, self.args[i])
    if ok and type(v) == "table" then b.arguments = v end
    self.emit({ type = "toolcall_delta", contentIndex = i, delta = piece, partial = self.msg })
  end
end

function B:close(key)
  local i = self.open[key]
  if not i then return end
  self.open[key] = nil
  local b = self.msg.content[i]
  if b.type == "toolCall" then
    local raw = self.args[i]
    if raw and raw ~= "" then
      local ok, v = pcall(json.decode, raw)
      b.arguments = ok and type(v) == "table" and v or {}
    end
    self.emit({ type = "toolcall_end", contentIndex = i, toolCall = b, partial = self.msg })
  else
    self.emit({ type = b.type .. "_end", contentIndex = i, content = b.text or b.thinking, partial = self.msg })
  end
end

function B:usage(u)
  local t = self.msg.usage
  for _, k in ipairs({ "input", "output", "cacheRead", "cacheWrite" }) do
    if u[k] then t[k] = u[k] end
  end
  t.totalTokens = t.input + t.output + t.cacheRead + t.cacheWrite
  M.cost(self.model, t)
end

local function close_all(self)
  local keys = {}
  for k, i in pairs(self.open) do keys[#keys + 1] = { k, i } end
  table.sort(keys, function(a, b) return a[2] < b[2] end)
  for _, k in ipairs(keys) do self:close(k[1]) end
end

function B:done(reason)
  close_all(self)
  local has_tool = false
  for _, b in ipairs(self.msg.content) do if b.type == "toolCall" then has_tool = true end end
  self.msg.stopReason = (has_tool and reason == "stop") and "toolUse" or reason or "stop"
  self.emit({ type = "done", reason = self.msg.stopReason, message = self.msg })
  return self.msg
end

function B:fail(err, aborted)
  close_all(self)
  self.msg.stopReason = aborted and "aborted" or "error"
  self.msg.errorMessage = type(err) == "table" and (err.message or tostring(err)) or tostring(err)
  if type(err) == "table" and err.status then self.msg.errorStatus = err.status end   -- a refusal (401, 402, 429) keeps its HTTP status
  self.emit({ type = "error", reason = self.msg.stopReason, error = self.msg })
  return self.msg
end

return M
