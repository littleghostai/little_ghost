# Connect agents to MCP servers

Give an Agent access to operations published by a Model Context Protocol (MCP)
server without changing how your application calls the Agent.
`LittleGhost::MCP::Toolset` turns operations discovered by the official MCP Ruby
client into LittleGhost Tool classes, which join the same `tools` declaration as
local application Tools.

MCP support is opt-in. Requiring `little_ghost` alone does not install or load
the SDK or its transports.

Add the official SDK for stdio connections:

```ruby
gem "mcp", "~> 1.3"
```

Streamable HTTP also needs the SDK's HTTP and SSE dependencies:

```ruby
gem "mcp", "~> 1.3"
gem "faraday", "~> 2.0"
gem "event_stream_parser", "~> 1.0"
```

Require the integration explicitly, then declare a factory for a fresh,
unconnected `MCP::Client`. LittleGhost calls the factory once for each Agent
run, connects the returned client, and closes its transport when the run ends:

```ruby
require "little_ghost/mcp"

class HelpCenterTools < LittleGhost::MCP::Toolset
  client do |_binding|
    transport = MCP::Client::HTTP.new(
      url: "https://mcp.example/rpc"
    )
    MCP::Client.new(transport:)
  end
end

class CustomerSupportAgent < LittleGhost::Agent
  system_prompt "Use help-center tools for published guidance."
  tools HelpCenterTools
end

run = CustomerSupportAgent.ask("How long do refunds take?")
run.response
```

The factory receives the current `Tool::Binding`, so it can construct headers
or credentials from authenticated application context without storing them on
the Toolset:

```ruby
class AccountTools < LittleGhost::MCP::Toolset
  client do |binding|
    token = McpAccessTokens.for_actor(binding.run.invocation.actor_id)
    transport = MCP::Client::HTTP.new(
      url: "https://mcp.example/rpc",
      headers: {"Authorization" => "Bearer #{token}"}
    )
    MCP::Client.new(transport:)
  end
end
```

Configure transport timeouts, message limits, OAuth providers, middleware, and
other transport behavior through the SDK. LittleGhost does not copy those
options into a second connection API. For stdio, construct the official
transport directly:

```ruby
class LocalDatabaseTools < LittleGhost::MCP::Toolset
  client do |_binding|
    transport = MCP::Client::Stdio.new(
      command: "bundle",
      args: ["exec", "database-mcp"],
      env: {"APP_ENV" => "production"},
      read_timeout: 30
    )
    MCP::Client.new(transport:)
  end
end
```

A stdio server is executable code with the Ruby process's operating-system
permissions; it is not a sandbox. Choose its environment and use an operating-
system sandbox when the executable is not fully trusted. The SDK's `env` Hash
adds, replaces, or removes named variables; all other variables from the parent
process remain inherited. Clear sensitive variables explicitly or start the
server through an isolated wrapper when it must not receive ambient credentials.

## Configure the official client

Keyword arguments passed to `client` are forwarded unchanged to
`MCP::Client#connect`. Use them for client capabilities or an explicit protocol
mode or version. Configure handlers on the client before returning it:

```ruby
class InteractiveTools < LittleGhost::MCP::Toolset
  client(capabilities: {elicitation: {}}) do |binding|
    transport = MCP::Client::HTTP.new(url: "https://mcp.example/rpc")
    MCP::Client.new(transport:).tap do |official_client|
      official_client.on_elicitation do |request|
        Elicitations.answer(request, run: binding.run)
      end
    end
  end
end
```

The SDK also exposes sampling and roots handlers, OAuth providers, pagination
limits, and transport customization. Configure those features through its
public API so applications can adopt new SDK capabilities without waiting for a
matching LittleGhost wrapper.

Treat every server-initiated handler request as untrusted. Authorize it against
the current run, restrict roots to intended paths, constrain model sampling and
its cost, and return only the application data that server is allowed to receive.

The factory must return a new, unconnected `MCP::Client`. Client and transport
construction should not start remote work. Once the client is returned,
LittleGhost calls `close` on transports that expose it, including after
connection or discovery fails. A custom transport owns any resource cleanup not
covered by that method. Configure SDK transport timeouts so construction and
connection cannot wait past the application's intended deadline; LittleGhost
bridges Run cancellation and deadlines to SDK cancellation tokens for Tool
discovery and calls.

## Plan concurrency and cancellation

The client factory and `MCP::Client#connect` run on the fiber or thread that is
discovering the Agent's Tools. Connection does not receive an SDK cancellation
token. Choose a scheduler-compatible transport adapter when other fibers must
continue during connection, and always configure the transport's connection and
read timeouts.

For discovery and Tool calls, LittleGhost passes an SDK cancellation token and
watches the Run's cancellation and deadline. The official SDK performs each
cancellable request on a worker thread; LittleGhost uses another short-lived
thread to watch the Run. This keeps a scheduled fiber responsive, but MCP calls
are thread-backed rather than fiber-native. A cancelled HTTP request can leave
the SDK's request thread waiting until the server responds or the transport
closes.

All Tools generated for one Agent run share the same client. Calls through the
official HTTP transport may overlap when LittleGhost runs independent Tools
concurrently. Use a Faraday adapter that permits overlapping calls. If the
server, adapter, or a custom transport requires serialization, mark the
generated Tools exclusive:

```ruby
map_tool do |tool_class, mcp_tool:, binding:|
  tool_class.exclusive true
  tool_class
end
```

When the client uses the official `MCP::Client::Stdio` transport directly,
LittleGhost serializes requests because one subprocess stdout stream cannot
safely serve multiple readers. Cancelling a request closes and invalidates that
run's session; later calls through its generated Tools fail instead of reusing a
stream whose pending response may still arrive. A custom transport, including a
transport that decorates stdio, must provide its own request serialization,
cancellation-safe invalidation, and `close` behavior.

SDK handlers for elicitation, sampling, roots, and server requests may run on an
SDK worker or listener thread. Write those handlers for concurrent use, capture
the application values they need when building the client, and do not rely on
the current fiber's local state inside a handler.

## Select and map Tools

By default, the Agent receives every Tool published by the server.
LittleGhost normalizes server names for model-facing Tool names while retaining
the official Tool's original name for dispatch. Discovery stops after 1,000
Tools or 100 pages so an untrusted server cannot create an unbounded number of
Ruby classes in one Agent run.

Use `map_tool` to omit operations or configure their generated classes:

```ruby
class CuratedHelpCenterTools < HelpCenterTools
  map_tool do |tool_class, mcp_tool:, binding:|
    next unless %w[search fetch].include?(mcp_tool.name)

    tool_class.tool_name "help_center_#{mcp_tool.name}"
    tool_class
  end
end
```

`mcp_tool` is the official `MCP::Client::Tool`, and the generated class also
exposes it through `.mcp_tool`. Return the generated class, a subclass, or `nil`
to omit it. Renaming the generated Tool does not change the name sent to the
server.

LittleGhost publishes the SDK-provided input schema to the model but does not
compile or validate it independently. The MCP server remains responsible for
validating Tool arguments. This avoids claiming support for a different JSON
Schema subset from the protocol and avoids a second validation result that can
disagree with the server. LittleGhost still applies structural nesting and node
limits across the discovered catalog. It also translates an SDK nesting failure
from transport-level processing into a normal protocol failure so the client is
closed rather than leaving discovery blocked.

## Convert results

Without a mapping, LittleGhost returns `structuredContent` when present,
including explicit `false` or `null`; otherwise it returns text content or the
remaining visible content blocks. MCP image blocks become Artifacts.

Use `map_result` for application-specific conversion:

```ruby
map_result do |value, result:, mcp_tool:, arguments:, binding:|
  next value unless mcp_tool.name == "export"

  LittleGhost::Tool::Result.new(
    value:,
    artifacts: [
      LittleGhost::Artifact.deferred(
        reference: result.fetch("_meta").fetch("download_id"),
        media_type: "application/octet-stream"
      )
    ]
  )
end
```

The positional `value` is LittleGhost's default conversion. `result` is the raw
MCP `tools/call` result Hash returned by the SDK; `mcp_tool` is the official Tool;
`arguments` are the values sent to the server; and `binding` identifies the
current run. Return any Ruby value or `Tool::Result`. Image Artifacts are added
to any Artifacts returned by the mapper. A server result marked `isError`
remains a model-visible Tool error.

An optional server can fail discovery without preventing Agent construction:

```ruby
class OptionalHelpCenterTools < HelpCenterTools
  optional true
  on_error do |error, binding:|
    McpAvailability.report(error, run_id: binding.run.invocation.run_id)
  end
end
```

`optional true` converts expected SDK provider and protocol discovery failures
into an empty Tool set. Configuration, cancellation, deadline, and application
callback failures still propagate.

> **Safety note:** An MCP server supplies descriptions and results that the model
> can see. A schema does not make that content trustworthy or authorize an
> operation it suggests. Expose only the operations the Agent needs, use narrowly
> scoped credentials, and have the server authorize every sensitive call. A
> deferred Artifact resolver must verify ownership, fetch only from an intended
> service, and limit response size before returning bytes to LittleGhost.

## Protocol compatibility

LittleGhost delegates lifecycle negotiation, protocol envelopes, transports,
OAuth, pagination, cancellation messages, multi-round-trip input, and protocol
evolution to the [official MCP Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk).
With no explicit connect options, the SDK negotiates across every protocol
version it supports. Pin `protocol_version` or `mode` only when interoperability
requires it.

LittleGhost's interface is the MCP client Tool flow: discover official SDK
Tools, expose them to an Agent, call them, and convert their results. Other MCP
features remain accessible on the client created by the application, but
LittleGhost does not claim each server capability or future SDK method as part
of its own API. See the [Ruby SDK client documentation](https://ruby.sdk.modelcontextprotocol.io/client/)
and the [versioned MCP specification](https://modelcontextprotocol.io/specification/)
for the installed SDK's supported boundary.

Continue with [Tools](tools.md) for the local Tool boundary,
[Integrations](integrations.md) to send Runs through AG-UI or OpenTelemetry, or
the [`MCP::Toolset` API](rdoc-ref:LittleGhost::MCP::Toolset) for exact mapping
and ownership contracts.
