# LittleGhost examples

Each folder is a complete, runnable application with its own setup instructions.
Both use a local Ollama server and the `qwen3.8` model by default.
Their Gemfiles load LittleGhost from this source checkout, so run them from
their directories inside the repository.

- [`basic_agent`](basic_agent/) is a single-file Agent you run with Ruby.
- [`decision`](decision/) asks typed questions with a reusable `Decision` class and TypeSafe Jev.
- [`coding_harness`](coding_harness/) plans, edits, and checks changes through
  Agents, prompt views, Tools, a Graph, a Workspace, and a native Sandbox.
