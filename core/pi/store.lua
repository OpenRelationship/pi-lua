-- A session as pi keeps it: JSONL, one entry per line, each pointing at its parent, so the file is a tree and the
-- conversation is the path from the root to the current leaf (pi's SessionManager, format version 3).
--
--   local store = require("pi.store")
--   local s = store.open{ write = fn(line) | nil, lines = { existing lines } | nil, id = fn() -> string, now = fn()
--                         -> ms, cwd? }
--   s:append_message(msg) -> id      s:append_custom(customType, data) -> id
--   s:append_custom_message(customType, content, display?, details?) -> id
--   s:append_compaction(summary, firstKeptEntryId, tokensBefore, details?) -> id
--   s:append_model_change(provider, modelId)   s:append_thinking_level_change(level)   s:set_name(name)
--   s:set_label(entryId, label?)   s:branch(entryId)   (the next entry hangs from entryId)
--   s:entries() -> all entries in file order    s:path() -> the entries from the root to the leaf
--   s:context() -> { messages, thinkingLevel, model = { provider, modelId }? }  (what the agent resumes with)
--
-- write is the host's: a file append, a row in its database, nothing. pi.lua never touches a file itself.
local json = require("pi.json")

local M = {}
local S = {}
S.__index = S
M.VERSION = 3

local counter = 0
local function default_id()
  counter = counter + 1
  return ("%08x"):format((os.time() * 1000 + counter) % 4294967296)
end

function M.open(opts)
  opts = opts or {}
  local s = setmetatable({ write = opts.write, new_id = opts.id or default_id,
    now = opts.now or function() return os.time() * 1000 end, list = {}, by_id = {}, leaf = nil }, S)
  for _, line in ipairs(opts.lines or {}) do
    if line ~= "" then
      local ok, e = pcall(json.decode, line)
      if ok and type(e) == "table" then
        if e.type == "session" then s.header = e
        else
          s.list[#s.list + 1] = e
          if e.id then s.by_id[e.id] = e; s.leaf = e.id end
        end
      end
    end
  end
  if not s.header then
    s.header = { type = "session", version = M.VERSION, id = s.new_id(), timestamp = s.now(), cwd = opts.cwd }
    if s.write then s.write(json.encode(s.header)) end
  end
  return s
end

function S:id() return self.header.id end

local function add(self, e)
  e.id = self.new_id()
  while self.by_id[e.id] do e.id = self.new_id() end
  e.parentId = self.leaf or json.null
  e.timestamp = self.now()
  self.list[#self.list + 1] = e
  self.by_id[e.id] = e
  self.leaf = e.id
  if self.write then self.write(json.encode(e)) end
  return e.id
end

function S:append_message(msg) return add(self, { type = "message", message = msg }) end
function S:append_custom(customType, data) return add(self, { type = "custom", customType = customType, data = data }) end
function S:append_custom_message(customType, content, display, details)
  return add(self, { type = "custom_message", customType = customType, content = content, display = display ~= false,
    details = details })
end
function S:append_compaction(summary, first_kept, tokens_before, details)
  return add(self, { type = "compaction", summary = summary, firstKeptEntryId = first_kept,
    tokensBefore = tokens_before, details = details })
end
function S:append_model_change(provider, model_id)
  return add(self, { type = "model_change", provider = provider, modelId = model_id })
end
function S:append_thinking_level_change(level) return add(self, { type = "thinking_level_change", thinkingLevel = level }) end
function S:set_name(name) return add(self, { type = "session_info", name = name }) end
function S:set_label(target, label) return add(self, { type = "label", targetId = target, label = label }) end

function S:branch(entry_id)
  assert(self.by_id[entry_id], "no entry " .. tostring(entry_id))
  self.leaf = entry_id
end

function S:entries() return self.list end
function S:get(id) return self.by_id[id] end
function S:leaf_id() return self.leaf end

function S:path(from)
  local out, id = {}, from or self.leaf
  while id and id ~= json.null do
    local e = self.by_id[id]
    if not e then break end
    table.insert(out, 1, e)
    id = e.parentId
  end
  return out
end

function S:name()
  local name
  for _, e in ipairs(self:path()) do if e.type == "session_info" then name = e.name end end
  return name
end

local function as_message(e)
  if e.type == "message" then return e.message end
  if e.type == "custom_message" then
    return { role = "custom", customType = e.customType, content = e.content, display = e.display,
      details = e.details, timestamp = e.timestamp }
  end
end

-- the messages the agent resumes with: after the last compaction on the path, its summary, then the entries it
-- kept (from firstKeptEntryId) and everything after it
function S:context()
  local path = self:path()
  local ctx = { messages = {}, thinkingLevel = "off" }
  local last
  for i, e in ipairs(path) do
    if e.type == "compaction" then last = i end
    if e.type == "thinking_level_change" then ctx.thinkingLevel = e.thinkingLevel end
    -- the model last chosen or last answering, whichever came later
    if e.type == "model_change" then ctx.model = { provider = e.provider, modelId = e.modelId } end
    if e.type == "message" and e.message.role == "assistant" and e.message.model then
      ctx.model = { provider = e.message.provider, modelId = e.message.model }
    end
  end
  local from = 1
  if last then
    local c = path[last]
    ctx.messages[1] = { role = "compactionSummary", summary = c.summary, tokensBefore = c.tokensBefore,
      timestamp = c.timestamp }
    from = last + 1
    for i = 1, last - 1 do
      if path[i].id == c.firstKeptEntryId then
        for j = i, last - 1 do
          local m = as_message(path[j])
          if m then ctx.messages[#ctx.messages + 1] = m end
        end
        break
      end
    end
  end
  for i = from, #path do
    local m = as_message(path[i])
    if m then ctx.messages[#ctx.messages + 1] = m end
  end
  return ctx
end

return M
