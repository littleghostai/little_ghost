# Getting Started

In this guide, you'll run an agent, connect it to a small help center, and stream its answer. The whole feature stays in ordinary Ruby.

## Install the gem

LittleGhost requires Ruby 3.3 or newer. Add the gem to your `Gemfile`, install it, and set a provider credential:

```ruby
gem "little_ghost"
```

```sh
$ bundle install
$ export OPENROUTER_API_KEY="..."
```

Use your application's secret manager outside a local shell, and never commit provider credentials.

This guide uses OpenRouter, a service that sends requests to your chosen AI
model. Set `OPENROUTER_API_KEY` to a key from your OpenRouter account. Prefer another hosted
provider or a local model server? Start with [Provider Support](providers.md).

## See your first answer

Create `customer_support_agent.rb`:

```ruby
require "little_ghost"

class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  system_prompt "Answer customer questions clearly and concisely."
end

run = CustomerSupportAgent.ask("Can I change the address on my order?")

if run.completed?
  puts run.response
else
  warn "Support request ended as #{run.outcome}: #{run.error&.class}"
end
```

`model` selects the service and model to call. `system_prompt` supplies the
instructions the model follows on each request. Run the file with your bundle:

```sh
$ bundle exec ruby customer_support_agent.rb
```

`CustomerSupportAgent.ask` creates a `LittleGhost::Run` for this request. When the work finishes, the Run holds the outcome and response.

The inline prompt keeps this first example visible in one place. When the instructions grow, [Prompts as Views](prompt_views.md) moves them into a conventional ERB file without adding setup to the Agent.

The selected external provider may receive system instructions, caller input, conversation history, tool results, and attachments. Model wording can vary, so use application code—not a prompt—when a rule must always hold.

## Connect the agent to your application

The first agent can answer general questions. A **tool** gives it a focused
operation backed by your Ruby code. Add this class after the `require` line,
before `CustomerSupportAgent`:

```ruby
class HelpCenterLookupTool < LittleGhost::Tool
  HELP_CENTER_ENTRIES = {
    "refunds" => "Refunds are available within 30 days of purchase.",
    "shipping" => "Standard shipping takes three to five business days."
  }.freeze

  description "Look up a help center entry by topic."
  input_schema(
    type: "object",
    properties: {
      topic: {type: "string", enum: HELP_CENTER_ENTRIES.keys}
    },
    required: ["topic"],
    additionalProperties: false
  )

  def call(input)
    HELP_CENTER_ENTRIES.fetch(input.fetch("topic"))
  end
end
```

`input_schema` describes the arguments the model may supply. Here, `topic` must
be one of the help center's keys. Replace the Agent definition and the call at
the end of the file with these:

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  description "Answers customer support questions."
  model "openrouter:openai/gpt-5.6-luna"
  system_prompt <<~PROMPT
    Answer clearly and do not invent company guidance.
    Check the help center before stating company guidance.
  PROMPT
  tools HelpCenterLookupTool
end

run = CustomerSupportAgent.ask(
  "I bought an item two weeks ago. Can I get a refund?"
)

run.response
# One possible response:
# Refunds are available within 30 days, so your purchase is eligible.
```

LittleGhost checks the model's arguments before it calls
`HelpCenterLookupTool#call`. The Tool's result then becomes context for the
model.

> **Safety note:** The schema checks arguments, not permission. This example
> reads a public help center. Before a Tool returns private data or changes
> anything, check permission using the user and account identified by your
> application—not values supplied by the model. [Tools](tools.md) shows how to
> pass that information to a Tool.

## Stream the same agent

Use `.stream_ask` when a console, HTTP response, or user interface should receive
the answer as it is written. Replace the `.ask` call with the following code.

Each `:agent_stream` event contains the Agent's progress and a `source` that
identifies which Agent produced it. The source check below selects the Agent
you called directly: `/root` with no enclosing assembly steps. `:text_delta`
contains the next piece of its answer.

```ruby
stream = CustomerSupportAgent.stream_ask("Can I get a refund?")

run = stream.each do |event|
  case event.type
  when :agent_stream
    source = event.data.fetch(:source)
    next unless source.agent_path == "/root" && source.assembly_path.empty?

    progress = event.data.fetch(:event)
    print progress.data.fetch(:text) if progress.type == :text_delta
  when :run_error
    warn event.data.fetch(:message)
  end
end

run.response # The completed answer, separate from live progress.
warn run.error.class.name if run.failed?
```

When enumeration finishes, `.each` returns the Run with the final outcome and
complete response. You can display progress and still read the finished answer.

If you later add other Agents, their progress arrives in the same stream. Keep
the source check when your audience should see only this Agent's text. See
[Compose Agents](assemblies.md) to display several participants.

## Give the code a home

LittleGhost does not require an application layout. Keep definitions beside related application code, or use these optional conventions:

```text
app/
├── agents/
│   └── customer_support_agent.rb
├── assemblies/
│   └── response_workflow.rb
├── prompts/
│   └── customer_support/
│       └── system_prompt.erb
└── tools/
    └── help_center_lookup_tool.rb
```

To generate this layout for a standalone application, install the gem and run
`little_ghost new`:

```sh
$ gem install little_ghost
$ little_ghost new MyApp
$ cd my_app
$ export OPENROUTER_API_KEY="..."
$ bin/little_ghost console
```

The generator creates `my_app` with one Agent, a prompt view, configuration,
the conventional application directories, an installed bundle, and a local
LittleGhost command. `bin/little_ghost console` uses the generated
application's bundle, loads its configuration and classes, and then starts
IRB.

The source repository also contains a complete
[single-file Agent](https://github.com/littleghostai/little_ghost/tree/main/examples/basic_agent)
and a
[coding harness](https://github.com/littleghostai/little_ghost/tree/main/examples/coding_harness)
that shows a larger application with several agents and tools for working
with files.

You now have the smallest useful LittleGhost application: one Agent, one Tool, and one familiar Ruby call.

When the feature grows, the calling style stays the same. An **assembly** lets one or more agents work as a unit while keeping `.ask` and `.stream_ask`. Read [Core Concepts](core_concepts.md) next and grow this Agent into a larger system.
