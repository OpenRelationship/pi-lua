-- The messages a session holds beyond the model's three (user, assistant, toolResult), and how each reaches the
-- model, as pi's convertToLlm does:
--
--   { role = "custom", customType, content, display?, details? }   an extension's message: sent as a user turn
--   { role = "compactionSummary", summary, tokensBefore }           what compaction kept of the earlier conversation
--
--   messages.to_llm(list) -> the list the model is sent
local M = {}

M.COMPACTION_PREFIX = "The conversation history before this point was compacted into the following summary:\n\n<summary>\n"
M.COMPACTION_SUFFIX = "\n</summary>"

local function content_of(c)
  if type(c) == "string" then return { { type = "text", text = c } } end
  return c or {}
end

function M.to_llm(list)
  local out = {}
  for _, m in ipairs(list) do
    if m.role == "user" or m.role == "assistant" or m.role == "toolResult" then
      out[#out + 1] = m
    elseif m.role == "custom" then
      out[#out + 1] = { role = "user", content = content_of(m.content), timestamp = m.timestamp }
    elseif m.role == "compactionSummary" then
      out[#out + 1] = { role = "user", timestamp = m.timestamp,
        content = { { type = "text", text = M.COMPACTION_PREFIX .. m.summary .. M.COMPACTION_SUFFIX } } }
    end
  end
  return out
end

-- the text of a message's text blocks (a string content is its own text)
function M.text(m)
  if type(m.content) == "string" then return m.content end
  local out = {}
  for _, b in ipairs(m.content or {}) do
    if b.type == "text" then out[#out + 1] = b.text end
  end
  return table.concat(out, "")
end

return M
