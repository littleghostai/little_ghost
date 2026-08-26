# Connect agents to MCP servers

Give an Agent access to operations published by a Model Context Protocol (MCP)
server without changing how your application calls the Agent.
`LittleGhost::MCP::Toolset` turns operations discovered by the official MCP Ruby
client into LittleGhost Tool classes, which join the same `tools` declaration as
local application Tools.

MCP support is opt-in. Requiring `little_ghost` alone does not install or load
the SDK or its transports.

## Connect over Streamable HTTP

Add the official SDK and its HTTP dependencies to your bundle:

```ruby
gem "mcp", "~> 1.3"
gem "faraday", "~> 2.0"
gem "event_stream_parser", "~> 1.0"
```

Require the integration explicitly, then create a Toolset with a `client`
block. Return a new official client from the block:

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

LittleGhost calls the block once for each Agent run. It connects the client,
discovers the server's Tools, and closes the transport when the run ends.

The `client` block receives the current `Tool::Binding`. Use it to build headers
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

## Connect a local server over standard input and output

A standard input and output (stdio) connection needs only the official SDK:

```ruby
gem "mcp", "~> 1.3"
```

Construct the SDK transport in the same `client` block:

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

A stdio server is a child process with the same operating-system permissions as
your Ruby process. It is not a sandbox. Use an operating-system sandbox when
you do not fully trust the executable.

The `env` Hash changes only the variables you name. The child inherits every
other variable from the parent process. Clear sensitive variables explicitly,
or launch the server through an isolated wrapper when it must not receive
ambient credentials.

## Configure the official client

Set timeouts, message limits, OAuth, middleware, and other transport behavior
through the SDK. Keyword arguments on `client` go directly to
`MCP::Client#connect`; use them for an explicit protocol mode, version, or client
capability.

### Respond to server requests

A server may need more information while handling a Tool call. MCP calls this
elicitation. Advertise the capability when connecting, then register a handler
on the client:

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

The handler can answer from the current Run or pass the request to an application
interface. Sampling similarly lets a server request a model call, while roots
tell a server which directories the application makes available. Configure
these features on the official client.

Treat every server-initiated handler request as untrusted. Authorize it against
the current run, restrict roots to intended paths, constrain model sampling and
its cost, and return only the application data that server is allowed to receive.

Return a new, unconnected client for every run. Building it should not start
remote work. LittleGhost closes transports that provide `close`, including when
connection or discovery fails. If a custom transport owns other resources, it
must release them itself.

Set transport timeouts to match the application's deadline. LittleGhost passes
Run cancellation and deadlines to Tool discovery and calls, but connection has
its own timeout behavior.

## Plan concurrency and cancellation

Most applications only need transport timeouts. The details below matter when
the application uses a Fiber scheduler or runs independent Tools concurrently.

### Connection

LittleGhost connects while it discovers the Agent's Tools. Run cancellation
does not interrupt connection, so the transport's connection and read timeouts
control how long it can wait. Choose a scheduler-compatible transport adapter
when other fibers must continue during that time.

### Tool discovery and calls

Tool discovery and calls honor Run cancellation and deadlines. Cancelling an
HTTP call returns control to the Run, but the underlying request may continue
waiting until the server responds or the transport closes.

All Tools for one run share the same client. HTTP calls may overlap when
LittleGhost runs independent Tools concurrently, so choose a Faraday adapter
that supports overlapping calls. If the server or transport requires one call
at a time, mark the generated Tools exclusive:

```ruby
map_tool do |tool_class, mcp_tool:, binding:|
  tool_class.exclusive true
  tool_class
end
```

LittleGhost serializes calls through the official stdio transport. If one of
those calls is cancelled, it closes that run's session rather than risk reading
a late response as the answer to a later call. A custom or decorated stdio
transport must provide its own serialization, cancellation behavior, and
cleanup.

### Server handlers

The server may invoke a handler while other work is active. Write handlers for
concurrent use and capture the application values they need when building the
client. Do not rely on fiber-local state inside a handler.

## Select and map Tools

By default, the Agent receives every Tool published by the server. LittleGhost
normalizes each name for the model and keeps the server's original name for
calls. Discovery stops after 1,000 Tools or 100 pages, which bounds the work an
untrusted catalog can create in one run.

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

`mcp_tool` is the Tool published by the official client. Return the generated
class, a subclass, or `nil` to omit it. Renaming the generated Tool changes the
name shown to the model, not the name sent back to the server.

LittleGhost sends the server's input schema to the model unchanged. It does not
validate arguments against that schema; the server must validate them before
performing an operation. LittleGhost limits schema depth and node count during
discovery. Configure the transport's message-size limit to bound the bytes
accepted from a server.

> **Safety note:** Server descriptions and results become visible to the model.
> Treat them as untrusted content. Expose only the operations the Agent needs,
> use narrowly scoped credentials, and have the server authorize every sensitive
> call.

## Convert results

Without a mapping, LittleGhost returns `structuredContent` when the server sends
it. Otherwise, it returns the text or remaining visible content blocks. MCP
image blocks become Artifacts.

Suppose the help-center server returns `structuredContent` with an `articles`
array. Use `map_result` to present each article as a short line:

```ruby
map_result do |value, mcp_tool:, **|
  next value unless mcp_tool.name == "search"

  value.fetch("articles").map do |article|
    "#{article.fetch("title")}: #{article.fetch("url")}"
  end
end
```

`value` is LittleGhost's default conversion, and `mcp_tool` identifies the
server operation. Return `value` unchanged or replace it with any Ruby value or
`Tool::Result`. The block can also receive the raw result, sent arguments, and
current binding; see the [`MCP::Toolset`
API](rdoc-ref:LittleGhost::MCP::Toolset) for their exact shapes.

Image Artifacts remain attached to the mapped result. A server result marked
`isError` remains a model-visible Tool error.

For custom images, files, or deferred Artifacts, continue with [Structured
Results and Content](structured_outputs_and_content.md). A deferred resolver
must verify ownership, fetch only from the intended service, and limit response
size.

## Keep an optional server from blocking a run

An optional server can fail discovery without preventing Agent construction:

```ruby
class OptionalHelpCenterTools < HelpCenterTools
  optional true
  on_error do |error, binding:|
    McpAvailability.report(error, run_id: binding.run.invocation.run_id)
  end
end
```

`optional true` turns an expected connection or protocol error during discovery
into an empty Tool set. Configuration errors, cancellation, deadlines, and
failures in application callbacks still stop the run.

## Let the SDK negotiate the protocol version

The [official MCP Ruby SDK](https://github.com/modelcontextprotocol/ruby-sdk)
handles protocol negotiation and transport behavior. Without explicit connect
options, it negotiates with the server using a protocol version the installed
SDK supports. Pin `protocol_version` or `mode` only when interoperability
requires it.

Need sampling, roots, elicitation, or another client capability? Configure it
on the client you build above. The installed SDK and negotiated protocol version
determine what is available. Check the [Ruby SDK client
documentation](https://ruby.sdk.modelcontextprotocol.io/client/) and the
[versioned MCP specification](https://modelcontextprotocol.io/specification/)
for the capability you need.

Continue with [Tools](tools.md) for the local Tool boundary,
[Integrations](integrations.md) to send Runs through AG-UI or OpenTelemetry, or
the [`MCP::Toolset` API](rdoc-ref:LittleGhost::MCP::Toolset) for exact mapping
and ownership contracts.
