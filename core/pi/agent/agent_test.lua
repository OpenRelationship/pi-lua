-- The agent loop and Agent against a scripted model: each call to stream_fn answers with the next reply in a list.
local spec = require("mono.spec")
local agent = require("pi.agent")
local loop = require("pi.agent.loop")
local message = require("pi.ai.message")

local model = { id = "m", provider = "test", api = "test" }

-- a stream_fn that plays replies in turn; each reply is a list of blocks, or a function of the context it was sent
local function scripted(replies)
  local seen = {}
  local fn = function(_, m, context, _, on_event)
    seen[#seen + 1] = context
    local r = table.remove(replies, 1)
    if type(r) == "function" then r = r(context) end
    local b = message.builder(m, on_event)
    b:start()
    for i, blk in ipairs(r or { { type = "text", text = "(none)" } }) do
      if blk.type == "text" then b:text(i, blk.text)
      elseif blk.type == "toolCall" then
        b:tool(i, blk.id, blk.name, require("pi.json").encode(blk.arguments or {}))
      end
    end
    return b:done("stop")
  end
  return fn, seen
end

local function call(id, name, args) return { type = "toolCall", id = id, name = name, arguments = args } end
local function text(t) return { type = "text", text = t } end

local add = { name = "add", description = "adds", parameters = { type = "object", required = { "a", "b" },
  properties = { a = { type = "number" }, b = { type = "number" } } },
  execute = function(_, args) return { content = tostring(args.a + args.b) } end }

spec.test("a tool call runs and its result goes back before the answer", function()
  local fn, seen = scripted({ { call("c1", "add", { a = 2, b = 3 }) }, { text("5") } })
  local types = {}
  local new = loop.run({ { role = "user", content = "2+3?" } }, { systemPrompt = "s", messages = {}, tools = { add } },
    { model = model, stream_fn = fn }, function(e) types[#types + 1] = e.type end)
  spec.eq(#new, 4)
  spec.eq(new[3].role, "toolResult")
  spec.eq(new[3].content[1].text, "5")
  spec.eq(new[3].isError, false)
  spec.eq(new[4].content[1].text, "5")
  spec.eq(seen[2].messages[3].role, "toolResult")
  spec.eq(types[1], "agent_start")
  spec.eq(types[#types], "agent_end")
end)

spec.test("bad arguments, unknown tools and raising tools come back as errors the model reads", function()
  local boom = { name = "boom", description = "", execute = function() error("it broke", 0) end }
  local fn = scripted({ { call("a", "add", { a = 1 }), call("b", "nope", {}), call("c", "boom", {}) }, { text("ok") } })
  local new = loop.run({ { role = "user", content = "go" } }, { messages = {}, tools = { add, boom } },
    { model = model, stream_fn = fn })
  spec.ok(new[3].isError and new[3].content[1].text:find("is required", 1, true))
  spec.ok(new[4].isError and new[4].content[1].text:find("not found", 1, true))
  spec.ok(new[5].isError and new[5].content[1].text == "it broke")
end)

spec.test("before_tool_call blocks a call and after_tool_call rewrites a result", function()
  local fn = scripted({ { call("a", "add", { a = 1, b = 1 }), call("b", "add", { a = 2, b = 2 }) }, { text("ok") } })
  local new = loop.run({ { role = "user", content = "go" } }, { messages = {}, tools = { add } }, {
    model = model, stream_fn = fn,
    before_tool_call = function(c) if c.args.a == 2 then return { block = true, reason = "no twos" } end end,
    after_tool_call = function(c) return { content = "sum " .. c.result.content[1].text } end })
  spec.eq(new[3].content[1].text, "sum 2")
  spec.eq(new[4].content[1].text, "no twos")
  spec.eq(new[4].isError, true)
end)

spec.test("tools with start and finish run as one wave, results in call order", function()
  local order = {}
  local wave = { name = "w", description = "",
    start = function(id) order[#order + 1] = "start " .. id return id end,
    finish = function(h) order[#order + 1] = "finish " .. h return { content = h } end }
  local fn = scripted({ { call("x", "w", {}), call("y", "w", {}) }, { text("ok") } })
  local new = loop.run({ { role = "user", content = "go" } }, { messages = {}, tools = { wave } },
    { model = model, stream_fn = fn })
  spec.eq(table.concat(order, ","), "start x,start y,finish x,finish y")
  spec.eq(new[3].content[1].text, "x")
  spec.eq(new[4].content[1].text, "y")
end)

spec.test("a turn whose tools all say terminate ends the run", function()
  local stop = { name = "stop", description = "", execute = function() return { content = "bye", terminate = true } end }
  local fn, seen = scripted({ { call("s", "stop", {}) }, { text("never") } })
  loop.run({ { role = "user", content = "go" } }, { messages = {}, tools = { stop } }, { model = model, stream_fn = fn })
  spec.eq(#seen, 1)
end)

spec.test("the Agent keeps the conversation, hears steering before the next answer and follow-ups at the end", function()
  local a
  local fn, seen = scripted({ { call("c", "add", { a = 1, b = 1 }) }, { text("two") }, { text("later") } })
  a = agent.new({ model = model, stream_fn = fn, tools = { add }, systemPrompt = "sys" })
  local ends = 0
  a:subscribe(function(e)
    if e.type == "tool_execution_end" then a:steer(a:user("also, hurry")) a:follow_up(a:user("and then?")) end
    if e.type == "agent_end" then ends = ends + 1 end
  end)
  a:prompt("1+1?")
  local roles = {}
  for _, m in ipairs(a.state.messages) do roles[#roles + 1] = m.role end
  spec.eq(table.concat(roles, " "), "user assistant toolResult user assistant user assistant")
  spec.eq(a.state.messages[4].content[1].text, "also, hurry")
  spec.eq(seen[2].systemPrompt, "sys")
  spec.eq(a.state.isStreaming, false)
  spec.eq(ends, 1)
  spec.err(function() a:continue() end, "assistant")
end)

spec.test("a failed model call is the run's last message and the error is kept", function()
  local a = agent.new({ model = model, stream_fn = function(_, m, _, _, on_event)
    local b = message.builder(m, on_event)
    b:start()
    return b:fail("no route")
  end })
  a:prompt("hi")
  spec.eq(a.state.messages[2].stopReason, "error")
  spec.eq(a.state.errorMessage, "no route")
end)

spec.test("abort from a tool stops the run after that turn", function()
  local a
  local halt = { name = "halt", description = "", execute = function() a:abort() return { content = "stopping" } end }
  local fn, seen = scripted({ { call("h", "halt", {}) }, { text("never") } })
  a = agent.new({ model = model, stream_fn = fn, tools = { halt } })
  a:prompt("go")
  spec.eq(#seen, 1)
  spec.eq(a.run, nil)
end)

-- (a VM without coroutines, as Moss's moss-lua is, runs the loop to its end in one call: there is no yield to test)
if coroutine then spec.test("a tool may yield to its host when the loop runs in a coroutine", function()
  local slow = { name = "slow", description = "", execute = function() return { content = coroutine.yield("waiting") } end }
  local fn = scripted({ { call("s", "slow", {}) }, { text("got it") } })
  local a = agent.new({ model = model, stream_fn = fn, tools = { slow } })
  local co = coroutine.create(function() a:prompt("go") end)
  local _, why = coroutine.resume(co)
  spec.eq(why, "waiting")
  spec.eq(a.state.isStreaming, true)
  coroutine.resume(co, "done waiting")
  spec.eq(coroutine.status(co), "dead")
  spec.eq(a.state.messages[3].content[1].text, "done waiting")
end) end

spec.run()
