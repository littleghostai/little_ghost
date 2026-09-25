# Decision example

This example uses a `Decision` class to route a failed build and decide
whether it needs immediate attention.

## Setup and run

Requires Ruby 3.3 or newer and an [OpenRouter API key](https://openrouter.ai/):

```sh
$ bundle install
$ export OPENROUTER_API_KEY="..."
$ bundle exec ruby decision.rb
```

The example sends the sample state and question text to OpenRouter's Jev
Decisions endpoint. Replace the sample state with application data only when
that provider is appropriate for it. The Gemfile loads LittleGhost from the
repository root, so run these commands from `examples/decision` in a source
checkout.
