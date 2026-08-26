# Connect MCP, AG-UI, and OpenTelemetry

LittleGhost can load Tools from an MCP server, translate a Run stream for an
interactive interface, and publish traces. Each integration uses the same
Agents and Runs you already have.

## Load Tools from an MCP server

An MCP Toolset connects to one server and turns its published operations into
LittleGhost Tool classes. MCP support is opt-in so applications that do not use
it do not install or load its protocol and transport stack.

For stdio, add the official Ruby SDK to your `Gemfile`:

```ruby
gem "mcp", "~> 1.3"
```

The SDK currently installs `json_schemer`, which LittleGhost also uses to
validate server-advertised input and output schemas. For Streamable HTTP,
install the SDK's optional HTTP and SSE dependencies too:

```ruby
gem "mcp", "~> 1.3"
gem "faraday", "~> 2.0"
gem "event_stream_parser", "~> 1.0"
```

Then require the integration explicitly and add the Toolset through the same
Agent `tools` declaration used for local Tools:

```ruby
require "little_ghost/mcp"

class HelpCenterTools < LittleGhost::MCP::Toolset
  connection url: "https://mcp.example/rpc", timeout: 20
end

class CustomerSupportAgent < LittleGhost::Agent
  system_prompt "Use help-center tools for published guidance."
  tools HelpCenterTools
end

run = CustomerSupportAgent.ask("How long do refunds take?")
run.response
```

HTTP connections also accept `headers`, `timeout`, `signer`,
`allow_insecure_http`, `max_response_bytes`, `max_reconnection_wait`, `oauth`,
`protocol_version`, and `capabilities`. Pass a block when credentials depend on
the current Agent run:

```ruby
connection do |binding|
  token = McpAccessTokens.for_actor(binding.run.invocation.actor_id)
  {
    url: "https://mcp.example/rpc",
    headers: {"Authorization" => "Bearer #{token}"},
    timeout: 20
  }
end
```

The block's `binding` gives it access to the current Run. LittleGhost evaluates
the block before opening the MCP session, so each Agent run can use credentials
for its authenticated caller.

Use `command` instead of `url` for a stdio server. `args`, `env`, `timeout`,
`max_response_bytes`, `protocol_version`, and `capabilities` are available:

```ruby
class LocalDatabaseTools < LittleGhost::MCP::Toolset
  connection command: "bundle", args: ["exec", "database-mcp"],
    env: {"APP_ENV" => "production"}, inherit_env: false, timeout: 30
end
```

LittleGhost creates and closes one official `MCP::Client` for each Agent run.
HTTP sessions therefore receive the SDK's normal session-termination request,
and stdio child processes are closed at the end of the run.

A stdio server is executable code with the Ruby process's operating-system
permissions; it is not a sandbox. By default it also inherits the process
environment and `env` adds or replaces entries. Set `inherit_env: false` to
start with only the entries in `env`. A `nil` value removes one inherited entry.
Use an operating-system sandbox when the executable itself is not fully trusted.

By default, the Agent receives every operation published by the server. Their
normalized server names, such as `search` and `fetch`, become Tool names.

Use `map_tool` when the Agent should receive only part of the server catalog or
when a generated Tool needs a different name or configuration:

```ruby
class CuratedHelpCenterTools < LittleGhost::MCP::Toolset
  connection url: "https://mcp.example/rpc", timeout: 20

  map_tool do |tool_class, definition:, binding:|
    next unless %w[search fetch].include?(definition.source_name)

    tool_class.tool_name "help_center_#{definition.source_name}"
    tool_class
  end
end
```

`definition` describes the operation published by the server, and `binding`
identifies the current Agent run. Return the class after configuring it, or
return `nil` to omit the operation. Renaming a generated Tool does not change
the original `Definition#source_name` sent back to the server.

The Agent can call the generated Tools like local Tools. Most MCP results need
no mapping. LittleGhost returns any JSON value from `structuredContent` when it
is present, otherwise it returns the server's text. Server images become
Artifacts.

Use `map_result` when one operation needs application-specific conversion. This
example turns the server's download identifier into a deferred Artifact:

```ruby
map_result do |result, call:, binding:|
  next result unless call.definition.source_name == "export"

  LittleGhost::Tool::Result.new(
    value: result.structured_content,
    artifacts: [
      LittleGhost::Artifact.deferred(
        reference: result.metadata.fetch("download_id"),
        media_type: "application/octet-stream"
      )
    ]
  )
end
```

`map_result` receives the complete `MCP::Result`, the `MCP::Call` that produced
it, and the current binding. Return any Ruby value or `Tool::Result`. Returning
the supplied result unchanged keeps the default conversion described above.
MCP images and local Tool artifacts use the same storage and presentation
rules when `Configuration#artifacts` is enabled. Images and documents are sent
as model content; their stored references are fallback information rather than
a second representation. LittleGhost checks calls and results against
server-advertised JSON Schema Draft 2020-12 schemas. References must be
same-document references; remote schema retrieval is intentionally disabled.

### Configure official client features

`configure_client` exposes the run-scoped official client before connection.
Use it to install handlers for protocol features such as elicitation. Advertise
the matching capability in `connection`:

```ruby
class InteractiveTools < LittleGhost::MCP::Toolset
  connection url: "https://mcp.example/rpc",
    capabilities: {elicitation: {}}

  configure_client do |client, binding:|
    client.on_elicitation do |request|
      Elicitations.answer(request, run: binding.run)
    end
  end
end
```

The SDK also exposes handlers for sampling and roots for protocol versions
where those features apply. Review their trust and user-consent requirements
before advertising them.

HTTP authentication can use headers, a signer, or the SDK's OAuth providers.
For example, a client-credentials connection can be declared as:

```ruby
connection url: "https://mcp.example/rpc", oauth: {
  grant: :client_credentials,
  client_id: ENV.fetch("MCP_CLIENT_ID"),
  client_secret: ENV.fetch("MCP_CLIENT_SECRET")
}
```

`oauth` also accepts an official provider instance for advanced SDK features.
Supported hash grants are `authorization_code`, `client_credentials`, and
`jwt_bearer`. A `signer` is called with a `Net::HTTP::Post`; an AWS SigV4 signer
also requires `gem "aws-sigv4"`.

When the connection needs a custom transport, return a newly created official or
compatible transport from the connection block. The transport must be
run-scoped because LittleGhost wraps and closes it; use `configure_client` for
client handlers. A compatible custom transport must implement `send_request`,
`send_notification`, and `close`; it may also implement the official connection
methods. The built-in MCP HTTP and stdio transport I/O timeout is capped by the
Run deadline. SDK OAuth discovery and token exchanges, authorization callbacks,
and custom transports own their own timeout behavior; configure those paths so
they cannot wait past the application's deadline:

```ruby
connection do |_binding|
  MCP::Client::Stdio.new(command: "database-mcp")
end
```

An optional server can fail discovery without preventing Agent construction:

```ruby
class HelpCenterTools < LittleGhost::MCP::Toolset
  connection { |binding| McpConnections.help_center(binding) }
  optional true
  on_error do |error, binding:|
    McpAvailability.report(error, run_id: binding.run.invocation.run_id)
  end
end
```

`optional true` converts expected provider and protocol discovery failures
into an empty Tool set. `on_error` observes only those caught failures.
Cancellation, deadlines, configuration errors, and application callback
failures still propagate.

LittleGhost limits the number and total size of discovered operations, the
complexity of their schemas, and the size and number of returned images. HTTP
also limits each protocol message and requires HTTPS unless local HTTP is
explicitly enabled.

> **Safety note:** An MCP server supplies descriptions and results that the model
> can see. Structural validation does not make that content trustworthy or
> authorize an operation it suggests. Expose only the operations the Agent
> needs, use narrowly scoped credentials, and have the server authorize every
> sensitive call. If a result becomes a deferred Artifact, its resolver must
> verify that the referenced file belongs to the authenticated caller, fetch
> only from an intended service, and limit the response size before returning
> bytes to LittleGhost.

### Protocol compatibility

LittleGhost delegates transport, lifecycle negotiation, OAuth, pagination,
cancellation, and protocol evolution to the [official MCP Ruby
SDK](https://github.com/modelcontextprotocol/ruby-sdk). The default connection
mode automatically negotiates across every protocol version supported by the
installed compatible SDK. Pin `protocol_version` only when interoperability
requires a specific version; the SDK rejects unsupported pins.

LittleGhost's integration surface is the MCP client Tool flow: discover Tools,
validate their schemas, expose them to an Agent, call them, and convert their
results. `configure_client` makes applicable server-to-client requests and
multi-round-trip input available through the official client. LittleGhost does
not claim every MCP server feature, optional extension, or future SDK API as its
own public API. Features outside the Tool flow can be configured on the
run-scoped official client when the SDK supports them. Check the [Ruby SDK client
documentation](https://ruby.sdk.modelcontextprotocol.io/client/) and the
[versioned MCP specification](https://modelcontextprotocol.io/specification/)
for the installed SDK's current boundary.

Requiring `little_ghost` alone never loads MCP. Requiring
`little_ghost/mcp` without the SDK or schema validator raises an actionable
`LittleGhost::DependencyError`; HTTP and SSE dependencies are checked only when
that transport needs them.

## Send a Run stream through AG-UI

The AG-UI adapter converts LittleGhost events into protocol event hashes:

```ruby
require "json"
require "little_ghost/ag_ui"

source = CustomerSupportAgent.stream_ask(
  question,
  actor_id: authenticated_user.id,
  context: {account_id: authenticated_user.account_id}
)

events = LittleGhost::AGUI::Adapter.new.stream(
  source,
  thread_id: conversation.id,
  run_id: request.request_id
)

events.each { |event| websocket.write(JSON.generate(event)) }
```

The adapter translates text, reasoning, Tool activity, usage, retries, trace
context, subagent activity, and terminal outcomes. It is stateless between
calls. Your application still owns the connection, backpressure, disconnect
behavior, and any request state its callbacks need.

LittleGhost also emits namespaced custom events. Consumers should preserve or
deliberately ignore event types they don't recognize. See the [AG-UI event
documentation](https://docs.ag-ui.com/concepts/events) when implementing the
client.

> **Safety note:** A Run stream can include model output, Tool arguments and
> results, errors, and participant activity. Check that the connected user may
> see the complete Run, then filter fields before sending or storing events.

Calling `each` drives the source stream on the caller's fiber or thread. When a
client disconnects, stop enumerating and apply the cancellation behavior your
application needs. Closing the socket can't undo Tool work that already ran.

## Trace Runs with OpenTelemetry

Configure an OpenTelemetry SDK and exporter in the application, then register
the LittleGhost subscriber before the first Agent call:

```ruby
LittleGhost.configure do |config|
  config.instrument LittleGhost::Tracing::OpenTelemetry.new
end
```

LittleGhost depends on `opentelemetry-api`, leaving the SDK, processor, and
exporter up to the application. It emits spans and events for Runs, Agents,
model calls, Tools, assemblies, sessions, usage, and failures. Active operations
can propagate W3C `traceparent` and `tracestate` fields.

Prompts, messages, responses, Tool arguments, and exception content are omitted
by default. If you intentionally need some of that content, install a
`LittleGhost::Support::ContentCapture` with a scrubber before enabling capture.
Avoid putting raw user, order, session, or request IDs in span attributes.

Attribute names follow the evolving [OpenTelemetry GenAI semantic
conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/) where they
apply. Flush or shut down `LittleGhost::Instrumentation` during application
shutdown when your backend buffers data.

See [Running in Production](production.md) for startup, shutdown, and observability,
[Tools](tools.md) for local and remote Tool behavior, and [Workspaces and
Sandboxes](sandboxing.md) for child processes and files.
