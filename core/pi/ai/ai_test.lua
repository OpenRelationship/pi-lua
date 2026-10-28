-- pi.ai against a fake host: SSE bodies in the shapes OpenAI-style routes and Anthropic send, cut at awkward points.
local spec = require("mono.spec")
local ai = require("pi.ai")
local json = require("pi.json")
local sse = require("pi.ai.sse")
local validate = require("pi.ai.validate")

-- a host whose fetch hands the body over in chunks of n bytes, and remembers the request
local function host(status, body, n)
  local h = {}
  h.fetch = function(req)
    h.req = req
    if req.on_data and n then
      for i = 1, #body, n do req.on_data(body:sub(i, i + n - 1)) end
    end
    return { status = status, body = body }
  end
  return h
end

local function events(lines)
  local out = {}
  for _, l in ipairs(lines) do out[#out + 1] = "data: " .. json.encode(l) .. "\n\n" end
  return table.concat(out) .. "data: [DONE]\n\n"
end

local oa = ai.model{ id = "m", provider = "test", api = "openai-completions", baseUrl = "http://x/v1",
  cost = { input = 1, output = 2 } }

spec.test("the SSE reader joins data lines and survives any cut", function()
  local got = {}
  local r = sse.reader(function(e, d) got[#got + 1] = e .. "=" .. d end)
  local text = "event: a\ndata: 1\ndata: 2\n\n: comment\ndata: 3\n\ndata: tail"
  for i = 1, #text do r:feed(text:sub(i, i)) end
  r:finish()
  spec.eq(table.concat(got, ","), "a=1\n2,message=3,message=tail")
end)

spec.test("an OpenAI-style stream gives text, a tool call, usage and toolUse", function()
  local body = events({
    { choices = { { delta = { content = "Hel" } } } },
    { choices = { { delta = { content = "lo" } } } },
    { choices = { { delta = { tool_calls = { { index = 0, id = "c1", ["function"] = { name = "add", arguments = '{"a":' } } } } } } },
    { choices = { { delta = { tool_calls = { { index = 0, ["function"] = { arguments = "2}" } } } }, finish_reason = "tool_calls" } } },
    { choices = {}, usage = { prompt_tokens = 10, completion_tokens = 4, prompt_tokens_details = { cached_tokens = 3 } } },
  })
  local h, seen = host(200, body, 7), {}
  local msg = ai.stream(h, oa, { systemPrompt = "be brief", messages = { { role = "user", content = "hi" } },
    tools = { { name = "add", description = "adds", parameters = { type = "object" } } } }, { apiKey = "k" },
    function(e) seen[#seen + 1] = e.type end)
  spec.eq(msg.stopReason, "toolUse")
  spec.eq(msg.content[1].text, "Hello")
  spec.eq(msg.content[2].name, "add")
  spec.eq(msg.content[2].arguments.a, 2)
  spec.eq(msg.usage.input, 7)
  spec.eq(msg.usage.cacheRead, 3)
  spec.eq(msg.usage.output, 4)
  spec.eq(seen[1], "start")
  spec.eq(seen[#seen], "done")
  spec.eq(h.req.headers.Authorization, "Bearer k")
  local sent = json.decode(h.req.body)
  spec.eq(sent.messages[1].role, "system")
  spec.eq(sent.tools[1]["function"].name, "add")
end)

spec.test("a host that does not stream still gets the whole reply", function()
  local msg = ai.stream(host(200, events({ { choices = { { delta = { content = "ok" }, finish_reason = "stop" } } } })),
    oa, { messages = {} }, {})
  spec.eq(ai.text(msg), "ok")
  spec.eq(msg.stopReason, "stop")
end)

spec.test("a refused call comes back as an error message, not a raise", function()
  local msg = ai.stream(host(401, '{"error":{"message":"bad key"}}'), oa, { messages = {} }, {})
  spec.eq(msg.stopReason, "error")
  spec.ok(msg.errorMessage:find("bad key", 1, true))
end)

spec.test("assistant tool calls and tool results go back in the OpenAI shape", function()
  local h = host(200, events({ { choices = { { delta = { content = "done" }, finish_reason = "stop" } } } }))
  ai.stream(h, oa, { messages = {
    { role = "user", content = { { type = "text", text = "add" } } },
    { role = "assistant", content = { { type = "thinking", thinking = "hm" },
      { type = "toolCall", id = "c1", name = "add", arguments = { a = 1 } } } },
    { role = "toolResult", toolCallId = "c1", toolName = "add", content = { { type = "text", text = "1" } } },
  } }, {})
  local sent = json.decode(h.req.body).messages
  spec.eq(sent[2].tool_calls[1].id, "c1")
  spec.eq(sent[2].tool_calls[1]["function"].arguments, '{"a":1}')
  spec.eq(sent[3].role, "tool")
  spec.eq(sent[3].content, "1")
end)

local an = ai.model{ id = "claude", provider = "anthropic", api = "anthropic-messages", baseUrl = "http://a",
  reasoning = true }

spec.test("an Anthropic stream gives thinking with its signature, text and a tool call", function()
  local lines = {
    { type = "message_start", message = { usage = { input_tokens = 5, cache_read_input_tokens = 2 } } },
    { type = "content_block_start", index = 0, content_block = { type = "thinking", thinking = "" } },
    { type = "content_block_delta", index = 0, delta = { type = "thinking_delta", thinking = "let me" } },
    { type = "content_block_delta", index = 0, delta = { type = "signature_delta", signature = "sig" } },
    { type = "content_block_stop", index = 0 },
    { type = "content_block_start", index = 1, content_block = { type = "text", text = "" } },
    { type = "content_block_delta", index = 1, delta = { type = "text_delta", text = "Sure" } },
    { type = "content_block_stop", index = 1 },
    { type = "content_block_start", index = 2, content_block = { type = "tool_use", id = "t1", name = "add" } },
    { type = "content_block_delta", index = 2, delta = { type = "input_json_delta", partial_json = '{"a":' } },
    { type = "content_block_delta", index = 2, delta = { type = "input_json_delta", partial_json = "3}" } },
    { type = "content_block_stop", index = 2 },
    { type = "message_delta", delta = { stop_reason = "tool_use" }, usage = { output_tokens = 9 } },
  }
  local out = {}
  for _, l in ipairs(lines) do out[#out + 1] = "event: " .. l.type .. "\ndata: " .. json.encode(l) .. "\n\n" end
  local h = host(200, table.concat(out), 11)
  local msg = ai.stream(h, an, { systemPrompt = "s", messages = { { role = "user", content = "hi" } } },
    { apiKey = "k", reasoning = "low", maxTokens = 1000 })
  spec.eq(msg.stopReason, "toolUse")
  spec.eq(msg.content[1].thinking, "let me")
  spec.eq(msg.content[1].signature, "sig")
  spec.eq(msg.content[2].text, "Sure")
  spec.eq(msg.content[3].arguments.a, 3)
  spec.eq(msg.usage.input, 5)
  spec.eq(msg.usage.cacheRead, 2)
  spec.eq(msg.usage.output, 9)
  local sent = json.decode(h.req.body)
  spec.eq(h.req.headers["x-api-key"], "k")
  spec.eq(sent.thinking.budget_tokens, 2048)
  spec.ok(sent.max_tokens > 2048)
  spec.eq(sent.system[1].cache_control.type, "ephemeral")
  spec.eq(sent.messages[1].content[1].cache_control.type, "ephemeral")
end)

spec.test("consecutive tool results become one Anthropic user turn", function()
  local m = require("pi.ai.anthropic").messages({ messages = {
    { role = "assistant", content = { { type = "toolCall", id = "a", name = "x", arguments = {} },
      { type = "toolCall", id = "b", name = "x", arguments = {} } } },
    { role = "toolResult", toolCallId = "a", content = { { type = "text", text = "1" } } },
    { role = "toolResult", toolCallId = "b", content = {}, isError = true },
  } })
  spec.eq(#m, 2)
  spec.eq(#m[2].content, 2)
  spec.eq(m[2].content[2].is_error, true)
  spec.eq(json.encode(m[1].content[1].input), "{}")
end)

spec.test("arguments are checked against the schema, coerced where models slip", function()
  local tool = { name = "move", parameters = { type = "object", required = { "x" }, additionalProperties = false,
    properties = { x = { type = "integer" }, dir = { type = "string", enum = { "up", "down" } } } } }
  spec.eq(validate.arguments(tool, { x = "4" }).x, 4)
  local ok, err = pcall(validate.arguments, tool, { dir = "up" })
  spec.eq(ok, false)
  spec.ok(err:find("root.x: is required", 1, true))
  ok, err = pcall(validate.arguments, tool, { x = 1, dir = "left" })
  spec.ok(err:find("must be one of", 1, true))
  ok, err = pcall(validate.arguments, tool, { x = 1, y = 2 })
  spec.ok(err:find("root.y: is not allowed", 1, true))
end)

spec.run()
