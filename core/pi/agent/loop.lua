-- pi's agent loop (pi-agent-core's agentLoop), in portable Lua: the model answers, its tool calls run, their
-- results go back, until it answers without one. Steering messages are put in before the next answer; follow-ups
-- are taken when it would stop. Everything that happens is an event, as pi names them: agent_start, turn_start,
-- message_start, message_update, message_end, tool_execution_start, tool_execution_update, tool_execution_end,
-- turn_end, agent_end.
--
--   loop.run(prompts, context, config, emit, signal?) -> new messages      (a new prompt: user messages)
--   loop.continue(context, config, emit, signal?) -> new messages           (retry: the context ends in user/toolResult)
--
--   context = { systemPrompt, messages, tools }
--   tool    = { name, description, parameters (JSON Schema), label?, sequential?,
--               execute(id, args, signal, on_update, ctx) -> result,
--               start?(id, args, signal, on_update, ctx) -> handle,  finish?(handle) -> result }
--   result  = { content = { {type="text", text} | {type="image", data, mimeType} } | "text", details?, terminate? }
--   config  = { host, model, reasoning?, apiKey? | get_api_key(provider), maxTokens?, temperature?,
--               convert_to_llm?(messages), transform_context?(messages, signal),
--               get_steering_messages?(), get_follow_up_messages?(),
--               before_tool_call?(ctx, signal) -> { block = true, reason }?,
--               after_tool_call?(ctx, signal) -> { content?, details?, isError?, terminate? }?,
--               prepare_next_turn?(ctx) -> { context?, model?, reasoning? }?, should_stop_after_turn?(ctx),
--               tool_execution? = "parallel" | "sequential", stream_fn?, now? }
--
-- A tool with start and finish runs in a wave: every call of the turn is started, then each is finished in order,
-- so a host's hands can work on them together. A tool with only execute runs where it stands. The loop never
-- yields itself; a host that waits on its hands runs it in a coroutine and yields from the tool.
local ai = require("pi.ai")
local validate = require("pi.ai.validate")

local M = {}

local function now(config) return config.now and config.now() or os.time() * 1000 end

local function default_convert(messages)
  local out = {}
  for _, m in ipairs(messages) do
    if m.role == "user" or m.role == "assistant" or m.role == "toolResult" then out[#out + 1] = m end
  end
  return out
end

local function content_of(c)
  if type(c) == "string" then return { { type = "text", text = c } } end
  return c or {}
end

local function error_result(text) return { content = { { type = "text", text = text } }, details = {} } end

local function stream_reply(context, config, signal, emit)
  local messages = context.messages
  if config.transform_context then messages = config.transform_context(messages, signal) or messages end
  local llm = (config.convert_to_llm or default_convert)(messages)
  local key = (config.get_api_key and config.get_api_key(config.model.provider)) or config.apiKey
  local stream = config.stream_fn or ai.stream
  local added = false
  local final = stream(config.host, config.model, { systemPrompt = context.systemPrompt, messages = llm,
    tools = context.tools }, { apiKey = key, reasoning = config.reasoning, maxTokens = config.maxTokens,
    temperature = config.temperature, signal = signal }, function(e)
    if e.type == "start" then
      context.messages[#context.messages + 1] = e.partial
      added = true
      emit({ type = "message_start", message = e.partial })
    elseif e.type ~= "done" and e.type ~= "error" and added then
      emit({ type = "message_update", assistantMessageEvent = e, message = e.partial })
    end
  end)
  if added then context.messages[#context.messages] = final
  else
    context.messages[#context.messages + 1] = final
    emit({ type = "message_start", message = final })
  end
  emit({ type = "message_end", message = final })
  return final
end

local function find_tool(context, name)
  for _, t in ipairs(context.tools or {}) do if t.name == name then return t end end
end

-- validate and ask before_tool_call: { tool, args } to run, or an immediate result
local function prepare(context, assistant, call, config, signal)
  local tool = find_tool(context, call.name)
  if not tool then return { result = error_result("Tool " .. call.name .. " not found"), isError = true } end
  local ok, args = pcall(validate.arguments, tool, call.arguments)
  if not ok then return { result = error_result(tostring(args)), isError = true } end
  if config.before_tool_call then
    local before = config.before_tool_call({ assistantMessage = assistant, toolCall = call, args = args,
      context = context }, signal)
    if signal and signal.aborted then return { result = error_result("Operation aborted"), isError = true } end
    if before and before.block then
      return { result = error_result(before.reason or "Tool execution was blocked"), isError = true }
    end
  end
  if signal and signal.aborted then return { result = error_result("Operation aborted"), isError = true } end
  return { tool = tool, args = args }
end

local function updater(call, emit)
  return function(partial)
    emit({ type = "tool_execution_update", toolCallId = call.id, toolName = call.name, args = call.arguments,
      partialResult = partial })
  end
end

local function finalize(context, assistant, call, prep, ok, result, config, signal)
  local isError = not ok
  if not ok then result = error_result(type(result) == "table" and tostring(result.message or result)
    or tostring(result)) end
  result = result or { content = {} }
  result.content = content_of(result.content)
  if config.after_tool_call then
    local after_ok, after = pcall(config.after_tool_call, { assistantMessage = assistant, toolCall = call,
      args = prep.args, result = result, isError = isError, context = context }, signal)
    if not after_ok then
      result, isError = error_result(tostring(after)), true
    elseif after then
      result = { content = after.content and content_of(after.content) or result.content,
        details = after.details or result.details,
        terminate = after.terminate == nil and result.terminate or after.terminate }
      if after.isError ~= nil then isError = after.isError end
    end
  end
  return { call = call, result = result, isError = isError }
end

local function result_message(f, config)
  return { role = "toolResult", toolCallId = f.call.id, toolName = f.call.name, content = f.result.content,
    details = f.result.details, isError = f.isError, timestamp = now(config) }
end

local function end_event(f, emit)
  emit({ type = "tool_execution_end", toolCallId = f.call.id, toolName = f.call.name, result = f.result,
    isError = f.isError })
end

local function execute_calls(context, assistant, config, signal, emit)
  local calls = {}
  for _, b in ipairs(assistant.content) do if b.type == "toolCall" then calls[#calls + 1] = b end end
  local sequential = config.tool_execution == "sequential"
  for _, c in ipairs(calls) do
    local t = find_tool(context, c.name)
    if t and t.sequential then sequential = true end
  end
  local done, pending = {}, {}
  for i, call in ipairs(calls) do
    emit({ type = "tool_execution_start", toolCallId = call.id, toolName = call.name, args = call.arguments })
    local prep = prepare(context, assistant, call, config, signal)
    if prep.result then
      done[i] = { call = call, result = prep.result, isError = true }
      end_event(done[i], emit)
    elseif prep.tool.start and not sequential then
      local ok, handle = pcall(prep.tool.start, call.id, prep.args, signal, updater(call, emit), context)
      pending[#pending + 1] = { i = i, call = call, prep = prep, ok = ok, handle = handle }
    else
      local ok, result = pcall(prep.tool.execute, call.id, prep.args, signal, updater(call, emit), context)
      done[i] = finalize(context, assistant, call, prep, ok, result, config, signal)
      end_event(done[i], emit)
    end
    if signal and signal.aborted then break end
  end
  for _, p in ipairs(pending) do
    local ok, result = p.ok, p.handle
    if ok then ok, result = pcall(p.prep.tool.finish, p.handle) end
    done[p.i] = finalize(context, assistant, p.call, p.prep, ok, result, config, signal)
    end_event(done[p.i], emit)
  end
  local messages, all_terminate = {}, #calls > 0
  for i = 1, #calls do
    local f = done[i]
    if f then
      local m = result_message(f, config)
      emit({ type = "message_start", message = m })
      emit({ type = "message_end", message = m })
      messages[#messages + 1] = m
      if f.result.terminate ~= true then all_terminate = false end
    end
  end
  return messages, all_terminate
end

local function push(context, new, m)
  context.messages[#context.messages + 1] = m
  new[#new + 1] = m
end

local function run_loop(context, new, config, signal, emit)
  local first = true
  local pending = config.get_steering_messages and config.get_steering_messages() or {}
  while true do
    local more = true
    while more or #pending > 0 do
      if not first then emit({ type = "turn_start" }) end
      first = false
      for _, m in ipairs(pending) do
        emit({ type = "message_start", message = m })
        emit({ type = "message_end", message = m })
        push(context, new, m)
      end
      pending = {}
      local msg = stream_reply(context, config, signal, emit)
      new[#new + 1] = msg
      if msg.stopReason == "error" or msg.stopReason == "aborted" then
        emit({ type = "turn_end", message = msg, toolResults = {} })
        emit({ type = "agent_end", messages = new })
        return new
      end
      local results, terminate = {}, false
      more = false
      for _, b in ipairs(msg.content) do if b.type == "toolCall" then more = true end end
      if more then
        results, terminate = execute_calls(context, msg, config, signal, emit)
        more = not terminate
        for _, r in ipairs(results) do push(context, new, r) end
      end
      emit({ type = "turn_end", message = msg, toolResults = results })
      local turn = { message = msg, toolResults = results, context = context, newMessages = new }
      local snap = config.prepare_next_turn and config.prepare_next_turn(turn)
      if snap then
        context = snap.context or context
        if snap.model or snap.reasoning ~= nil then
          local c = {}
          for k, v in pairs(config) do c[k] = v end
          c.model = snap.model or config.model
          if snap.reasoning ~= nil then c.reasoning = snap.reasoning ~= "off" and snap.reasoning or nil end
          config = c
        end
      end
      if config.should_stop_after_turn and config.should_stop_after_turn(turn) then
        emit({ type = "agent_end", messages = new })
        return new
      end
      if signal and signal.aborted then more = false end
      pending = config.get_steering_messages and config.get_steering_messages() or {}
    end
    local follow = config.get_follow_up_messages and config.get_follow_up_messages() or {}
    if #follow == 0 then break end
    pending = follow
  end
  emit({ type = "agent_end", messages = new })
  return new
end

function M.run(prompts, context, config, emit, signal)
  emit = emit or function() end
  local new = {}
  local ctx = { systemPrompt = context.systemPrompt, tools = context.tools, messages = {} }
  for _, m in ipairs(context.messages or {}) do ctx.messages[#ctx.messages + 1] = m end
  emit({ type = "agent_start" })
  emit({ type = "turn_start" })
  for _, p in ipairs(prompts) do
    emit({ type = "message_start", message = p })
    emit({ type = "message_end", message = p })
    push(ctx, new, p)
  end
  return run_loop(ctx, new, config, signal, emit)
end

function M.continue(context, config, emit, signal)
  local msgs = context.messages or {}
  if #msgs == 0 then error("Cannot continue: no messages in context", 0) end
  if msgs[#msgs].role == "assistant" then error("Cannot continue from message role: assistant", 0) end
  emit = emit or function() end
  local ctx = { systemPrompt = context.systemPrompt, tools = context.tools, messages = {} }
  for _, m in ipairs(msgs) do ctx.messages[#ctx.messages + 1] = m end
  emit({ type = "agent_start" })
  emit({ type = "turn_start" })
  return run_loop(ctx, {}, config, signal, emit)
end

return M
