# frozen_string_literal: true

module LittleGhost
  # Harnesses run external coding-agent command-line tools, such as Claude
  # Code, Codex, and OpenCode, as bounded subprocesses: inside an isolating
  # Sandbox with the tool's own safeguards off, or on the host with them on.
  #
  # Each harness builds the tool's non-interactive command line, reads its JSON
  # event stream, and returns one Harnesses::Result. Progress arrives as
  # +:harness+ StreamEvent values while the tool works.
  #
  #   harness = LittleGhost::Harnesses.resolve(:claude_code).new(
  #     sandbox: run.sandbox,
  #     executable: "/opt/harnesses/bin/claude",
  #     home_root: :scratch,
  #     defaults: {base_url: "http://127.0.0.1:3130"}
  #   )
  #   request = LittleGhost::Harnesses::Request.new(
  #     prompt: "Add a test for the refund policy lookup.",
  #     budget_usd: 2,
  #     max_turns: 40,
  #     timeout: 900
  #   )
  #   result = harness.run(request) { |event| puts event.data[:event][:kind] }
  #   result.status # => :completed
  #
  # Built-in harnesses are registered as +:claude_code+, +:codex+, and
  # +:open_code+. Use Harnesses::Tool to let an Agent delegate work to them.
  # See the {Harnesses guide}[rdoc-ref:docs/guides/harnesses.md].
  module Harnesses
    @registry = {}
    @mutex = Mutex.new

    class << self
      # Registers +harness+, a Harnesses::Base subclass, under +name+.
      # Registering an existing name replaces it.
      def register(name, harness)
        unless harness.is_a?(Class) && harness <= Base
          raise ArgumentError, "harness must be a LittleGhost::Harnesses::Base subclass"
        end

        @mutex.synchronize { @registry[name.to_sym] = harness }
        harness
      end

      # Returns the harness class registered under +name+. Raises
      # ConfigurationError when no harness has that name.
      def resolve(name)
        @mutex.synchronize { @registry[name.to_sym] } ||
          raise(ConfigurationError, "unknown harness: #{name}")
      end

      # Registered harness names.
      def names
        @mutex.synchronize { @registry.keys }
      end
    end
  end
end

require_relative "harnesses/request"
require_relative "harnesses/result"
require_relative "harnesses/state"
require_relative "harnesses/home_directory"
require_relative "harnesses/host_runner"
require_relative "harnesses/base"
require_relative "harnesses/claude_code"
require_relative "harnesses/codex"
require_relative "harnesses/open_code"
require_relative "harnesses/tool"

LittleGhost::Harnesses.register(:claude_code, LittleGhost::Harnesses::ClaudeCode)
LittleGhost::Harnesses.register(:codex, LittleGhost::Harnesses::Codex)
LittleGhost::Harnesses.register(:open_code, LittleGhost::Harnesses::OpenCode)
