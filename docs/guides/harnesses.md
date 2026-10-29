# Harnesses

A harness lets an Agent hand a self-contained coding task to an external
coding-agent command-line tool, such as Claude Code, Codex, or OpenCode, and get
back its answer, session, cost, and token usage. In an isolating Sandbox the
tool runs as an ordinary Sandbox process, so the same filesystem, network, and
process limits that apply to generated code apply to it. Without one, it runs
on the host with its own safeguards turned on; see [Choose a mode](#choose-a-mode).

## Delegate a task from an Agent

Declare a `Harnesses::Tool` with the harnesses the model may choose, where each
executable lives, and the bounds the model may request:

```ruby
class DelegateCodingTask < LittleGhost::Harnesses::Tool
  tool_name "delegate_coding_task"
  harnesses claude_code: {
    executable: "/opt/harnesses/bin/claude",
    home_root: :scratch,
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

Passing `session_id` back continues the same tool session. The model can
resume only a session that an earlier call in the same Run started; any other
`session_id` is a tool error. Final text longer than 16,000 characters is
shortened and marked with `"text_truncated": true`. The tool is `exclusive`, so
two harnesses never edit the same workspace at once.

## Choose where the tool keeps its files

Coding-agent tools write configuration, caches, and session history to their
home directory, and the model controls what they write. By default each
harness gets a private home that lasts for one Run: `Harnesses::Tool` creates
it beneath a Workspace path that the Sandbox lets processes write, on the first
call in the Run, and removes it when the Run closes. Calls in the same Run share
it, so sessions can be resumed; nothing reaches a later Run.

`home_root` names that Workspace path. Without it, the first writable runtime
path in the Sandbox policy is used:

```ruby
config.workspace = {root: "./tmp/support-run", paths: {scratch: "scratch"}}
config.sandbox = {
  provider: :native,
  files: {root: :read_write},
  runtime_paths: {scratch: :read_write},
  network: hosts.network_policy(facades: [answers_facade])
}
```

A harness run directly, without a Tool, creates its home for each `run` and
removes it afterwards.

Setting `home:` instead opts in to a persistent home that the application owns.
Everything a run writes there, including tool configuration such as MCP
servers, hooks, or notification commands, applies to every later run that uses
the same home. Use a persistent home only for runs that are equally trusted.

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

Long strings in events are shortened, and tool inputs become JSON strings. A
run emits at most 1,000 events; the final `:stop` event repeats the status,
cost, and turns, and reports `dropped_events` when the limit was reached.

Tool inputs and outputs can contain repository content and credentials the
tool read, so `Harnesses::Tool` publishes tool calls with only their name and
tool results with only their error flag. Override `harness_event_data` to
publish more, or to redact text before it reaches the Run's stream:

```ruby
class DelegateCodingTask < LittleGhost::Harnesses::Tool
  private

  def harness_event_data(event)
    activity = event.data.fetch(:event)
    return super unless activity[:kind] == :tool_call

    event.data.merge(event: activity.slice(:kind, :id, :name, :input))
  end
end
```

A block passed to `Harness#run` receives every event unfiltered.

Any Tool can publish its own progress the same way with
`publish_event(type, **data)`.

## Run a harness directly

Application code with a Sandbox can run a harness without an Agent. A harness
holds trusted settings; a `Harnesses::Request` holds the task and its limits:

```ruby
harness = LittleGhost::Harnesses.resolve(:codex).new(
  sandbox:,
  executable: "/opt/harnesses/bin/codex",
  home_root: :scratch,
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
the tool allows it, and keeps its configuration under its home. Claude Code
starts with an empty MCP server list, and Codex clears MCP servers and
notification commands on its command line; OpenCode merges the harness's
configuration over any configuration it finds in its home, so its MCP servers
are cleared only by a fresh home. The harness stops the process when the
request's timeout elapses or when reported cost or turns pass the request's
limits.

Cost and turns come from the tool's own output, which a misbehaving model or
tool can understate. Treat `timeout` and limits enforced outside the sandbox,
such as a network gateway or provider spending limits, as the bounds you rely
on.

## Choose a mode

A harness runs in one of two modes, chosen from its Sandbox unless you pass
`mode:` to `Base.new` or in a Tool's harness settings:

| Mode | Selected when | Boundary | Credentials |
| --- | --- | --- | --- |
| `:isolated` | the Sandbox reports isolation and does not inherit the host network | the LittleGhost Sandbox; the tool's own prompts and command sandbox are off | a placeholder that a network gateway replaces |
| `:native_guards` | there is no Sandbox, or it does not isolate, such as `:unrestricted` | the tool's own safeguards | the user's own, from the inherited environment |

In `:isolated` mode Claude Code runs its allowed tools, including the shell,
without prompting, Codex runs with `--sandbox danger-full-access`, and OpenCode
grants every permission. Codex's command sandbox cannot nest inside an
isolating Sandbox, and the Sandbox already limits files and network, so these
safeguards add nothing there.

In `:native_guards` mode the tool runs directly on the host, or in the given
non-isolating Sandbox, and never with those bypasses. Claude Code uses
`--permission-mode dontAsk` with file and search tools allowed and the shell
and web tools denied. Codex runs commands in its own sandbox with
`--sandbox workspace-write` and no network access; approvals stay off, so a
command that needs more access fails rather than asking. OpenCode may read and
edit files in the working directory and is denied everything else. Timeouts,
output limits, cancellation, and stopping the whole process group apply in
both modes.

```ruby
harness = LittleGhost::Harnesses.resolve(:claude_code).new(executable: "/usr/local/bin/claude")
harness.mode # => :native_guards
harness.run(LittleGhost::Harnesses::Request.new(prompt: "Summarize TODO.md.", cwd: "/path/to/project"))
```

Without a Sandbox, `cwd` is a host directory. The child inherits the Ruby
process's environment, so the tool authenticates the way it would for the user,
for example with `ANTHROPIC_API_KEY` or `OPENAI_API_KEY`. LittleGhost never
reads, stores, or forwards those credentials. Because each run gets a fresh
home, a login the tool stored under the user's home directory is not visible;
set `home:` to that directory to use it, which also lets runs change the
user's tool configuration. Whether a subscription or account allows automated
use is between the user and the tool's provider.

Asking for `mode: :isolated` with a Sandbox that does not isolate raises
`ConfigurationError`; a harness never falls back from `:isolated` to running
without a Sandbox.

## Keep credentials out of the sandbox

In `:isolated` mode a harness passes a placeholder API key and a base URL to
the tool. Point the
base URL at a `Network::Facade` whose host policy replaces the placeholder with
the real key, as described in
[Workspaces and Sandboxes](sandboxing.md). The real key then exists only in the
gateway process, never in the tool's environment or files. A harness rejects an
`api_key` default that does not begin with `little-ghost-placeholder`.

> **Safety note:** A harness runs a model that can execute commands, edit
> files, and read the working directory, including instructions such as
> `AGENTS.md`. Run it in a Sandbox that limits writes to the files it should
> change and network access to the hosts it needs, and review its changes
> before you commit or publish them.

## Let the harness call your tools

`serve_tools` gives the harness the application's own tools while it works.
Each call starts a `Harnesses::ToolServer`, a Model Context Protocol server on
a Unix socket, and passes it to the tool as an HTTP MCP server; the server
closes when the call returns:

```ruby
class DelegateCodingTask < LittleGhost::Harnesses::Tool
  harnesses claude_code: {executable: "/opt/harnesses/bin/claude", home_root: :scratch}
  serve_tools HelpCenterLookupTool, RefundPolicyTools,
    socket: "/run/harness-tools/tools.sock",
    url: "http://127.0.0.1:3133/mcp",
    name: "support"
end
```

Entries are declared as in `Agent.tools` and bound to the delegating tool's
binding, so they run with the same Run, credentials, cancellation, and
deadline as the Agent's own calls. Override `served_tools` to choose them per
Run. The harness connects to `url` and sees each tool as `support` server
tools; Claude Code allows `mcp__support`, Codex receives it in
`mcp_servers`, and OpenCode in its `mcp` configuration.

Coding-agent tools reach MCP servers over TCP, so the application makes `url`
lead to `socket` inside the Sandbox, for example with a relay that the
Sandbox's command wrapper starts, and mounts the socket's directory into the
Sandbox. Any process that can reach the socket can call every served tool.
Served calls run each tool directly, without Agent callbacks such as
`before_tool`, so serve only tools that enforce their own safeguards. A call
fails while another Run's server is listening on the same socket, so Runs that
can overlap need separate sockets.

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
