This is pi-lua (see README.md): pi's agent harness in portable Lua. It is the harness and nothing else: it names no
host. A host embeds it in its own Lua VM and gives it the fetch, the session store and the tools it reaches the world
through.

## Rules

- Its Lua is `core/pi/`, read as modules by name (`core/pi/agent/loop.lua` is `pi.agent.loop`).
- Follow pi. A behaviour pi has keeps pi's semantics and its field names; a TypeScript method name becomes
  snake_case. Check pi's own source (pi-agent-core, pi-ai, pi-coding-agent) before inventing anything.
- Portable Lua: it runs unchanged on LuaJIT, Lua 5.4/5.5 and Luerl. No FFI, no `goto`, no `//`, no `utf8`, no
  `io` or `os` beyond `os.time` as a default clock. The loop never yields itself.
- No shell and no built-in tools. Tools come from the host or its extensions.
- Every module has a `*_test.lua` (`mono.spec`) wired as a `lua_test` in its folder's `BUCK`. Tests never reach the
  network: a fake fetch or a scripted `stream_fn`.
- Files stay under 400 lines, split by responsibility. No placeholder modules.
- Keys are never logged, printed, written to a session or put in an error.
