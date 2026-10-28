-- The Anthropic Messages API ("anthropic-messages"), streamed. The system prompt and the last user turn carry an
-- ephemeral cache mark, so a conversation's stable start is read from the prompt cache on the next turn.
--
--   model = { id, provider, api = "anthropic-messages", baseUrl, maxTokens?, reasoning? (bool), headers?, cost? }
local http = require("pi.ai.http")
local sse = require("pi.ai.sse")
local json = require("pi.json")
local message = require("pi.ai.message")

local M = {}

local budgets = { minimal = 1024, low = 2048, medium = 8192, high = 16384, xhigh = 32000 }
local cache = { type = "ephemeral" }

local function blocks(content)
  if type(content) == "string" then return { { type = "text", text = content } } end
  local out = {}
  for _, b in ipairs(content or {}) do
    if b.type == "text" and b.text ~= "" then
      out[#out + 1] = { type = "text", text = b.text }
    elseif b.type == "image" then
      out[#out + 1] = { type = "image", source = { type = "base64", media_type = b.mimeType, data = b.data } }
    end
  end
  return out
end

local function assistant(m)
  local out = {}
  for _, b in ipairs(m.content) do
    if b.type == "text" and b.text ~= "" then
      out[#out + 1] = { type = "text", text = b.text }
    elseif b.type == "thinking" and b.signature and b.signature ~= "" then
      out[#out + 1] = { type = "thinking", thinking = b.thinking, signature = b.signature }
    elseif b.type == "toolCall" then
      out[#out + 1] = { type = "tool_use", id = b.id, name = b.name, input = b.arguments or {} }
    end
  end
  return out
end

-- pi's messages in the API's shape: tool results become one user turn of tool_result blocks
function M.messages(context)
  local out = {}
  for _, m in ipairs(context.messages or {}) do
    if m.role == "user" then
      local c = blocks(m.content)
      if #c > 0 then out[#out + 1] = { role = "user", content = c } end
    elseif m.role == "assistant" then
      local c = assistant(m)
      if #c > 0 then out[#out + 1] = { role = "assistant", content = c } end
    elseif m.role == "toolResult" then
      local r = { type = "tool_result", tool_use_id = m.toolCallId, content = blocks(m.content), is_error = m.isError }
      if #r.content == 0 then r.content = { { type = "text", text = "(no output)" } } end
      local last = out[#out]
      if last and last.role == "user" and last.content[1] and last.content[1].type == "tool_result" then
        last.content[#last.content + 1] = r
      else
        out[#out + 1] = { role = "user", content = { r } }
      end
    end
  end
  -- the cache mark on the last block of the last user turn
  for i = #out, 1, -1 do
    if out[i].role == "user" then
      local c = out[i].content
      c[#c].cache_control = cache
      break
    end
  end
  return out
end

function M.payload(model, context, options)
  options = options or {}
  local max = options.maxTokens or model.maxTokens or 8192
  local p = { model = model.id, messages = M.messages(context), stream = true, max_tokens = max }
  if context.systemPrompt and context.systemPrompt ~= "" then
    p.system = { { type = "text", text = context.systemPrompt, cache_control = cache } }
  end
  if context.tools and #context.tools > 0 then
    p.tools = {}
    for _, t in ipairs(context.tools) do
      p.tools[#p.tools + 1] = { name = t.name, description = t.description, input_schema = t.parameters }
    end
  end
  if model.reasoning and options.reasoning and budgets[options.reasoning] then
    local budget = budgets[options.reasoning]
    if max <= budget then p.max_tokens = budget + 4096 end
    p.thinking = { type = "enabled", budget_tokens = budget }
  elseif options.temperature then
    p.temperature = options.temperature
  end
  for k, v in pairs(model.body or {}) do p[k] = v end
  return p
end

local stops = { end_turn = "stop", max_tokens = "length", tool_use = "toolUse", stop_sequence = "stop",
  pause_turn = "stop", refusal = "error" }

-- Stream one reply: on_event hears pi-ai's events; the final message is returned (a failure is a message with
-- stopReason "error" and its errorMessage, never raised).
function M.stream(host, model, context, options, on_event)
  options = options or {}
  local b = message.builder(model, on_event)
  local reason, failed = "stop", nil
  local reader = sse.reader(function(_, data)
    local ok, ev = pcall(json.decode, data)
    if not ok or type(ev) ~= "table" then return end
    local t = ev.type
    if t == "message_start" and type(ev.message) == "table" and type(ev.message.usage) == "table" then
      local u = ev.message.usage
      b:usage({ input = u.input_tokens, output = u.output_tokens, cacheRead = u.cache_read_input_tokens,
        cacheWrite = u.cache_creation_input_tokens })
    elseif t == "content_block_start" then
      local cb = ev.content_block or {}
      if cb.type == "text" then b:text(ev.index, cb.text)
      elseif cb.type == "thinking" then b:thinking(ev.index, cb.thinking)
      elseif cb.type == "tool_use" then b:tool(ev.index, cb.id, cb.name) end
    elseif t == "content_block_delta" then
      local d = ev.delta or {}
      if d.type == "text_delta" then b:text(ev.index, d.text)
      elseif d.type == "thinking_delta" then b:thinking(ev.index, d.thinking)
      elseif d.type == "signature_delta" then b:thinking(ev.index, nil, d.signature)
      elseif d.type == "input_json_delta" then b:tool(ev.index, nil, nil, d.partial_json) end
    elseif t == "content_block_stop" then
      b:close(ev.index)
    elseif t == "message_delta" then
      if type(ev.delta) == "table" and ev.delta.stop_reason then reason = stops[ev.delta.stop_reason] or "stop" end
      if type(ev.usage) == "table" then b:usage({ output = ev.usage.output_tokens }) end
    elseif t == "error" then
      failed = type(ev.error) == "table" and ev.error.message or "the stream ended in an error"
    end
  end)
  b:start()
  local headers = { ["x-api-key"] = tostring(options.apiKey or ""), ["anthropic-version"] = "2023-06-01" }
  for k, v in pairs(model.headers or {}) do headers[k] = v end
  local signal, fed = options.signal, false
  local ok, body = pcall(http.post, host, model.provider, model.baseUrl .. "/v1/messages", headers,
    M.payload(model, context, options), { on_data = function(chunk) fed = true; reader:feed(chunk) end,
      timeout = options.timeout, aborted = signal and function() return signal.aborted end })
  if ok and not fed then reader:feed(body) end
  if ok then reader:finish() end
  if signal and signal.aborted then return b:fail("Request was aborted", true) end
  if not ok then return b:fail(body) end
  if failed then return b:fail(failed) end
  if reason == "error" then return b:fail("the model refused") end
  return b:done(reason)
end

return M
