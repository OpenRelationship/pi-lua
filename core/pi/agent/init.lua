-- pi's Agent (pi-agent-core): the loop with its state kept, its events heard, and messages queued while it runs.
--
--   local agent = require("pi.agent")
--   local a = agent.new{ host, model, systemPrompt?, tools?, messages?, thinkingLevel? = "off" | "minimal" | "low"
--                        | "medium" | "high", apiKey? | get_api_key?, steeringMode?, followUpMode? ("one-at-a-time"
--                        | "all"), and any loop hook (before_tool_call, after_tool_call, transform_context,
--                        convert_to_llm, prepare_next_turn, should_stop_after_turn, tool_execution, stream_fn, now) }
--   local off = a:subscribe(function(event, signal) end)
--   a:prompt("text" | message | { messages }, images?)      runs to the end (in the caller's coroutine, if any)
--   a:continue()       a:steer(message)   a:follow_up(message)   a:abort()   a:reset()
--   a.state = { systemPrompt, model, thinkingLevel, tools, messages, isStreaming, streamingMessage,
--               pendingToolCalls (id -> true), errorMessage }
--
-- steer is heard before the model's next answer; follow_up only once it would stop. Both may be called from a tool,
-- a listener, or between a coroutine's resumes while the agent runs.
local loop = require("pi.agent.loop")
local message = require("pi.ai.message")

local M = {}
local A = {}
A.__index = A
M.Agent = A

local hooks = { "before_tool_call", "after_tool_call", "transform_context", "convert_to_llm", "prepare_next_turn",
  "should_stop_after_turn", "tool_execution", "stream_fn", "get_api_key", "maxTokens", "temperature" }

local function queue(mode) return { mode = mode or "one-at-a-time", items = {} } end

local function drain(q)
  if q.mode == "all" then
    local all = q.items
    q.items = {}
    return all
  end
  if #q.items == 0 then return {} end
  return { table.remove(q.items, 1) }
end

function M.new(opts)
  opts = opts or {}
  local a = setmetatable({ host = opts.host, apiKey = opts.apiKey, now = opts.now, listeners = {},
    steering = queue(opts.steeringMode), follow = queue(opts.followUpMode), hooks = {} }, A)
  for _, k in ipairs(hooks) do a.hooks[k] = opts[k] end
  a.state = { systemPrompt = opts.systemPrompt or "", model = opts.model, thinkingLevel = opts.thinkingLevel or "off",
    tools = opts.tools or {}, messages = opts.messages or {}, isStreaming = false, pendingToolCalls = {} }
  return a
end

function A:subscribe(fn)
  self.listeners[#self.listeners + 1] = fn
  return function()
    for i, l in ipairs(self.listeners) do
      if l == fn then table.remove(self.listeners, i) return end
    end
  end
end

function A:set(key, fn) self.hooks[key] = fn end

function A:steer(m) self.steering.items[#self.steering.items + 1] = m end
function A:follow_up(m) self.follow.items[#self.follow.items + 1] = m end
function A:clear_queues() self.steering.items, self.follow.items = {}, {} end
function A:has_queued() return #self.steering.items > 0 or #self.follow.items > 0 end

function A:abort()
  if self.run then self.run.signal.aborted = true end
end

function A:reset()
  self.state.messages = {}
  self.state.isStreaming = false
  self.state.streamingMessage = nil
  self.state.pendingToolCalls = {}
  self.state.errorMessage = nil
  self:clear_queues()
end

local function stamp(self) return self.now and self.now() or os.time() * 1000 end

function A:user(text, images)
  local content = { { type = "text", text = text } }
  for _, im in ipairs(images or {}) do content[#content + 1] = im end
  return { role = "user", content = content, timestamp = stamp(self) }
end

function A:process(event)
  local s = self.state
  local t = event.type
  if t == "message_start" or t == "message_update" then
    s.streamingMessage = event.message
  elseif t == "message_end" then
    s.streamingMessage = nil
    s.messages[#s.messages + 1] = event.message
  elseif t == "tool_execution_start" then
    s.pendingToolCalls[event.toolCallId] = true
  elseif t == "tool_execution_end" then
    s.pendingToolCalls[event.toolCallId] = nil
  elseif t == "turn_end" then
    if event.message.role == "assistant" and event.message.errorMessage then s.errorMessage = event.message.errorMessage end
  elseif t == "agent_end" then
    s.streamingMessage = nil
  end
  local signal = self.run and self.run.signal
  for _, l in ipairs(self.listeners) do l(event, signal) end
end

function A:config(skip_steering)
  local c = { host = self.host, model = self.state.model, apiKey = self.apiKey, now = self.now,
    reasoning = self.state.thinkingLevel ~= "off" and self.state.thinkingLevel or nil }
  for _, k in ipairs(hooks) do c[k] = self.hooks[k] end
  local skip = skip_steering
  c.get_steering_messages = function()
    if skip then skip = false return {} end
    return drain(self.steering)
  end
  c.get_follow_up_messages = function() return drain(self.follow) end
  if self.hooks.prepare_next_turn then
    c.prepare_next_turn = function(turn) return self.hooks.prepare_next_turn(turn, self.run and self.run.signal) end
  end
  return c
end

function A:snapshot()
  local msgs, tools = {}, {}
  for i, m in ipairs(self.state.messages) do msgs[i] = m end
  for i, t in ipairs(self.state.tools) do tools[i] = t end
  return { systemPrompt = self.state.systemPrompt, messages = msgs, tools = tools }
end

-- one run of the loop, its failures turned into an assistant message as pi's agent does
function A:lifecycle(body)
  if self.run then error("Agent is already processing a prompt. Use steer() or follow_up() to queue messages.", 0) end
  self.run = { signal = { aborted = false } }
  local s = self.state
  s.isStreaming, s.streamingMessage, s.errorMessage = true, nil, nil
  local emit = function(e) self:process(e) end
  local ok, err = pcall(body, emit, self.run.signal)
  if not ok then
    local m = s.model or {}
    local failure = { role = "assistant", content = { { type = "text", text = "" } }, api = m.api,
      provider = m.provider, model = m.id, usage = message.usage(),
      stopReason = self.run.signal.aborted and "aborted" or "error",
      errorMessage = type(err) == "table" and tostring(err.message or err) or tostring(err), timestamp = stamp(self) }
    emit({ type = "message_start", message = failure })
    emit({ type = "message_end", message = failure })
    emit({ type = "turn_end", message = failure, toolResults = {} })
    emit({ type = "agent_end", messages = { failure } })
  end
  s.isStreaming, s.streamingMessage, s.pendingToolCalls = false, nil, {}
  self.run = nil
end

function A:prompt(input, images)
  local msgs
  if type(input) == "string" then msgs = { self:user(input, images) }
  elseif input.role then msgs = { input }
  else msgs = input end
  self:run_messages(msgs)
end

function A:run_messages(msgs, skip_steering)
  self:lifecycle(function(emit, signal)
    -- the loop's own context copy; the agent's state is kept through message_end events
    local ctx = self:snapshot()
    loop.run(msgs, ctx, self:config(skip_steering), emit, signal)
  end)
end

function A:continue()
  if self.run then error("Agent is already processing. Wait for completion before continuing.", 0) end
  local last = self.state.messages[#self.state.messages]
  if not last then error("No messages to continue from", 0) end
  if last.role == "assistant" then
    local steering = drain(self.steering)
    if #steering > 0 then return self:run_messages(steering, true) end
    local follow = drain(self.follow)
    if #follow > 0 then return self:run_messages(follow) end
    error("Cannot continue from message role: assistant", 0)
  end
  self:lifecycle(function(emit, signal)
    loop.continue(self:snapshot(), self:config(), emit, signal)
  end)
end

return M
