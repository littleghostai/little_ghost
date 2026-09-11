# Build AI features that feel at home in Ruby

LittleGhost is a Ruby library for adding AI features to an existing application
or building a dedicated AI service. An **agent** combines a model with
instructions and Ruby operations it can call. Agents can work together in an
**assembly**, which your application calls like a single agent.

> **Using a coding agent?** Start with
> [`llms.txt`](https://littleghostai.org/llms.txt) for a concise map
> of the guides and API. [`llms-full.txt`](https://littleghostai.org/llms-full.txt)
> contains the complete documentation in one file.

With the gem installed and `OPENROUTER_API_KEY` set, start with one class:

```ruby
require "little_ghost"

class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  system_prompt "Answer customer questions clearly and concisely."
end

run = CustomerSupportAgent.ask("Draft a friendly greeting for a customer.")
run.response
# One possible response: Hi! How can I help today?
```

That definition is a complete Agent. LittleGhost makes the model call, tracks
usage, supports streaming, and closes request resources. Add a Tool for
application capabilities or an Assembly as the work grows.

Model requests may send system instructions, caller input, conversation history,
Tool results, and attachments to the selected provider. Model wording can vary
between runs. [Models and Providers](docs/guides/models_and_providers.md) explains
how to choose where each Agent sends its requests.

## Install the gem

LittleGhost requires Ruby 3.3 or newer. Add it to your bundle and provide a provider credential:

```ruby
gem "little_ghost"
```

```sh
$ bundle install
$ export OPENROUTER_API_KEY="..."
```

The introductory guides use OpenRouter so you can start with one key. Prefer
another hosted provider or a local Ollama or LM Studio server? See [Provider
Support](docs/guides/providers.md).

LittleGhost runs inside your Ruby process. Use it from a controller, job, CLI,
or service.

## Generate a small application

Generate a conventional standalone application:

```sh
$ gem install little_ghost
$ little_ghost new MyApp
$ cd my_app
$ export OPENROUTER_API_KEY="..."
$ bin/little_ghost console
```

The generator installs the bundle. `bin/little_ghost console` runs that
bundle's LittleGhost version and loads the application before starting IRB.

The source checkout also includes a complete
[single-file Agent](https://github.com/littleghostai/little_ghost/tree/main/examples/basic_agent)
and
[coding harness](https://github.com/littleghostai/little_ghost/tree/main/examples/coding_harness),
both configured for local Ollama.

## Give an agent real capabilities

Tools let an agent call focused parts of your application:

```ruby
class HelpCenterLookupTool < LittleGhost::Tool
  description "Look up a help center entry by topic."
  input_schema(
    type: "object",
    properties: {topic: {type: "string"}},
    required: ["topic"],
    additionalProperties: false
  )

  def call(input)
    {"refunds" => "Refunds are available within 30 days."}
      .fetch(input.fetch("topic"), "No help center entry found.")
  end
end

class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  system_prompt "Check the help center before stating company guidance."
  tools HelpCenterLookupTool
end
```

The schema checks the shape of the input. Your Ruby code still decides whether
the operation is allowed. The result goes back to the model as context.

An ordinary Tool runs in your Ruby process. For operations that need files or
child processes, see [Workspaces and Sandboxes](docs/guides/sandboxing.md).

## Grow without changing the caller

When a task needs several agents, choose how they work together. These example
classes use different coordination styles, but their callers all use `.ask`:

```ruby
CustomerSupportAgent.ask(question)
ResponseWorkflow.ask(question)
ProblemSolverSwarm.ask(question)
SupportFlowGraph.ask(question)
```

Choose the coordination style that matches who should control the next step:

- A **subagent** is a specialist an agent can ask for help.
- A **workflow** uses ordinary Ruby for ordering and branching.
- A **swarm** lets configured agents choose permitted handoffs.
- A **graph** makes allowed routes explicit as nodes and edges.

A Workflow or Graph can contain agents, other assemblies, or both.

```text
request ──> CustomerSupportAgent

request ──> ResponseWorkflow ──> ResearchAgent ──> CustomerSupportAgent

request ──> ProblemSolverSwarm ──> TriageAgent ──handoff──> BillingAgent

request ──> SupportFlowGraph ──> TriageAgent ──edge──> ResponseAgent
```

The result stays familiar too. Every call returns a `Run` with the response,
outcome, usage, and any final error. A coordinated assembly also records which
participants ran. Use `.stream_ask` to watch the work as it happens and choose
which participants to display. [Getting Started](docs/guides/getting_started.md)
shows how to stream an Agent's answer and read the completed result.

LittleGhost is pre-1.0. Pin the gem version and review release notes before
upgrading, because interfaces may change between releases.

## Keep going

- [Getting Started](docs/guides/getting_started.md) takes you from installation to a tool-backed, streaming agent.
- [Core Concepts](docs/guides/core_concepts.md) builds the mental model from Agent to Assembly.
- [Models and Providers](docs/guides/models_and_providers.md) explains targets, shared roles, and per-request model selection.
- [Provider Support](docs/guides/providers.md) has copyable setup for hosted APIs and local model servers.
- [Prompts as Views](docs/guides/prompt_views.md) explains Agent instructions and shared partials, including how to customize LittleGhost's bundled framework prompts.
- [Tools](docs/guides/tools.md) explains how models call focused Ruby operations.
- [MCP](docs/guides/mcp.md) connects agents to operations published through the Model Context Protocol.
- [Structured Results and Content](docs/guides/structured_outputs_and_content.md) covers checked result shapes, images, and documents.
- [Compose Agents](docs/guides/assemblies.md) walks through workflows, swarms, graphs, nesting, and builders.
- [Skills](docs/guides/skills.md) organizes reusable instructions and supporting resources.
- [Workspaces and Sandboxes](docs/guides/sandboxing.md) gives files and child processes a deliberate place to run.
- [Code Mode](docs/guides/code_mode.md) lets a model compose Tools in sandboxed Ruby or optional JavaScript.
- [Integrations](docs/guides/integrations.md) connects Run streams to AG-UI and OpenTelemetry.
- [Running in Production](docs/guides/production.md) covers configuration, saved conversations, supervision, and observability.
- [API reference](rdoc-ref:LittleGhost) provides exact method signatures and ownership rules.

### For contributors

See the [contributing guide](https://github.com/littleghostai/little_ghost/blob/main/CONTRIBUTING.md), [Code of Conduct](https://github.com/littleghostai/little_ghost/blob/main/CODE_OF_CONDUCT.md), and [security policy](https://github.com/littleghostai/little_ghost/blob/main/SECURITY.md).

```sh
$ bundle install
$ bundle exec rake test
$ bundle exec standardrb --no-fix
```

LittleGhost is available under the MIT License.
