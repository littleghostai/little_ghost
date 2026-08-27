# Basic agent

This single-file example asks an Agent to write a friendly customer greeting.

## Setup and run

Requires Ruby 3.3 or newer and [Ollama](https://ollama.com/download). Install
Ollama, make sure its local server is running, and pull
[`qwen3.8`](https://ollama.com/library/qwen3.8):

```sh
$ ollama pull qwen3.8
$ bundle install
$ ruby customer_support_agent.rb
```

No API key is needed. LittleGhost connects to Ollama at
`http://localhost:11434`. The Gemfile loads LittleGhost from the repository
root, so run these commands from `examples/basic_agent` in a source checkout.
