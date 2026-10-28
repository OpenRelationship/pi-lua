-- pi.ai: one call to any model, streamed, in pi-ai's shapes (message.lua). The providers are chosen by the model's
-- api; a host adds its own with ai.register(api, stream_fn).
--
--   local ai = require("pi.ai")
--   local model = ai.model{ id = "claude-sonnet-5-5", provider = "anthropic", api = "anthropic-messages",
--                           baseUrl = "https://api.anthropic.com", reasoning = true, maxTokens = 16384 }
--   ai.stream(host, model, { systemPrompt, messages, tools }, { apiKey, reasoning?, maxTokens?, temperature?,
--             signal? = { aborted = bool } }, on_event) -> assistant message
--   ai.complete(host, model, context, options) -> assistant message (no events)
--
-- host = { fetch, now?, sleep? } (pi.ai.http). Nothing here raises for a failed call: the message comes back with
-- stopReason "error" and errorMessage, as pi-ai's streams end.
local M = {}

local apis = {
  ["openai-completions"] = function(...) return require("pi.ai.openai").stream(...) end,
  ["anthropic-messages"] = function(...) return require("pi.ai.anthropic").stream(...) end,
}

local defaults = {
  ["openai-completions"] = "https://api.openai.com/v1",
  ["anthropic-messages"] = "https://api.anthropic.com",
}

function M.register(api, stream_fn) apis[api] = stream_fn end

function M.model(m)
  assert(type(m.id) == "string", "a model needs its id")
  m.api = m.api or "openai-completions"
  m.provider = m.provider or m.api
  m.baseUrl = m.baseUrl or defaults[m.api]
  assert(m.baseUrl, "a model of api " .. m.api .. " needs its baseUrl")
  return m
end

function M.stream(host, model, context, options, on_event)
  local fn = apis[model.api]
  if not fn then error("no provider for api " .. tostring(model.api), 0) end
  return fn(host, model, context, options or {}, on_event)
end

function M.complete(host, model, context, options)
  return M.stream(host, model, context, options, nil)
end

-- the text of an assistant message's text blocks
function M.text(msg)
  local out = {}
  for _, b in ipairs(msg.content or {}) do
    if b.type == "text" then out[#out + 1] = b.text end
  end
  return table.concat(out, "")
end

return M
