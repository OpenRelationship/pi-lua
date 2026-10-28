-- Extensions as pi has them: a function given the extension API, which registers tools and commands and hears the
-- session's events, some of which it may answer to change what happens.
--
--   return function(pi)
--     pi.register_tool{ name, label?, description, parameters, execute(id, args, signal, on_update, ctx) -> result }
--     pi.register_command("name", { description, handler = function(args, ctx) end })
--     pi.on("tool_call", function(event, ctx) return { block = true, reason = "..." } end)
--   end
--
-- Events, with what an answer may do (first block wins; the rest chain, each handler seeing the last's change):
--   session_start, session_shutdown, agent_start, agent_end, turn_start, turn_end, message_start, message_update,
--   message_end, tool_execution_start, tool_execution_update, tool_execution_end, model_select,
--   thinking_level_select, session_compact                                          (heard only)
--   input { text, images, source }            -> { action = "continue" | "transform", text, images } | "handled"
--   before_agent_start { prompt, images, systemPrompt } -> { systemPrompt?, message? = { customType, content, ... } }
--   context { messages }                      -> { messages }      (what this model call sees; the session keeps all)
--   tool_call { toolName, toolCallId, input } -> { block, reason }  (change arguments by editing event.input)
--   tool_result { toolName, toolCallId, input, content, details, isError } -> { content?, details?, isError? }
--   session_before_compact { preparation }    -> { cancel? , summary? }
--
-- The rest of the API: send_message(msg, { triggerTurn?, deliverAs? = "steer" | "followUp" | "nextTurn" }),
-- send_user_message(content, { deliverAs? }), append_entry(customType, data), set_session_name(name),
-- get_session_name(), set_label(entryId, label), get_active_tools(), get_all_tools(), set_active_tools(names),
-- get_commands(), set_model(model), get_thinking_level(), set_thinking_level(level), events (a bus between
-- extensions: events.on(name, fn), events.emit(name, data)).
local M = {}
local R = {}
R.__index = R

function M.runner(on_error)
  return setmetatable({ handlers = {}, tools = {}, tool_order = {}, commands = {}, bus = {},
    on_error = on_error or function() end, errors = {} }, R)
end

-- the API one extension is given; session is the pi.session that owns this runner
function R:api(session)
  local r = self
  local api = {}
  function api.on(event, fn)
    r.handlers[event] = r.handlers[event] or {}
    local list = r.handlers[event]
    list[#list + 1] = fn
  end
  function api.register_tool(tool)
    assert(type(tool.name) == "string", "a tool needs its name")
    if not r.tools[tool.name] then r.tool_order[#r.tool_order + 1] = tool.name end
    r.tools[tool.name] = tool
    if session then session:refresh_tools(tool.name) end
  end
  function api.register_command(name, spec)
    r.commands[name] = { name = name, description = spec.description, handler = spec.handler }
  end
  function api.get_commands()
    local out = {}
    for name, c in pairs(r.commands) do out[#out + 1] = { name = name, description = c.description } end
    table.sort(out, function(a, b) return a.name < b.name end)
    return out
  end
  api.events = {
    on = function(name, fn)
      r.bus[name] = r.bus[name] or {}
      r.bus[name][#r.bus[name] + 1] = fn
    end,
    emit = function(name, data)
      for _, fn in ipairs(r.bus[name] or {}) do fn(data) end
    end,
  }
  if session then
    function api.send_message(msg, opts) return session:send_message(msg, opts) end
    function api.send_user_message(content, opts) return session:send_user_message(content, opts) end
    function api.append_entry(custom_type, data) return session.store:append_custom(custom_type, data) end
    function api.set_session_name(name) return session.store:set_name(name) end
    function api.get_session_name() return session.store:name() end
    function api.set_label(id, label) return session.store:set_label(id, label) end
    function api.get_active_tools() return session:active_tools() end
    function api.get_all_tools() return session:all_tools() end
    function api.set_active_tools(names) return session:set_active_tools(names) end
    function api.set_model(model) return session:set_model(model) end
    function api.get_thinking_level() return session.agent.state.thinkingLevel end
    function api.set_thinking_level(level) return session:set_thinking_level(level) end
  end
  return api
end

function R:load(fn, session)
  local ok, err = pcall(fn, self:api(session))
  if not ok then self:fail("load", err) end
end

function R:fail(event, err)
  local e = { event = event, error = tostring(type(err) == "table" and (err.message or err) or err) }
  self.errors[#self.errors + 1] = e
  self.on_error(e)
end

function R:has(event) return self.handlers[event] ~= nil and #self.handlers[event] > 0 end

-- every handler of event in turn; each answer is handed to fold(answer) -> stop?
function R:each(event, payload, ctx, fold)
  for _, fn in ipairs(self.handlers[event] or {}) do
    local ok, answer = pcall(fn, payload, ctx)
    if not ok then self:fail(event, answer)
    elseif answer ~= nil and fold and fold(answer) then return answer end
  end
end

function R:emit(event, ctx) self:each(event.type, event, ctx) end

function R:input(text, images, source, ctx)
  local ev = { type = "input", text = text, images = images, source = source }
  local handled = false
  self:each("input", ev, ctx, function(a)
    if a == "handled" or a.action == "handled" then handled = true return true end
    if a.action == "transform" then ev.text, ev.images = a.text or ev.text, a.images or ev.images end
  end)
  return handled, ev.text, ev.images
end

function R:before_agent_start(prompt, images, system, ctx)
  local ev = { type = "before_agent_start", prompt = prompt, images = images, systemPrompt = system }
  local extra = {}
  self:each("before_agent_start", ev, ctx, function(a)
    if a.systemPrompt then ev.systemPrompt = a.systemPrompt end
    if a.message then extra[#extra + 1] = a.message end
  end)
  return ev.systemPrompt, extra
end

function R:context(list, ctx)
  local ev = { type = "context", messages = list }
  self:each("context", ev, ctx, function(a) if a.messages then ev.messages = a.messages end end)
  return ev.messages
end

function R:tool_call(name, id, input, ctx)
  local ev = { type = "tool_call", toolName = name, toolCallId = id, input = input }
  return self:each("tool_call", ev, ctx, function(a) return a.block end)
end

function R:tool_result(name, id, input, result, is_error, ctx)
  local ev = { type = "tool_result", toolName = name, toolCallId = id, input = input, content = result.content,
    details = result.details, isError = is_error }
  local changed = false
  self:each("tool_result", ev, ctx, function(a)
    changed = true
    if a.content then ev.content = a.content end
    if a.details ~= nil then ev.details = a.details end
    if a.isError ~= nil then ev.isError = a.isError end
  end)
  if changed then return { content = ev.content, details = ev.details, isError = ev.isError } end
end

function R:before_compact(prep, ctx)
  local ev = { type = "session_before_compact", preparation = prep }
  return self:each("session_before_compact", ev, ctx, function(a) return a.cancel or a.summary end)
end

return M
