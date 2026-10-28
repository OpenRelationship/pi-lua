-- pi's AgentSession: the Agent, its session file, its extensions and compaction, as a host drives them.
--
--   local session = require("pi.session")
--   local s = session.new{ host, model, apiKey? | get_api_key?, systemPrompt?, thinkingLevel?, tools? = { tool... },
--                          extensions? = { fn(pi)... }, store? = pi.store | store_opts? (pi.store.open's),
--                          compaction? = settings, ui?, cwd?, on_error?(e), now?, tool_execution? }
--   s:prompt(text, { images?, source? })   a turn: input handlers, "/command args", before_agent_start, the agent
--   s:steer(text)  s:follow_up(text)  s:abort()  s:compact(instructions?) -> summary | nil, why
--   s:subscribe(fn(event))   s:set_model(model)   s:set_thinking_level(level)   s:set_active_tools(names)
--   s:send_message(msg, opts)  s:send_user_message(content, opts)  s:shutdown()
--   s.agent (pi.agent)  s.store (pi.store)  s.extensions (the runner)
--
-- On open the agent resumes the store's conversation (store:context()). Every message the agent ends is appended
-- to the store as it happens, so a host that writes the store as JSONL can resume after a crash.
local agent = require("pi.agent")
local store = require("pi.store")
local extensions = require("pi.extensions")
local compaction = require("pi.compaction")
local messages = require("pi.messages")

local M = {}
local S = {}
S.__index = S

local function ctx_of(self, signal)
  return { session = self, model = self.agent.state.model, signal = signal, ui = self.ui, cwd = self.cwd,
    is_idle = function() return not self.agent.state.isStreaming end,
    abort = function() self.agent:abort() end,
    has_pending_messages = function() return self.agent:has_queued() end,
    get_context_usage = function() return self:context_usage() end,
    compact = function(o) return self:compact(o and o.customInstructions) end }
end

-- a registered tool as the agent runs it: the extension context comes as execute's fifth argument, as in pi
local function wrap(self, tool)
  local w = {}
  for k, v in pairs(tool) do w[k] = v end
  if tool.execute then
    w.execute = function(id, args, signal, on_update) return tool.execute(id, args, signal, on_update, ctx_of(self, signal)) end
  end
  if tool.start then
    w.start = function(id, args, signal, on_update) return tool.start(id, args, signal, on_update, ctx_of(self, signal)) end
  end
  return w
end

function M.new(opts)
  local self = setmetatable({ host = opts.host, ui = opts.ui, cwd = opts.cwd, base_tools = opts.tools or {},
    settings = opts.compaction or compaction.settings, listeners = {}, next_turn = {}, active = nil,
    get_api_key = opts.get_api_key, apiKey = opts.apiKey, now = opts.now }, S)
  self.store = opts.store or store.open(opts.store_opts)
  self.extensions = extensions.runner(opts.on_error)
  local resumed = self.store:context()
  self.agent = agent.new({ host = opts.host, model = opts.model, apiKey = opts.apiKey, get_api_key = opts.get_api_key,
    systemPrompt = opts.systemPrompt or "", thinkingLevel = opts.thinkingLevel or resumed.thinkingLevel,
    messages = resumed.messages, now = opts.now, tool_execution = opts.tool_execution, stream_fn = opts.stream_fn,
    convert_to_llm = messages.to_llm })
  self.base_system = opts.systemPrompt or ""
  local a = self.agent
  a:set("transform_context", function(list, signal)
    if not self.extensions:has("context") then return list end
    return self.extensions:context(list, ctx_of(self, signal))
  end)
  a:set("before_tool_call", function(c, signal)
    return self.extensions:tool_call(c.toolCall.name, c.toolCall.id, c.args, ctx_of(self, signal))
  end)
  a:set("after_tool_call", function(c, signal)
    return self.extensions:tool_result(c.toolCall.name, c.toolCall.id, c.args, c.result, c.isError,
      ctx_of(self, signal))
  end)
  a:subscribe(function(event, signal)
    if event.type == "message_end" then
      local m = event.message
      if m.role == "custom" then self.store:append_custom_message(m.customType, m.content, m.display, m.details)
      else self.store:append_message(m) end
    end
    self.extensions:emit(event, ctx_of(self, signal))
    for _, l in ipairs(self.listeners) do l(event) end
  end)
  for _, fn in ipairs(opts.extensions or {}) do self.extensions:load(fn, self) end
  self:refresh_tools()
  self.extensions:emit({ type = "session_start" }, ctx_of(self))
  return self
end

function S:subscribe(fn) self.listeners[#self.listeners + 1] = fn end

function S:all_tools()
  local out = {}
  for _, t in ipairs(self.base_tools) do out[#out + 1] = t end
  for _, name in ipairs(self.extensions.tool_order) do out[#out + 1] = self.extensions.tools[name] end
  return out
end

function S:active_tools()
  local out = {}
  for _, t in ipairs(self.agent.state.tools) do out[#out + 1] = t.name end
  return out
end

-- the agent's tools: every tool, or only those named active; a newly registered tool is active unless a list is set
function S:refresh_tools(added)
  if added and self.active then self.active[#self.active + 1] = added end
  local keep
  if self.active then
    keep = {}
    for _, n in ipairs(self.active) do keep[n] = true end
  end
  local tools = {}
  for _, t in ipairs(self:all_tools()) do
    if not keep or keep[t.name] then tools[#tools + 1] = wrap(self, t) end
  end
  self.agent.state.tools = tools
end

function S:set_active_tools(names)
  self.active = {}
  for i, n in ipairs(names) do self.active[i] = n end
  self:refresh_tools()
end

function S:set_model(model)
  self.agent.state.model = model
  self.store:append_model_change(model.provider, model.id)
  self.extensions:emit({ type = "model_select", model = model }, ctx_of(self))
  return true
end

function S:set_thinking_level(level)
  self.agent.state.thinkingLevel = level
  self.store:append_thinking_level_change(level)
  self.extensions:emit({ type = "thinking_level_select", level = level }, ctx_of(self))
end

local function stamp(self) return self.now and self.now() or os.time() * 1000 end

local function custom(self, msg)
  return { role = "custom", customType = msg.customType, content = msg.content, display = msg.display ~= false,
    details = msg.details, timestamp = stamp(self) }
end

local function run_command(self, text)
  local name, args = text:match("^/(%S+)%s*(.*)$")
  local cmd = name and self.extensions.commands[name]
  if not cmd then return false end
  local ok, err = pcall(cmd.handler, args, ctx_of(self))
  if not ok then self.extensions:fail("command /" .. name, err) end
  return true
end

function S:prompt(text, opts)
  opts = opts or {}
  -- a command runs first, even while the agent works, as in pi; then input handlers may take or change the words
  if text:sub(1, 1) == "/" and run_command(self, text) then return end
  local handled, t, images = self.extensions:input(text, opts.images, opts.source or "host", ctx_of(self))
  if handled then return end
  if self.agent.state.isStreaming then return self:steer(t, images) end
  local system, extra = self.extensions:before_agent_start(t, images, self.base_system, ctx_of(self))
  local batch = { self.agent:user(t, images) }
  for _, m in ipairs(self.next_turn) do batch[#batch + 1] = m end
  self.next_turn = {}
  for _, m in ipairs(extra) do batch[#batch + 1] = custom(self, m) end
  self.agent.state.systemPrompt = system
  self.agent:prompt(batch)
  self.agent.state.systemPrompt = self.base_system
  self:auto_compact()
end

function S:steer(text, images) self.agent:steer(self.agent:user(text, images)) end
function S:follow_up(text, images) self.agent:follow_up(self.agent:user(text, images)) end
function S:abort() self.agent:abort() end

function S:send_user_message(content, opts)
  opts = opts or {}
  local m = type(content) == "string" and self.agent:user(content)
    or { role = "user", content = content, timestamp = stamp(self) }
  if self.agent.state.isStreaming then
    if opts.deliverAs == "followUp" then self.agent:follow_up(m) else self.agent:steer(m) end
  else
    self.agent:prompt({ m })
    self:auto_compact()
  end
end

function S:send_message(msg, opts)
  opts = opts or {}
  local m = custom(self, msg)
  if opts.deliverAs == "nextTurn" then self.next_turn[#self.next_turn + 1] = m return end
  if self.agent.state.isStreaming then
    if opts.deliverAs == "followUp" then self.agent:follow_up(m) else self.agent:steer(m) end
  elseif opts.triggerTurn then
    self.agent:prompt({ m })
    self:auto_compact()
  else
    self.agent.state.messages[#self.agent.state.messages + 1] = m
    self.store:append_custom_message(m.customType, m.content, m.display, m.details)
  end
end

function S:context_usage()
  local window = self.agent.state.model and self.agent.state.model.contextWindow
  local tokens = compaction.context_tokens(self.agent.state.messages)
  return { tokens = tokens, contextWindow = window, percent = window and (100 * tokens / window) or nil }
end

function S:auto_compact()
  local u = self:context_usage()
  if compaction.should(u.tokens, u.contextWindow, self.settings) then self:compact() end
end

function S:compact(instructions)
  local prep = compaction.prepare(self.store:path(), self.settings)
  if not prep then return nil, "nothing to compact" end
  local answer = self.extensions:before_compact(prep, ctx_of(self))
  if answer and answer.cancel then return nil, "cancelled by an extension" end
  local summary, why = answer and answer.summary, nil
  if not summary then
    local model = self.agent.state.model
    local key = (self.get_api_key and self.get_api_key(model.provider)) or self.apiKey
    summary, why = compaction.summarize(self.host, model, prep, { apiKey = key, instructions = instructions,
      stream_fn = self.agent.hooks.stream_fn })
  end
  if not summary then return nil, why end
  self.store:append_compaction(summary, prep.firstKeptEntryId, prep.tokensBefore)
  self.agent.state.messages = self.store:context().messages
  self.extensions:emit({ type = "session_compact", summary = summary, tokensBefore = prep.tokensBefore }, ctx_of(self))
  return summary
end

function S:shutdown() self.extensions:emit({ type = "session_shutdown" }, ctx_of(self)) end

return M
