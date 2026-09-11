# Core Concepts

Start with an Agent: a Ruby class that gives a model instructions and operations
it can call. This guide builds on the help center example in
[Getting Started](getting_started.md), including its `HelpCenterLookupTool` and
provider setup.

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  system_prompt "Answer customer questions clearly."
  tools HelpCenterLookupTool
end

run = CustomerSupportAgent.ask("What is the refund policy?")
run.response
```

From there, add only what the work needs. Give the agent a tool. Let it ask a specialist for help. Or coordinate several agents while the rest of your application keeps making the same call.

## An Agent carries a request through to an answer

An **Agent** defines one model-driven behavior. It chooses the model, supplies the instructions and tools, and carries one request through to an answer.

The model can answer immediately or ask to call a Tool. LittleGhost runs the
Tool and sends its result back to the model, which can continue working. That
back-and-forth is the **model loop**.

The class holds the behavior you want to reuse. Each call brings its own input, history, context, settings, and attachments. Request data never needs to live on the class.

```text
CustomerSupportAgent
├── model selection
├── system prompt
├── HelpCenterLookupTool
└── limits and optional capabilities
```

An Agent can return text or checked, structured data. You can add streaming,
saved conversations, or callbacks later. None of them are required to begin.

## A Tool connects the model to Ruby

A **Tool** is one focused thing an agent can ask your application to do. It has a name, a description, an input schema, and the Ruby code that does the work.

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
      .fetch(input.fetch("topic"))
  end
end
```

LittleGhost checks the model's arguments, calls the Tool, and gives the result
back to the model. The schema checks shape, not permission. Check permission
inside the Tool using identity and account information from your application.

[Tools](tools.md) follows that path from model input to application code,
including run-scoped bindings, concurrency, retries, and sandbox delegation.

## A Run records one request

Every `.ask` or `.stream_ask` creates a **Run**. Think of it as the record of one trip through LittleGhost. It opens what the request needs, records how the work ended, and closes the resources it owns.

```ruby
run = CustomerSupportAgent.ask("What is the refund policy?")

run.completed? # => true
run.response
# One possible response: Refunds are available within 30 days.
run.usage      # Token counts reported by the model provider.
run.result     # => the complete LittleGhost::RunResult
```

The Agent defines reusable behavior; the Run records what happened this time.

The final **RunResult**, available through `run.result`, holds the answer and
details such as token usage. Its `output` returns text unless you configured
the Agent to return checked data, such as a hash of named fields. See
[Structured Results and Content](structured_outputs_and_content.md) for that
alternative. Use `run.response` when you want the text answer.

When a Tool needs to know who is asking, pass information from your application
with the request. [Tools](tools.md) explains how it reaches the Tool. When a
conversation should continue across requests, a **Session** saves its history
and working state; [Running in Production](production.md) covers that setup.

## An Assembly can look like one Agent

One model loop is not always enough. LittleGhost calls any unit that a caller can invoke like an Agent an **Assembly**.

An Agent is the smallest Assembly. Workflow, Swarm, and Graph coordinate several participants while preserving the same entrypoints:

```ruby
CustomerSupportAgent.ask(question)
ResponseWorkflow.ask(question)
ProblemSolverSwarm.ask(question)
SupportFlowGraph.ask(question)
```

That shared calling style is what makes composition feel natural. A controller, job, or CLI does not need to know whether one Agent answered or a whole support process worked together.

## Choose who controls the next step

The coordination types differ mainly in who decides what happens next:

| Need | Choose | Who controls the next step? |
| --- | --- | --- |
| One model-driven behavior | Agent | The active model loop |
| A model should delegate a named task | Subagent | The parent model |
| Ruby should enforce ordering or branching | Workflow | The workflow's Ruby code |
| Specialists should choose permitted handoffs | Swarm | The active agent |
| Allowed routes should be visible in advance | Graph | Declared nodes and edges |

### Subagents bring in a specialist

A **subagent** is a specialist that a parent Agent can call for help. The parent model chooses when to delegate, reads the result, and then continues its own answer.

The examples below omit the specialist Agent definitions. Each is an Agent
class like `CustomerSupportAgent`, with instructions and tools suited to its
task. [Compose Agents](assemblies.md) expands on these coordination patterns.

```ruby
class CustomerSupportAgent < LittleGhost::Agent
  model "openrouter:openai/gpt-5.6-luna"
  subagent ResearchAgent, kind: "research"
end
```

Use a subagent when delegation is part of one model's decision-making. Use a Workflow when application code must guarantee that a step happens.

### Workflows make Ruby the coordinator

A **Workflow** coordinates work with ordinary Ruby. Its `perform` method can call an Agent or another Assembly, read a result, choose a branch, or run independent steps together.

`invoke` prepares a participant's call without running it yet. Read `.output`
to run it and use its answer in Ruby. Return the final `invoke` call to use
that participant's answer as the Workflow's result.

```ruby
class ResponseWorkflow < LittleGhost::Workflow
  private

  def perform
    research = invoke(ResearchAgent).output
    invoke CustomerSupportAgent, input: <<~PROMPT
      #{input.text}

      Research:
      #{research}
    PROMPT
  end
end
```

In this example, research finishes before the support Agent begins. `input.text`
is the original question; the Workflow adds the research to it.

You can also inspect an answer before choosing it as the final result, without
running the participant again. [Compose Agents](assemblies.md) shows how, along
with ways to display each participant's progress.

Workflow children receive the caller's history and application context by default. Pass `history: []`, `context: {}`, or redacted values when a participant should receive less.

### Swarms let agents hand work to one another

A **Swarm** is a group of Agents that can hand work to one another. One member is active at a time. It can answer the caller or choose one of its allowed specialists.

```ruby
class ProblemSolverSwarm < LittleGhost::Swarm
  member TriageAgent
  member BillingAgent
  member AccountAgent

  start TriageAgent
  handoff TriageAgent, to: [BillingAgent, AccountAgent]
end
```

A Swarm is intentionally agent-to-agent. Its members are Agents, not other
kinds of Assembly. Caller history and application context stay hidden unless a
member opts in. A handoff message comes from another model, so a receiving
Agent should use it as context rather than proof that an action is permitted.

### Graphs make routes visible

A **Graph** lays out the steps and routes through a task. Each named **node**
runs an Agent or another Assembly. An **edge** says which node can run next.

```ruby
class SupportFlowGraph < LittleGhost::Graph
  node :triage, TriageAgent
  node :billing, BillingAgent
  node :general, CustomerSupportAgent
  node :respond, CustomerSupportAgent

  start :triage
  edge :triage, :billing do |state|
    state.result(:triage).output == "billing"
  end
  edge :triage, :general
  edge :billing, :respond
  edge :general, :respond
  finish :respond
end
```

Here, `TriageAgent` is expected to answer `billing` for billing questions.
That answer selects the conditional billing route. Otherwise, the unconditional
general route is the fallback; it does not run alongside the billing route.

Graph nodes receive the original task and results from the nodes immediately
before them. They do not receive caller history or application context unless
their declarations opt in. [Compose Agents](assemblies.md) explains parallel
routes, joins, input mapping, and data boundaries.

## One result, even when several agents help

Every assembly produces the same top-level `Run` and final `RunResult`. Composite assemblies also keep a size-limited record of the participants that ran:

```ruby
run = SupportFlowGraph.ask("Why was I charged twice?")

run.response
run.result.steps
run.result.trajectory.transitions
```

This record shows which participants ran. [Compose Agents](assemblies.md)
explains builders, detailed routing records, and live events from nested Agents.

## Handle the outcome

An Agent or coordinated Assembly normally returns a Run even when the work
fails. Check its outcome before using the answer:

| What happened | Run outcome | What to inspect |
| --- | --- | --- |
| Work completed | `completed` | `run.response` or `run.result` |
| Model, provider, or assembly execution failed | `failed` | `run.error` |
| The deadline stopped work | `partial` | Any response produced so far |
| Cancellation stopped work | `cancelled` | No response is returned |

A Tool error need not end the Run: LittleGhost can give the model a safe error
result so it can try again. Unexpected exception messages stay in application
diagnostics rather than going to the model.

Some failures raise Ruby exceptions instead of returning a Run, including
invalid setup before work starts and failures while closing resources or
delivering events. [Running in Production](production.md) covers error handling
and shutdown; [Run](rdoc-ref:LittleGhost::Run) lists the streaming events for
each outcome.

The pieces now fit together: Agents define behavior. Tools connect them to Ruby. Runs record one execution. Assemblies let the system grow without changing the caller.

Continue with [Models and Providers](models_and_providers.md) to choose model
targets and configure provider connections. When you need several agents to
work together, [Compose Agents](assemblies.md) builds on the same concepts.
