# Connect Runs to interfaces and tracing

Use AG-UI to stream Run events to an interactive client. Use OpenTelemetry to
publish traces to the backend your application already uses. Neither changes
the Agent that produced the Run.

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

The adapter translates the full Run, including model output, Tool activity,
retries, subagent activity, and the final outcome. It does not keep state between
calls. Your application owns the connection, backpressure, disconnect behavior,
and any request state its callbacks need.

LittleGhost may emit event types beyond the core AG-UI set. Decide whether the
client preserves or ignores types it does not recognize. See the [AG-UI event
documentation](https://docs.ag-ui.com/concepts/events) when implementing the
client.

> **Safety note:** A Run stream can include model output, Tool arguments and
> results, errors, and participant activity. Check that the connected user may
> see the complete Run, then filter fields before sending or storing events.

Calling `each` drives the source stream on the caller's fiber or thread. When a
client disconnects, stop enumerating and decide whether the application should
cancel the Run. Closing the socket cannot undo Tool work that already ran.

## Trace Runs with OpenTelemetry

Configure an OpenTelemetry SDK and exporter in the application, then register
the LittleGhost subscriber before the first Agent call:

```ruby
LittleGhost.configure do |config|
  config.instrument LittleGhost::Tracing::OpenTelemetry.new
end
```

LittleGhost includes the `opentelemetry-api` integration. Your application
chooses the SDK, processor, and exporter. The subscriber emits spans and events
for Runs, model calls, Tools, assemblies, sessions, usage, and failures, and it
can propagate W3C `traceparent` and `tracestate` fields.

Prompts, messages, responses, Tool arguments, and exception content are omitted
by default. If you intentionally need some of that content, install a
`LittleGhost::Support::ContentCapture` with a scrubber before enabling capture.
Avoid putting raw user, order, session, or request IDs in span attributes.

Attribute names follow the evolving [OpenTelemetry GenAI semantic
conventions](https://opentelemetry.io/docs/specs/semconv/gen-ai/) where they
apply. If the tracing backend buffers data, flush or shut down
`LittleGhost::Instrumentation` before the application exits.

See [Running in Production](production.md) for startup, shutdown, and
observability, [MCP](mcp.md) for operations published by remote servers,
and [Workspaces and Sandboxes](sandboxing.md) for child processes and files.
