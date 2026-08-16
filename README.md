# zig-harness

A stripped-down [Wizard](https://github.com/teddytennant/wizard) written in Zig, with LuaJIT in-process.

No TUI, no GUI, no mesh, no ACP. One binary, one agent loop, the same prompts and the same everyday tools.

```
zig-harness -p "list the Zig files and summarize what they do"
```

## What it is

Wizard is a 200k-line Rust agent with several surfaces. zig-harness is the experiment: can the *harness* (prompts, tools, LuaJIT, a provider loop) live in Zig without all of that?

- Headless only (`-p` / `--prompt`)
- Genie and sovereign personalities, plan mode, omakase
- Native tools: files, shell, git, memory, todo, manual, web fetch/search, compact, interview, exit_plan, spawn_subagent
- Embedded LuaJIT: `run_code` and `--eval-lua`
- OpenAI-compatible Chat Completions (any `ZIG_HARNESS_BASE_URL`)

## Build

Needs Zig 0.14+, LuaJIT, libcurl, pkg-config.

```sh
# Nix
nix-shell --run 'zig build test && zig build -Doptimize=ReleaseSafe'

# elsewhere
zig build test
zig build -Doptimize=ReleaseSafe
```

The binary lands at `zig-out/bin/zig-harness`.

## Run

```sh
export OPENAI_API_KEY=sk-...
# optional
export ZIG_HARNESS_MODEL=gpt-4.1-mini
export ZIG_HARNESS_BASE_URL=https://api.openai.com/v1   # or any compatible root

./zig-out/bin/zig-harness -p "what is in README.md?"
./zig-out/bin/zig-harness --mode sovereign -p "add a failing test, then make it pass"
./zig-out/bin/zig-harness --plan -p "design a cache for tool results"
./zig-out/bin/zig-harness --eval-lua "print(wizard.runtime); return 2+2"
```

Local llama.cpp / vLLM / Ollama (OpenAI-compatible):

```sh
export ZIG_HARNESS_BASE_URL=http://127.0.0.1:11435/v1
export ZIG_HARNESS_MODEL=Qwen3.6-27B-Q4_K_M
export OPENAI_API_KEY=   # empty is fine for local servers
./zig-out/bin/zig-harness -p "say hi"
```

## Layout

```
src/
  main.zig          CLI
  agent.zig         tool-calling loop + subagents
  llm.zig           OpenAI-compatible client (libcurl)
  lua.zig           LuaJIT host (wizard.read_file / write_file)
  prompts.zig       system prompt + charter manual
  tools/            native tools
prompts/            genie, sovereign, plan, omakase, todo, context
lua/                bundled Lua (json.lua, example slugify tool)
WIZARD.md           operating charter (served by the `manual` tool)
```

Config, memories, and sessions live under `~/.zig-harness` (override with `ZIG_HARNESS_HOME`).

## LuaJIT

`--eval-lua` and the `run_code` tool share one host:

```lua
print(wizard.runtime)          -- "luajit"
wizard.write_file("out.txt", "hi")
return wizard.read_file("out.txt")
```

`args` is the JSON object the model passed. `print` is captured as the tool result. A sandboxed profile (no `io`/`os`, paths confined to the project) exists for untrusted scripts.

## Status

This is a working skeleton, not a Wizard replacement. Missing on purpose: TUI/GUI, MCP, fleet, mesh, self-update, deep evolve. Those belong in the Rust tree until this one earns them.
