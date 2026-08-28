# frozen_string_literal: true

require_relative "../../little_ghost" unless defined?(LittleGhost::CodeMode::Engine)
require_relative "ruby/catalog"
require_relative "ruby/session"

module LittleGhost
  module CodeMode
    # Runs model-written Ruby in a fresh sandboxed process.
    #
    # Tool calls cross a bounded protocol to the trusted parent Broker. The
    # engine uses only Ruby's standard library and adds no runtime dependency.
    #
    #   LittleGhost.configure do |config|
    #     config.code_mode = {engine: :ruby, sandbox: :native}
    #   end
    class RubyEngine < Engine
      # Resource, Tool-call, and program limits applied when the application
      # does not override them.
      DEFAULT_LIMITS = {
        source_bytes: 1_000_000,
        output_bytes: 1_000_000,
        memory_bytes: 64 * 1024 * 1024,
        wall_seconds: 3_600,
        cpu_seconds: 10,
        file_bytes: 1_000_000,
        programs: 8,
        tool_calls: 1_000,
        concurrency: 8,
        cleanup_seconds: 5
      }.freeze

      # Returns the +:ruby+ language identifier.
      def language = :ruby

      # Builds Ruby usage instructions and method declarations for +catalog+.
      def instructions(catalog:, prompts: nil)
        renderer = prompts || ->(key, **locals) { FrameworkPrompts.new.render(key, locals:) }
        renderer.call("code_mode/ruby/instructions", declarations: Ruby::Catalog.new(catalog).declarations)
      end

      # Opens a Ruby Session with engine defaults merged with +limits+.
      # Unsupported limit keys raise ArgumentError.
      def open_session(broker:, sandbox_factory:, limits: {}, framework_prompt_scope: {})
        Ruby::Session.new(
          broker:,
          sandbox_factory:,
          subprocess_policy: method(:allow_subprocesses_for),
          limits: normalize_limits(limits, defaults: DEFAULT_LIMITS),
          framework_prompt_scope:
        )
      end
    end

    CodeMode.register_engine(:ruby, RubyEngine)
  end
end
