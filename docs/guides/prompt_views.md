# Prompts as Views

A short prompt fits nicely inside an Agent class. As the instructions grow, move them into a **prompt view**: an ERB file that LittleGhost finds and renders for the Agent.

This keeps the Agent definition focused. It also gives shared instructions and application values a natural home.

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

That is enough. `CustomerSupportAgent` becomes `customer_support`, so LittleGhost looks for `customer_support/system_prompt.erb` under `app/prompts`.

The prompt is still a system instruction sent to the selected model provider. Keeping it in a view improves organization; it does not keep the content inside your process.

## Prepare application values with Ruby

Define `system_prompt` as an instance method when the view needs values from
your application. Assign them to instance variables, as you would in a Rails
controller action:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  def system_prompt
    @company_name = "Northstar"
    @policy_version = SupportPolicy.current_version
  end
end
```

The instance variables are available in the view:

```erb
You are a customer support agent for <%= @company_name %>.
Follow support policy <%= @policy_version %>.
Answer clearly and concisely.
```

LittleGhost calls the method once, immediately before rendering each file-backed
system prompt. Its return value is ignored. Exceptions stop that invocation and
follow the Run's normal failure handling. Inline prompts take precedence and do
not call the method.

Each action starts with the application assigns established when the Agent
finished initialization. LittleGhost copies that baseline and the current
action's assignments into the separate view context, then immediately restores
the Agent's real state. Callback and tool state from an earlier invocation is
not exposed automatically. Read persistent values through `run`, the session,
or another application object instead of relying on prompt assigns.

Assigned objects cross into the view by reference, as ordinary Ruby objects do.
Treat mutable assigns as read-only while preparing and rendering a prompt, or
duplicate them when the view needs an isolated value.

Subclass actions can call `super` before adding their own values:

```ruby
class BillingSupportAgent < CustomerSupportAgent
  def system_prompt
    super
    @billing_region = "US"
  end
end
```

Prompt views also receive `invocation`, `run`, and `agent`. Reach for those when the instruction truly depends on the current request. Keep user wording in the caller message unless you deliberately want it inside the system instruction.

Every rendered value may be sent to the model provider. Pass only data that belongs in the prompt.

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
so `@company_name` remains available. Ordinary locals are still explicit: pass
them with `locals:` when a partial needs a temporary value that is not an Agent
assign.

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
Earlier roots win, which lets application code override a shared prompt package.

## Treat views as application code

Prompt views run as ERB inside the Ruby process and can call Ruby. Keep prompt
directories with the rest of your application code rather than letting a
request choose one.

`TrustedPath` is available for the uncommon case where application code selects
a request-specific root. It marks that choice explicitly; it does not inspect
or restrict the directory.

## Build request-specific input in a Workflow

A prompt view defines reusable instructions for one Agent. A Workflow may still build request-specific input for that Agent:

```ruby
invoke CustomerSupportAgent, input: <<~MESSAGE
  #{input.text}

  Verified research:
  #{research}
MESSAGE
```

The Workflow is composing this request. `CustomerSupportAgent` still receives its own system prompt view when it runs.

Continue with [Tools](tools.md) to give those Agents application capabilities
while keeping model input, trusted context, and delegated sandbox operations
distinct.
