# LittleGhost coding harness

This coding harness plans a change, edits a project, checks its work, and loops
when the check finds a problem. It demonstrates LittleGhost Agents, prompt
views, Tools, a Graph, a Workspace, and a native Sandbox.

## Setup

Requires Ruby 3.3 or newer, [Ollama](https://ollama.com/download), and a native
sandbox: Seatbelt on macOS or
[Bubblewrap](https://github.com/containers/bubblewrap) on Linux. Install Ollama,
make sure its local server is running, and pull
[`qwen3.8`](https://ollama.com/library/qwen3.8):

```sh
$ ollama pull qwen3.8
$ bundle install
```

No API key is needed. LittleGhost connects to Ollama at
`http://localhost:11434`. The Gemfile loads LittleGhost from the repository
root, so run setup from `examples/coding_harness` in a source checkout.

## Run

Pass an existing project directory, or omit it to work in the current
directory:

```sh
$ bin/coding_harness /path/to/project
```

> **Safety note:** The model can read, overwrite, and delete files anywhere in
> the selected project and can run commands there. Use a clean version-controlled
> or disposable checkout without secrets, and review its changes before keeping
> them.

Enter one coding instruction per prompt; enter `exit` or `quit` (or press Ctrl-D)
to stop. Each instruction starts a fresh run, while edits remain in the project.

Like an application created by `little_ghost new`, this example includes a
bundle-aware local command. Use it to open a console with the configuration and
classes under `app/` already loaded:

```sh
$ bin/little_ghost console
```

Commands run without network access in an isolated root filesystem. The
selected project is the only host directory they can read or write, alongside
the minimal system paths supplied by the native sandbox for running commands.
The parent LittleGhost process sends project contents, prompts, and tool output
to the local Ollama server as part of the agent conversation.
