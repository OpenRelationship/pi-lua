-- pi.session with its store, extensions and compaction, against a scripted model.
local spec = require("mono.spec")
local session = require("pi.session")
local store = require("pi.store")
local compaction = require("pi.compaction")
local message = require("pi.ai.message")
local json = require("pi.json")

local model = { id = "m", provider = "test", api = "test", contextWindow = 1000 }

local function scripted(replies, seen)
  return function(_, m, context, _, on_event)
    if seen then seen[#seen + 1] = context end
    local r = table.remove(replies, 1) or { { type = "text", text = "(none)" } }
    if type(r) == "function" then r = r(context) end
    local b = message.builder(m, on_event)
    b:start()
    for i, blk in ipairs(r) do
      if blk.type == "text" then b:text(i, blk.text)
      else b:tool(i, blk.id, blk.name, json.encode(blk.arguments or {})) end
    end
    if r.usage then b:usage(r.usage) end
    return b:done("stop")
  end
end

local function counter()
  local n = 0
  return function() n = n + 1 return ("e%03d"):format(n) end
end

local function lines_store()
  local lines = {}
  return store.open({ write = function(l) lines[#lines + 1] = l end, id = counter(), now = function() return 1 end }),
    lines
end

spec.test("every message is written as it ends, and a reopened store resumes the conversation", function()
  local s, lines = lines_store()
  local sess = session.new({ model = model, store = s, stream_fn = scripted({ { { type = "text", text = "hi there" } } }) })
  sess:prompt("hello")
  spec.eq(#lines, 3)
  spec.eq(json.decode(lines[1]).type, "session")
  spec.eq(json.decode(lines[3]).parentId, json.decode(lines[2]).id)
  local again = session.new({ model = model, store = store.open({ lines = lines }), stream_fn = scripted({}) })
  spec.eq(#again.agent.state.messages, 2)
  spec.eq(again.agent.state.messages[2].content[1].text, "hi there")
end)

spec.test("an extension's tool runs with the extension context, and tool_call can block it", function()
  local ran = {}
  local ext = function(pi)
    pi.register_tool({ name = "note", description = "", parameters = { type = "object" },
      execute = function(_, args, _, _, ctx) ran[#ran + 1] = args.text .. "@" .. ctx.model.id return { content = "kept" } end })
    pi.on("tool_call", function(e) if e.input.text == "secret" then return { block = true, reason = "not that" } end end)
    pi.on("tool_result", function(e) return { content = { { type = "text", text = e.content[1].text .. "!" } } } end)
  end
  local sess = session.new({ model = model, extensions = { ext }, stream_fn = scripted({
    { { type = "toolCall", id = "a", name = "note", arguments = { text = "milk" } },
      { type = "toolCall", id = "b", name = "note", arguments = { text = "secret" } } },
    { { type = "text", text = "ok" } } }) })
  sess:prompt("remember")
  local m = sess.agent.state.messages
  spec.eq(ran[1], "milk@m")
  spec.eq(#ran, 1)
  spec.eq(m[3].content[1].text, "kept!")
  spec.eq(m[4].content[1].text, "not that")   -- a blocked call never ran, so tool_result does not hear it (as in pi)
  spec.eq(m[4].isError, true)
end)

spec.test("before_agent_start changes the system prompt for the turn and adds a message the model reads", function()
  local seen = {}
  local ext = function(pi)
    pi.on("before_agent_start", function(e)
      return { systemPrompt = e.systemPrompt .. " Be kind.", message = { customType = "memory", content = "likes tea" } }
    end)
  end
  local sess = session.new({ model = model, systemPrompt = "You help.", extensions = { ext },
    stream_fn = scripted({ { { type = "text", text = "tea?" } } }, seen) })
  sess:prompt("hi")
  spec.eq(seen[1].systemPrompt, "You help. Be kind.")
  spec.eq(seen[1].messages[2].role, "user")
  spec.eq(seen[1].messages[2].content[1].text, "likes tea")
  spec.eq(sess.agent.state.systemPrompt, "You help.")
  spec.eq(sess.agent.state.messages[2].role, "custom")
end)

spec.test("input can transform or handle a prompt, and /commands run without the model", function()
  local seen, got = {}, nil
  local ext = function(pi)
    pi.on("input", function(e)
      if e.text == "skip" then return "handled" end
      return { action = "transform", text = e.text:upper() }
    end)
    pi.register_command("name", { description = "", handler = function(args, ctx) got = args; pi.set_session_name(args) end })
  end
  local sess = session.new({ model = model, extensions = { ext }, stream_fn = scripted({ { { type = "text", text = "ok" } } }, seen) })
  sess:prompt("skip")
  sess:prompt("/name Groceries")
  spec.eq(#seen, 0)
  spec.eq(sess.store:name(), "Groceries")
  sess:prompt("hey")
  spec.eq(seen[1].messages[1].content[1].text, "HEY")
end)

spec.test("context changes what the model sees, not what the session keeps", function()
  local seen = {}
  local ext = function(pi)
    pi.on("context", function(e) return { messages = { e.messages[#e.messages] } } end)
  end
  local sess = session.new({ model = model, extensions = { ext }, stream_fn = scripted({
    { { type = "text", text = "one" } }, { { type = "text", text = "two" } } }, seen) })
  sess:prompt("a")
  sess:prompt("b")
  spec.eq(#seen[2].messages, 1)
  spec.eq(#sess.agent.state.messages, 4)
end)

spec.test("set_active_tools narrows the tools the model is offered", function()
  local seen = {}
  local t = function(n) return { name = n, description = "", execute = function() return { content = n } end } end
  local sess = session.new({ model = model, tools = { t("a"), t("b") }, stream_fn = scripted({}, seen) })
  sess:set_active_tools({ "b" })
  sess:prompt("x")
  spec.eq(#seen[1].tools, 1)
  spec.eq(seen[1].tools[1].name, "b")
end)

spec.test("the cut keeps the newest messages and never starts on a tool result", function()
  local s = store.open({ id = counter() })
  local big = string.rep("x", 400)
  s:append_message({ role = "user", content = big })
  s:append_message({ role = "assistant", content = { { type = "toolCall", id = "c", name = "t", arguments = {} } } })
  s:append_message({ role = "toolResult", toolCallId = "c", content = { { type = "text", text = big } } })
  s:append_message({ role = "assistant", content = { { type = "text", text = big } } })
  s:append_message({ role = "user", content = big })
  s:append_message({ role = "assistant", content = { { type = "text", text = big } } })
  local prep = compaction.prepare(s:path(), { enabled = true, reserveTokens = 10, keepRecentTokens = 150 })
  spec.eq(prep.firstKeptEntryId, s:path()[5].id)
  spec.eq(#prep.summarize, 4)
end)

spec.test("compaction summarises the old part and the agent resumes from summary plus what was kept", function()
  local seen = {}
  local big = string.rep("y", 2000)
  local sess = session.new({ model = model, compaction = { enabled = true, reserveTokens = 100, keepRecentTokens = 400 },
    stream_fn = scripted({ { { type = "text", text = big } }, { { type = "text", text = big } },
      { { type = "text", text = "## Goal\nchat" } }, { { type = "text", text = "after" } } }, seen) })
  sess:prompt("first")
  sess:prompt("second")   -- the context is now past 1000 - 100 tokens: compaction runs after this turn
  spec.eq(seen[3].systemPrompt, compaction.SYSTEM)
  local m = sess.agent.state.messages
  spec.eq(m[1].role, "compactionSummary")
  spec.eq(m[1].summary, "## Goal\nchat")
  sess:prompt("third")
  spec.ok(seen[4].messages[1].content[1].text:find("<summary>", 1, true))
  local resumed = store.open({ lines = (function()
    local out = { json.encode(sess.store.header) }
    for _, e in ipairs(sess.store:entries()) do out[#out + 1] = json.encode(e) end
    return out
  end)() }):context()
  spec.eq(resumed.messages[1].role, "compactionSummary")
end)

spec.test("an extension that raises is reported and the session goes on", function()
  local errs = {}
  local ext = function(pi) pi.on("turn_end", function() error("oops", 0) end) end
  local sess = session.new({ model = model, extensions = { ext }, on_error = function(e) errs[#errs + 1] = e end,
    stream_fn = scripted({ { { type = "text", text = "fine" } } }) })
  sess:prompt("go")
  spec.eq(errs[1].event, "turn_end")
  spec.eq(errs[1].error, "oops")
  spec.eq(sess.agent.state.messages[2].content[1].text, "fine")
end)

spec.test("send_message with nextTurn rides along with the next prompt", function()
  local seen = {}
  local ext
  ext = function(pi) pi.on("session_start", function() pi.send_message({ customType = "hint", content = "be short" },
    { deliverAs = "nextTurn" }) end) end
  local sess = session.new({ model = model, extensions = { ext }, stream_fn = scripted({}, seen) })
  sess:prompt("hi")
  spec.eq(seen[1].messages[2].content[1].text, "be short")
end)

spec.test("reset_leaf starts a new root, so the conversation reads as empty", function()
  local s = store.open({ id = counter() })
  s:append_message({ role = "user", content = "a" })
  s:reset_leaf()
  spec.eq(#s:context().messages, 0)
  s:append_message({ role = "user", content = "b" })
  spec.eq(#s:context().messages, 1)
  spec.eq(s:context().messages[1].content, "b")
end)

spec.run()
