-- Compaction as pi does it: when the context nears the model's window, the older part of the conversation is
-- summarised by the model into a structured checkpoint, and the recent part is kept as it was.
--
--   compaction.settings = { enabled = true, reserveTokens = 16384, keepRecentTokens = 20000 }
--   compaction.estimate(message) -> tokens (characters / 4, as pi estimates)
--   compaction.context_tokens(messages) -> tokens: the last assistant reply's usage plus estimates after it
--   compaction.should(tokens, window, settings?) -> bool
--   compaction.prepare(path_entries, settings?) -> { summarize = messages, firstKeptEntryId, tokensBefore,
--                                                    previous = summary? } | nil (nothing to cut)
--   compaction.summarize(host, model, prep, options) -> summary text | nil, error
local ai = require("pi.ai")
local json = require("pi.json")
local messages = require("pi.messages")

local M = {}

M.settings = { enabled = true, reserveTokens = 16384, keepRecentTokens = 20000 }

M.SYSTEM = "You are a context summarization assistant. Your task is to read a conversation between a user and an AI "
  .. "assistant, then produce a structured summary following the exact format specified.\n\nDo NOT continue the "
  .. "conversation. Do NOT respond to any questions in the conversation. ONLY output the structured summary."

local FORMAT = [[

Use this EXACT format:

## Goal
[What is the user trying to accomplish? Can be multiple items if the session covers different tasks.]

## Constraints & Preferences
- [Any constraints, preferences, or requirements mentioned by user]
- [Or "(none)" if none were mentioned]

## Progress
### Done
- [x] [Completed tasks/changes]

### In Progress
- [ ] [Current work]

### Blocked
- [Issues preventing progress, if any]

## Key Decisions
- **[Decision]**: [Brief rationale]

## Next Steps
1. [Ordered list of what should happen next]

## Critical Context
- [Any data, examples, or references needed to continue]
- [Or "(none)" if not applicable]

Keep each section concise. Preserve exact names, numbers, and error messages.]]

M.PROMPT = "The messages above are a conversation to summarize. Create a structured context checkpoint summary that "
  .. "another LLM will use to continue the work." .. FORMAT
M.UPDATE = "The messages above are NEW conversation messages to incorporate into the existing summary provided in "
  .. "<previous-summary> tags.\n\nUpdate the existing structured summary with new information: PRESERVE all existing "
  .. "information, ADD new progress, decisions and context, move items from \"In Progress\" to \"Done\" when "
  .. "completed, and update \"Next Steps\". If something is no longer relevant, you may remove it." .. FORMAT

local function size(m)
  local n = 0
  if type(m.content) == "string" then return #m.content end
  for _, b in ipairs(m.content or {}) do
    if b.type == "text" then n = n + #b.text
    elseif b.type == "thinking" then n = n + #b.thinking
    elseif b.type == "toolCall" then n = n + #b.name + #json.encode(b.arguments or {})
    elseif b.type == "image" then n = n + 4800 end
  end
  if m.summary then n = n + #m.summary end
  return n
end

function M.estimate(m) return math.ceil(size(m) / 4) end

function M.context_tokens(list)
  local total, from = 0, 1
  for i = #list, 1, -1 do
    local m = list[i]
    if m.role == "assistant" and m.usage and m.usage.totalTokens and m.usage.totalTokens > 0
      and m.stopReason ~= "error" and m.stopReason ~= "aborted" then
      total, from = m.usage.totalTokens, i + 1
      break
    end
  end
  for i = from, #list do total = total + M.estimate(list[i]) end
  return total
end

function M.should(tokens, window, settings)
  settings = settings or M.settings
  if not settings.enabled or not window then return false end
  return tokens > window - settings.reserveTokens
end

local function message_of(e)
  if e.type == "message" then return e.message end
  if e.type == "custom_message" then return { role = "custom", content = e.content } end
end

-- where to cut: a user, assistant or custom message (never a tool result, which needs its call before it), as late
-- as keeps keepRecentTokens of the newest messages
function M.prepare(path, settings)
  settings = settings or M.settings
  local start, previous = 1, nil
  for i = #path, 1, -1 do
    if path[i].type == "compaction" then
      previous = path[i].summary
      for j = 1, i - 1 do if path[j].id == path[i].firstKeptEntryId then start = j end end
      if start == 1 then start = i + 1 end
      break
    end
  end
  local cuts = {}
  for i = start, #path do
    local m = message_of(path[i])
    if m and m.role ~= "toolResult" then cuts[#cuts + 1] = i end
  end
  if #cuts < 2 then return nil end
  local acc, cut = 0, nil
  for i = #path, start, -1 do
    local m = message_of(path[i])
    if m then
      acc = acc + M.estimate(m)
      if acc >= settings.keepRecentTokens then
        for _, c in ipairs(cuts) do if c >= i then cut = c break end end
        break
      end
    end
  end
  if not cut or cut <= start then return nil end
  local summarize, all = {}, {}
  for i = start, cut - 1 do
    local m = message_of(path[i])
    if m and path[i].type ~= "compaction" then summarize[#summarize + 1] = m end
  end
  for i = start, #path do
    local m = message_of(path[i])
    if m then all[#all + 1] = m end
  end
  return { summarize = summarize, firstKeptEntryId = path[cut].id, previous = previous,
    tokensBefore = M.context_tokens(all) }
end

-- the conversation as text, so the summariser reads it rather than continuing it
function M.serialize(list)
  local parts = {}
  for _, m in ipairs(list) do
    if m.role == "user" or m.role == "custom" then
      local t = messages.text(m)
      if t ~= "" then parts[#parts + 1] = "[User]: " .. t end
    elseif m.role == "assistant" then
      for _, b in ipairs(m.content) do
        if b.type == "thinking" then parts[#parts + 1] = "[Assistant thinking]: " .. b.thinking
        elseif b.type == "text" and b.text ~= "" then parts[#parts + 1] = "[Assistant]: " .. b.text
        elseif b.type == "toolCall" then
          parts[#parts + 1] = "[Assistant tool calls]: " .. b.name .. "(" .. json.encode(b.arguments or {}) .. ")"
        end
      end
    elseif m.role == "toolResult" then
      parts[#parts + 1] = "[Tool result]: " .. messages.text(m):sub(1, 2000)
    end
  end
  return table.concat(parts, "\n\n")
end

function M.summarize(host, model, prep, options)
  options = options or {}
  local text = "<conversation>\n" .. M.serialize(prep.summarize) .. "\n</conversation>\n\n"
  if prep.previous then text = text .. "<previous-summary>\n" .. prep.previous .. "\n</previous-summary>\n\n" end
  text = text .. (prep.previous and M.UPDATE or M.PROMPT)
  if options.instructions then text = text .. "\n\nAdditional focus: " .. options.instructions end
  local reply = (options.stream_fn or ai.stream)(host, model, { systemPrompt = M.SYSTEM,
    messages = { { role = "user", content = { { type = "text", text = text } } } } },
    { apiKey = options.apiKey, maxTokens = options.maxTokens or 4096, signal = options.signal })
  if reply.stopReason == "error" or reply.stopReason == "aborted" then return nil, reply.errorMessage end
  return ai.text(reply)
end

return M
