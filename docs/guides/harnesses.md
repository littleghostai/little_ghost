# Harnesses

A harness lets an Agent hand a self-contained coding task to an external
coding-agent command-line tool, such as Claude Code, Codex, or OpenCode, and get
back its answer, session, cost, and token usage. The tool runs as an ordinary
Sandbox process, so the same filesystem, network, and process limits that apply
to generated code apply to it.

## Delegate a task from an Agent

Declare a `Harnesses::Tool` with the harnesses the model may choose, where each
executable lives, and the bounds the model may request:

```ruby
class DelegateCodingTask < LittleGhost::Harnesses::Tool
  tool_name "delegate_coding_task"
  harnesses claude_code: {
    executable: "/opt/harnesses/bin/claude",
    home: "/home/agent",
    defaults: {base_url: "http://127.0.0.1:3130"}
  }
  budget default: 2, maximum: 10
  timeout default: 900, maximum: 3600
end

class SupportEngineerAgent < LittleGhost::Agent
  tools DelegateCodingTask
end
```

The model writes the task. The tool starts Claude Code in the Run's Sandbox,
publishes progress to the Run while it works, and returns a JSON object:

```json
{"harness": "claude_code", "status": "completed", "text": "Added the test.",
 "session_id": "7f0c2b8e-...", "cost_usd": 0.42, "turns": 12, "exit_code": 0,
 "stop_reason": "success", "usage": {"input_tokens": 1800, "output_tokens": 950}}
```

Passing `session_id` back continues the same tool session. The tool is
`exclusive`, so two harnesses never edit the same workspace at once.

## Watch progress

Each harness turns its tool's JSON output into `:harness` stream events. Every
event carries the harness name, the session, and an `event` Hash whose `kind`
is `:start`, `:text`, `:tool_call`, `:tool_result`, `:usage`, or `:stop`:

```ruby
SupportEngineerAgent.stream("Add a test for the refund policy lookup.") do |event|
  next unless event.type == :harness

  activity = event.data[:event]
  puts "#{activity[:kind]} #{activity[:name]}" if activity[:kind] == :tool_call
end
```

Long strings in events are shortened, and tool inputs become JSON strings. The
final `:stop` event repeats the status, cost, and turns.

Any Tool can publish its own progress the same way with
`publish_event(type, **data)`.

## Run a harness directly

Application code with a Sandbox can run a harness without an Agent. A harness
holds trusted settings; a `Harnesses::Request` holds the task and its limits:

```ruby
harness = LittleGhost::Harnesses.resolve(:codex).new(
  sandbox:,
  executable: "/opt/harnesses/bin/codex",
  home: "/home/agent",
  defaults: {base_url: "http://127.0.0.1:3131/v1", model: "gpt-5.2-codex"}
)
request = LittleGhost::Harnesses::Request.new(
  prompt: "Add a test for the refund policy lookup.",
  cwd: "repository",
  max_turns: 20,
  timeout: 900
)

result = harness.run(request) { |event| logger.info(event.data[:event]) }
result.status # => :completed
```

`Harnesses::Result#status` is `:completed`, `:failed`, `:timed_out`,
`:budget_exceeded`, or `:turns_exceeded`. Pass a Tool's `context:` to `run`
so cancelling the Run stops the process; `run` then raises instead of
returning a Result.

`probe` runs `--version` in the Sandbox and reports whether the installed tool
is one the harness understands:

```ruby
harness.probe # => {available: true, version: "0.52.0", supported: true, reason: nil}
```

## What each harness runs

| Harness | Command | Limits it enforces | Reports |
| --- | --- | --- | --- |
| `:claude_code` | `claude -p --bare --output-format stream-json` with fixed tool lists and no MCP servers | budget and turns | cost, turns, usage |
| `:codex` | `codex exec --json` with approvals off and its own sandbox disabled | timeout only | usage |
| `:open_code` | `opencode run --format json --agent build` with every permission granted | budget and turns, by the harness | cost, usage |

Every harness disables automatic updates, ignores project configuration where
the tool allows it, and keeps its configuration under `home`. The harness stops
the process when the request's timeout elapses or when reported cost or turns
pass the request's limits.

Codex's own command sandbox cannot run inside an isolating Sandbox, so it is
off; the LittleGhost Sandbox is the boundary. OpenCode receives permission for
every tool for the same reason.

## Keep credentials out of the sandbox

A harness passes a placeholder API key and a base URL to the tool. Point the
base URL at a `Network::Facade` whose host policy replaces the placeholder with
the real key, as described in
[Workspaces and Sandboxes](sandboxing.md). The real key then exists only in the
gateway process, never in the tool's environment or files.

> **Safety note:** A harness runs a model that can execute commands, edit
> files, and read the working directory, including instructions such as
> `AGENTS.md`. Run it in a Sandbox that limits writes to the files it should
> change and network access to the hosts it needs, and review its changes
> before you commit or publish them.

## Add another tool

Subclass `Harnesses::Base` and implement `command`, `environment`, and
`parse_line`. `parse_line` receives one output line and a `Harnesses::State`,
records progress in the state, and returns event Hashes. Register the class so
`Harnesses::Tool` can offer it:

```ruby
LittleGhost::Harnesses.register(:support_agent, SupportAgentHarness)
```

See `LittleGhost::Harnesses::Base` for the complete contract, and
`LittleGhost::Harnesses::Tool` for the hooks that choose settings per run.
