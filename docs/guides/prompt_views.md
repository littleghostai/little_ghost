# Prompts as Views

Keep growing Agent instructions readable by moving them into a **prompt view**:
an ERB file that LittleGhost finds and renders for the Agent. The Agent prepares
any application values the prompt needs, while the view holds the instructions
sent to the model.

## Start with the inline prompt

The Agent from Getting Started keeps its first instruction close to the model:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  system_prompt "Answer customer questions clearly and concisely."
end
```

Inline prompts are a good fit while the whole instruction is one thought.

## Move a growing prompt into a view

Remove `system_prompt` from the class:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  tools HelpCenterLookupTool, OrderStatusTool
end
```

Then create `app/prompts/customer_support/system_prompt.erb`:

```erb
You help customers understand their orders and account.

Answer clearly and concisely.
Never invent company guidance. Check the help center when policy matters.
Use the order status tool before making a claim about a private order.
```

That is enough. LittleGhost turns `CustomerSupportAgent` into the logical path
`customer_support` and looks for
`app/prompts/customer_support/system_prompt.erb`.

The prompt is still a system instruction sent to the selected model provider.
Keeping it in a view improves organization; it does not keep the content inside
your process.

## Prepare application values with Ruby

Define `system_prompt` as an instance method when the view needs values from
your application. Assign those values to instance variables:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  def system_prompt
    @company_name = "Northstar"
    @policy_version = SupportPolicy.current_version
  end
end
```

LittleGhost calls the method before it renders the view. The instance variables
are available there by the same names:

```erb
You are a customer support agent for <%= @company_name %>.
Follow support policy <%= @policy_version %>.
Answer clearly and concisely.
```

If you know Rails controllers, the pairing is familiar: the method prepares
values, and the ERB file presents them. The method's return value is ignored. If
it raises an exception, the Run fails in the usual way.

An inline `system_prompt` declaration still takes precedence over a view. Remove
the inline declaration when you want LittleGhost to call the instance method and
render `system_prompt.erb`.

Subclass actions can call `super` before adding their own values:

```ruby
class BillingSupportAgent < CustomerSupportAgent
  def system_prompt
    super
    @billing_region = "US"
  end
end
```

Prompt views also receive three built-in local variables: `invocation` for the
current request, `run` for its lifecycle, and `agent` for the run-scoped Agent.
Use them when an instruction genuinely depends on the current request. Keep the
customer's wording in the caller message unless it belongs in the system
instruction.

Every rendered value may be sent to the model provider. Put only data that
belongs in the prompt into the view.

## Share a small partial

Partials keep repeated instructions in one place. Create `app/prompts/shared/_voice.erb`:

```erb
Use a warm, direct voice for <%= @company_name %>.
Prefer one clear next step over a long list of possibilities.
```

Render it from the Agent's system view:

```erb
You are a customer support agent for <%= @company_name %>.

<%= partial "shared/voice" %>
```

The underscore marks a partial. Partials share the Agent's instance variables,
so `@company_name` remains available without extra wiring.

Use an explicit local for a value that belongs only to one partial. For example,
create `app/prompts/shared/_closing.erb`:

```erb
Offer one clear next step for <%= audience %>.
```

Then pass `audience` when you render it:

```erb
<%= partial "shared/closing", locals: {audience: "account owners"} %>
```

Locals do not flow into nested partials unless you pass them again.

## Keep repeated renders predictable

LittleGhost calls `system_prompt` once for each file-backed prompt render. Each
call starts with the instance variables captured after LittleGhost's
`after_initialize` callbacks finish. Values left behind by a later callback,
Tool, or earlier render do not become prompt assigns by accident.

After preparing the view, LittleGhost restores the Agent's live instance
variables. The objects assigned to the view are still ordinary Ruby objects,
though, so the view sees the same mutable objects. Treat them as read-only, or
duplicate a value before assigning it when the template needs an isolated copy.

For state that should change across invocations, read from `run`, a session, or
an application object in `system_prompt` instead of relying on an earlier
prompt render.

## Choose a different template path

Most named Agents can rely on their conventional path. Use `system_template` when a class should read a differently named view:

```ruby
class BillingSupportAgent < LittleGhost::Agent
  system_template "customer_support/billing"
end
```

LittleGhost chooses one prompt source in this order:

1. An inline `system_prompt`
2. An explicit `system_template`
3. The Agent's conventional `system_prompt.erb` view

Applications can add prompt lookup roots through `Configuration#prompt_paths`.
Earlier roots win, so an application can override a view from a shared prompt
package.

## Override LittleGhost's framework prompts

LittleGhost also uses prompt views for its own model-facing language: Tool
descriptions, structured-result repair requests, context summaries, code-mode
instructions, and similar framework messages. The gem includes a complete
default catalog under the `little_ghost/` namespace. Inspect it from an
application without searching the gem's source:

```sh
$ little_ghost prompts list
$ little_ghost prompts list structured_output
$ little_ghost prompts list structured_output/repair
$ little_ghost prompts show structured_output/repair/request
```

The bare `list` command shows feature groups with template counts. Pass a group
prefix to browse its immediate children, or use `list --all` to print every
canonical key. Framework prompt keys follow `feature/component/purpose`, with
`feedback` for conditions the model can correct and `errors` for operational
failures. For example, built-in Tool descriptions live under
`tools/built_in`, while JSON Schema feedback lives under
`tools/validation/schema`.

`show` prints the bundled ERB source. Every bundled template starts with a
structured ERB comment that explains where LittleGhost renders it, its locals,
and any formatting constraints. These headers use `<%# ... -%>`, so neither the
comment nor its trailing newline enters the rendered prompt. Each interior line
also starts with `#` so Ruby-aware editors recognize the whole header as a
comment. A `#` line outside `<%# ... -%>` and an HTML comment are output text and
would be sent to the model.

Copy one template into the default application prompt root before editing it:

```sh
$ little_ghost prompts copy structured_output/repair/request
```

That creates
`app/prompts/little_ghost/structured_output/repair/request.erb`. Use `--root` when the
application configures a different prompt root:

```sh
$ little_ghost prompts copy structured_output/repair/request --root config/prompts
```

Use `--agent` when one Agent needs different wording from the rest of the
application. Pass the Agent's logical path, which is its underscored class name
without the `Agent` suffix:

```sh
$ little_ghost prompts copy structured_output/repair/request --agent customer_support
```

That creates
`app/prompts/customer_support/little_ghost/structured_output/repair/request.erb`.
Namespaced classes use a namespaced logical path, such as
`Admin::CustomerSupportAgent` becoming `admin/customer_support`.

Copy the complete catalog when an application deliberately wants to own every
piece of framework wording:

```sh
$ little_ghost prompts copy --all
```

Copy commands refuse to overwrite any existing destination. With `--all`, the
command checks every destination before it starts writing. Copied templates
retain their invisible documentation headers so the override remains
self-explanatory in the application.

For every framework prompt that applies to an Agent invocation, LittleGhost
uses the first matching template in this order:

1. An invocation-specific `TrustedPath` root
2. The Agent-scoped directory inside a configured prompt root
3. The runtime-wide directory inside a configured prompt root
4. The template bundled with LittleGhost

Each root keeps the same `little_ghost/<key>.erb` namespace. Agent scope inserts
the logical path before that namespace.

Runtime-wide overrides normally live in the default `app/prompts` root. Add or
replace configured roots when the application uses another location:

```ruby
LittleGhost.configure do |config|
  config.prompt_paths = ["config/prompts", "app/prompts"]
end
```

The uncommon invocation-specific layer is explicit because it can change model
instructions for only one call:

```ruby
campaign_prompts = LittleGhost::TrustedPath.new(
  path: File.expand_path("config/campaign_prompts", __dir__)
)

CustomerSupportAgent.ask(
  "Where is my order?",
  template_paths: [campaign_prompts]
)
```

The invocation root would contain
`little_ghost/structured_output/repair/request.erb`, just like a runtime root. Direct
`LittleGhost.generate` calls accept the same `template_paths:` option.

Only application code should construct a `TrustedPath`. Never build its path
from request parameters, model output, Tool arguments, or other untrusted input.
The wrapper records an application trust decision; it does not sanitize the
directory or restrict what ERB can execute.

Framework templates control model-facing language, not protocol roles, Tool
names, schemas, validation behavior, security checks, or execution limits. A
required template also cannot render as blank. LittleGhost is pre-1.0; template
keys and their documented locals are maintained on a best-effort basis until
1.0, so review release notes and copied overrides when upgrading.

## Treat views as application code

Prompt views run as ERB inside the Ruby process and can call Ruby. Keep prompt
directories with the rest of your application code rather than letting a
request choose one.

`TrustedPath` is available for the uncommon case where application code selects
a request-specific root. It marks that choice explicitly; it does not inspect
or restrict the directory.

## Build request-specific input in a Workflow

A prompt view defines reusable instructions for one Agent. A Workflow may still
build request-specific input for that Agent:

```ruby
invoke CustomerSupportAgent, input: <<~MESSAGE
  #{input.text}

  Verified research:
  #{research}
MESSAGE
```

The Workflow is composing this request. `CustomerSupportAgent` still receives
its own system prompt view when it runs.

Continue with [Tools](tools.md) to give those Agents application capabilities
while keeping model input, trusted context, and delegated sandbox operations
distinct.
