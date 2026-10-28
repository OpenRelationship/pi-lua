# pi-lua

The [pi](https://github.com/badlogic/pi-mono) agent harness in portable Lua: pi's agent loop, its model layer,
its JSONL sessions, compaction and extension API, for any host that embeds a Lua VM. It runs unchanged on LuaJIT,
Lua 5.4/5.5 and Luerl, uses no FFI, and touches nothing outside what the host hands it: the network is the host's
`fetch`, the session file is the host's `write`. pi-lua has no shell and no built-in tools. A host gives the agent
its tools, usually as extensions.

```lua
local session = require("pi.session")
local ai = require("pi.ai")

local s = session.new{
  host = { fetch = my_fetch },                 -- fetch{ method, url, headers, body, timeout, on_data } -> { status, body }
  model = ai.model{ id = "claude-sonnet-5-5", provider = "anthropic", api = "anthropic-messages",
                    reasoning = true, contextWindow = 200000, maxTokens = 16384 },
  apiKey = os.getenv("ANTHROPIC_API_KEY"),
  systemPrompt = "You are a helpful assistant.",
  extensions = { require("my.weather") },
}
s:subscribe(function(e)
  if e.type == "message_update" and e.assistantMessageEvent.type == "text_delta" then
    io.write(e.assistantMessageEvent.delta)
  end
end)
s:prompt("What's the weather in Lisbon?")
```

An extension is a function given the API, as in pi:

```lua
return function(pi)
  pi.register_tool{
    name = "weather", description = "Current weather for a city",
    parameters = { type = "object", required = { "city" }, properties = { city = { type = "string" } } },
    execute = function(id, args, signal, on_update, ctx) return { content = lookup(args.city) } end,
  }
  pi.on("tool_call", function(event, ctx)
    if event.toolName == "weather" and event.input.city == "" then return { block = true, reason = "Which city?" } end
  end)
end
```

## Modules

| Module | pi's | What it is |
| --- | --- | --- |
| `pi.ai` | pi-ai | `stream(host, model, context, options, on_event)`: one model call in pi-ai's message and event shapes, for the `openai-completions` API (OpenAI, OpenRouter, Cerebras, Groq, Inception, llama.cpp, vLLM) and `anthropic-messages`; `register(api, fn)` adds a provider |
| `pi.ai.validate` | validateToolArguments | tool arguments checked against their JSON Schema, numbers and booleans sent as strings coerced |
| `pi.agent.loop` | agentLoop | turns, tool calls, `before_tool_call` / `after_tool_call`, steering and follow-up messages, `terminate` |
| `pi.agent` | Agent | the loop with its state, listeners, `steer`, `follow_up`, `abort`, `continue` |
| `pi.store` | SessionManager | the JSONL session tree (format 3): messages, custom entries, compactions, labels, branches |
| `pi.compaction` | compaction | the cut point, the structured checkpoint summary and its update |
| `pi.extensions` | ExtensionRunner | `on`, `register_tool`, `register_command`, `send_message`, `append_entry`, active tools, the event bus |
| `pi.session` | AgentSession | all of it together, as a host drives it |

pi's TypeScript names become snake_case (`registerTool` is `register_tool`, `beforeToolCall` is
`before_tool_call`); message and event fields keep pi's names (`toolCallId`, `stopReason`), so sessions read the same.

**Tools in waves.** pi runs a turn's tool calls together with `Promise.all`. In Lua a tool may give `start` and
`finish` instead of `execute`: every call in the turn is started, then each is finished in order, so a host can
work on them at once. A host that waits on its own work runs the session in a coroutine and yields from a tool;
the loop itself never yields, so a VM without coroutines runs it too.

## Tests

`core/pi/**/*_test.lua` use `mono.spec` and run as buck2 `lua_test` targets where the repository is attached
(OpenRelationship/arock attaches it at `submodules/pi-lua`). Every test drives a fake fetch or a scripted model;
none reaches the network.

## Credits

The design and names are [pi](https://github.com/badlogic/pi-mono)'s, by Mario Zechner (MIT).
[neoagent](https://github.com/tarruda/neoagent) (MIT), a Lua port of pi inside Neovim, showed the way.
