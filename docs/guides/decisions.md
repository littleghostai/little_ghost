# Decisions

Use a decision model when an application needs typed answers to a small set of
questions. `LittleGhost.decide` returns the answers and token usage without
starting an Agent or creating a Run. Jev supports Choice, Score, and Noul
(yes/no probability) questions:

```ruby
result = LittleGhost.decide(
  model: "primary:typesafe/jev-latest",
  state: {payout_status: "failed", failed_days: 3},
  questions: [
    {id: "route", type: :choice, instructions: "Choose a route", criteria: ["review", "approve", "decline"]},
    {id: "urgent", type: :noul, instructions: "Does this need same-day attention?"}
  ]
)

result.answers.fetch("route").choice
result.answers.fetch("urgent").noul
```

Choice answers contain the selected label. Noul answers contain the
probability of yes from 0 to 1. Score answers contain a probability-weighted
value across the declared levels.

For reusable decisions, declare questions once on a `Decision` class. A class
can mix question types:

```ruby
class ApplicationTriage < LittleGhost::Decision
  model "primary:typesafe/jev-latest"
  choice :route, instructions: "Choose a route", criteria: ["review", "approve", "decline"]
  noul :urgent, instructions: "Does this need same-day attention?"
  score :quality, instructions: "Rate the quality", criteria: ["accuracy", "completeness"]
end

application_state = {payout_status: "failed", failed_days: 3}
result = ApplicationTriage.ask(application_state)
result.answers.fetch("quality").score
```

The class-level `.ask` and an instance's `#ask` return
`LittleGhost::DecisionResult`. Read a typed value with
`LittleGhost::DecisionAnswer#value` or its type-specific reader (`choice`,
`noul`, or `score`).

The selected provider receives the state and question text. Choose a provider
that is appropriate for that data.

Decisions require a TypeSafe connection or an OpenRouter connection configured
for a Jev decision endpoint. Other providers raise
`UnsupportedModelOperationError`. See [Provider Support](providers.md) for
connection setup and [Models and Providers](models_and_providers.md) for model
targets, shared roles, and capabilities.
