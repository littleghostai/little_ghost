# Choose Models and Providers

An Agent needs a model target: a configured provider connection plus the
provider's model identifier. You can write that target directly while getting
started, then give it an application-facing name when several Agents share it.

## Start with one direct target

A direct target has the form `connection:model-id`:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  system_prompt "Answer customer questions clearly and concisely."
end
```

`openrouter` names a connection configured by the application. The remainder
is the model identifier understood by that provider. This is a good fit when
one Agent owns one stable choice.

## Give shared choices a role

A model role lets several Agents share a choice without knowing its provider
or model identifier:

```ruby
LittleGhost.configure do |config|
  config.providers = {
    primary: {
      adapter: :openrouter,
      api_key: ENV.fetch("OPENROUTER_API_KEY")
    }
  }
  config.models = {
    customer_support: {
      target: "primary:openai/gpt-5.6-luna",
      settings: {temperature: 0.2}
    }
  }
  config.default_model = :customer_support
end

class CustomerSupportAgent < LittleGhost::Agent
  model :customer_support
end
```

Here `customer_support` is the role, `primary` is the connection, and
`openrouter` is the adapter. You can move the role to another model or provider
without editing the Agent.

Profile settings are defaults. An individual call can override them:

```ruby
run = CustomerSupportAgent.ask(
  "Explain the refund decision.",
  settings: {temperature: 0.0}
)
```

Build these settings in application code instead of passing request parameters
through unchanged. Settings can affect cost, latency, and model behavior.

## Connect the provider you chose

Connections may live in an initializer or in the conventional files under
`config/little_ghost`. [Provider Support](providers.md) has copyable settings
for each built-in adapter, compatible endpoints, Ollama, and LM Studio.

Keep credentials in your application's secret manager. Agents refer to a role
or configured connection; they don't need to contain credentials. If your
application obtains short-lived credentials at runtime, configure a credential
resolver that returns them for the selected connection.

> **Safety note:** The selected provider may receive system instructions,
> caller input, conversation history, Tool results, schemas, and attachments.
> Choose a provider that is appropriate for that data, and keep credentials and
> provider endpoints under application control.

## Choose a role for each request

An Agent can select between configured roles using its `Invocation`:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model do |invocation|
    invocation.fetch(:premium_account, false) ? :premium_support : :customer_support
  end
end
```

Set `premium_account` from application state when creating the invocation. If
a public request offers a model choice, map that choice to one of your
configured roles rather than accepting an arbitrary provider target.

Trusted application code may also declare a selection inline:

```ruby
class ResearchAgent < LittleGhost::Agent
  model(
    provider: "primary",
    model: "openai/gpt-5.6-luna",
    reasoning_effort: "high"
  )
end
```

`provider` still names a configured connection. The inline settings change the
selection; they don't create a new connection.

## Use model capabilities

`LittleGhost::ModelResolver` turns a role or target into an executable
`LittleGhost::Model`. Its catalog describes capabilities such as supported
input types, output limits, and structured results. LittleGhost uses that
information to reject unsupported attachments, constrain output limits, and
choose a structured-result strategy.

Provider capabilities can change. Handle failed Runs and provider errors even
when the catalog says a feature is supported.

Most application code does not call the resolver directly. Declaring an
Agent's model, or passing `model:` to generation or embedding, resolves the
selection for you. Inspect model details when an interface needs to explain
limits or your application wants to check an attachment before sending it.

## Call a model without an Agent

Some application work needs one model response rather than an Agent. Use
`LittleGhost.generate` for tasks such as classification, extraction, or
rewriting when your application already owns the surrounding workflow:

```ruby
response = LittleGhost.generate(
  model: :customer_support,
  messages: [
    {role: :system, content: "Classify the request."},
    {role: :user, content: "My transfer is still pending."}
  ],
  settings: {temperature: 0}
)

response.output
response.usage.total_tokens
```

The operation returns a `LittleGhost::RunResult`, the same result type returned
by an Agent invocation. Application code can read `output`, `usage`, and the
final message in the same way. Plain generation makes one model request without
starting an Agent or creating a Run.

Pass `result_schema:` when application code needs checked JSON. [Structured
Results and Content](structured_outputs_and_content.md) covers strict schemas,
provider strategies, repair behavior, and the application checks that still
belong outside the schema.

## Create embeddings

Use `LittleGhost.embed` when your application needs numeric representations for
search, clustering, or another similarity-based feature:

```ruby
response = LittleGhost.embed(
  model: "primary:openai/text-embedding-3-small",
  inputs: ["Reset a password", "Track a transfer"]
)

response.vectors.length # => 2
response.dimensions
response.usage.input_tokens
```

The response keeps vectors in the same order as the inputs. LittleGhost rejects
an incomplete or malformed response instead of returning a partial batch.
Embedding text is sent to the selected provider, so choose one appropriate for
that data. [Provider Support](providers.md) identifies adapters with embedding
support; `LittleGhost::Embeddings::Request` documents settings and request
bounds.

Continue with [Prompts as Views](prompt_views.md) when an Agent's instructions
outgrow one string. See [Structured Results and Content](structured_outputs_and_content.md)
when you need checked result shapes, images, or documents.
