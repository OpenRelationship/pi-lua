-- The OpenAI chat-completions API ("openai-completions"), streamed: OpenAI itself and every route that speaks it
-- (OpenRouter, Cerebras, Groq, Inception, a local llama.cpp or vLLM server). pi-ai's model fields it reads:
--
--   model = { id, provider, api = "openai-completions", baseUrl, maxTokens?, reasoning? (bool), headers?,
--             compat? = { reasoning = "effort" | "openrouter" | "none", maxTokensField = "max_tokens" |
--                         "max_completion_tokens", developerRole? }, cost? }
local http = require("pi.ai.http")
local sse = require("pi.ai.sse")
local json = require("pi.json")
local message = require("pi.ai.message")

local M = {}

local function text_of(content)
  if type(content) == "string" then return content end
  local out = {}
  for _, b in ipairs(content or {}) do
    if b.type == "text" then out[#out + 1] = b.text end
  end
  return table.concat(out, "\n")
end

local function user_content(content)
  if type(content) == "string" then return content end
  local parts, images = {}, false
  for _, b in ipairs(content) do
    if b.type == "text" then
      parts[#parts + 1] = { type = "text", text = b.text }
    elseif b.type == "image" then
      images = true
      parts[#parts + 1] = { type = "image_url", image_url = { url = "data:" .. b.mimeType .. ";base64," .. b.data } }
    end
  end
  if not images then return text_of(content) end
  return parts
end

-- pi's messages in the API's shape: thinking is not sent back, a tool call keeps its id
function M.messages(model, context)
  local out = {}
  local compat = model.compat or {}
  if context.systemPrompt and context.systemPrompt ~= "" then
    local role = (compat.developerRole and model.reasoning) and "developer" or "system"
    out[#out + 1] = { role = role, content = context.systemPrompt }
  end
  for _, m in ipairs(context.messages or {}) do
    if m.role == "user" then
      out[#out + 1] = { role = "user", content = user_content(m.content) }
    elseif m.role == "assistant" then
      local text, calls = {}, {}
      for _, b in ipairs(m.content) do
        if b.type == "text" then text[#text + 1] = b.text
        elseif b.type == "toolCall" then
          calls[#calls + 1] = { id = b.id, type = "function",
            ["function"] = { name = b.name, arguments = json.encode(b.arguments or {}) } }
        end
      end
      local a = { role = "assistant", content = #text > 0 and table.concat(text, "") or json.null }
      if #calls > 0 then a.tool_calls = calls end
      if #text > 0 or #calls > 0 then out[#out + 1] = a end
    elseif m.role == "toolResult" then
      local t = text_of(m.content)
      out[#out + 1] = { role = "tool", tool_call_id = m.toolCallId, content = t ~= "" and t or "(no output)" }
    end
  end
  return out
end

function M.tools(tools)
  local out = {}
  for _, t in ipairs(tools or {}) do
    out[#out + 1] = { type = "function",
      ["function"] = { name = t.name, description = t.description, parameters = t.parameters } }
  end
  return out
end

function M.payload(model, context, options)
  options = options or {}
  local compat = model.compat or {}
  local p = { model = model.id, messages = M.messages(model, context), stream = true,
    stream_options = { include_usage = true } }
  local max = options.maxTokens or model.maxTokens
  if max then p[compat.maxTokensField or "max_tokens"] = max end
  if options.temperature then p.temperature = options.temperature end
  if context.tools and #context.tools > 0 then p.tools = M.tools(context.tools) end
  if model.reasoning and options.reasoning and compat.reasoning ~= "none" then
    if compat.reasoning == "openrouter" then p.reasoning = { effort = options.reasoning }
    else p.reasoning_effort = options.reasoning end
  end
  for k, v in pairs(model.body or {}) do p[k] = v end
  return p
end

local stops = { stop = "stop", length = "length", tool_calls = "toolUse", function_call = "toolUse",
  content_filter = "error" }

local function usage_of(u)
  local cached = type(u.prompt_tokens_details) == "table" and u.prompt_tokens_details.cached_tokens or 0
  return { input = (u.prompt_tokens or 0) - cached, output = u.completion_tokens or 0, cacheRead = cached,
    billed = tonumber(u.cost) }
end

-- Stream one reply: on_event hears pi-ai's events; the final message is returned (never raised: a failure is a
-- message with stopReason "error" and its errorMessage).
function M.stream(host, model, context, options, on_event)
  options = options or {}
  local b = message.builder(model, on_event)
  local reason, failed = "stop", nil
  local reader = sse.reader(function(_, data)
    if data == "[DONE]" then return end
    local ok, ev = pcall(json.decode, data)
    if not ok or type(ev) ~= "table" then return end
    if type(ev.usage) == "table" then b:usage(usage_of(ev.usage)) end
    if type(ev.error) == "table" then failed = ev.error.message or json.encode(ev.error) return end
    local c = type(ev.choices) == "table" and ev.choices[1]
    if not c then return end
    local d = type(c.delta) == "table" and c.delta or {}
    local think = d.reasoning_content or d.reasoning
    if type(think) == "string" and think ~= "" then b:thinking("thinking", think) end
    if type(d.content) == "string" and d.content ~= "" then b:text("text", d.content) end
    for _, tc in ipairs(type(d.tool_calls) == "table" and d.tool_calls or {}) do
      local f = type(tc["function"]) == "table" and tc["function"] or {}
      b:tool("tool" .. tostring(tc.index or 0), tc.id, f.name, f.arguments)
    end
    if type(c.finish_reason) == "string" then reason = stops[c.finish_reason] or "stop" end
  end)
  b:start()
  local headers = { Authorization = "Bearer " .. tostring(options.apiKey or "") }
  for k, v in pairs(model.headers or {}) do headers[k] = v end
  local signal = options.signal
  local fed = false
  local ok, body = pcall(http.post, host, model.provider, model.baseUrl .. "/chat/completions", headers,
    M.payload(model, context, options), { on_data = function(chunk) fed = true; reader:feed(chunk) end,
      timeout = options.timeout, aborted = signal and function() return signal.aborted end })
  if ok and not fed then reader:feed(body) end   -- a host whose fetch does not stream hands the body over whole
  if ok then reader:finish() end
  if signal and signal.aborted then return b:fail("Request was aborted", true) end
  if not ok then return b:fail(body) end
  if failed then return b:fail(failed) end
  return b:done(reason)
end

return M
