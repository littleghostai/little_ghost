# frozen_string_literal: true

module LittleGhost
  module Harnesses
    # One unit of work for a harness: the task and the limits it runs under.
    #
    #   LittleGhost::Harnesses::Request.new(
    #     prompt: "Add a test for the refund policy lookup.",
    #     cwd: "repository",
    #     budget_usd: 2,
    #     max_turns: 40,
    #     timeout: 900
    #   )
    #
    # +cwd+ is a Workspace path for the process's working directory.
    # +session_id+ resumes an earlier session of the same harness. +model+ and
    # +instructions+ (text added to the tool's system prompt, or placed before
    # the task when the tool has no such option) are optional. +add_dirs+ lists
    # extra absolute directories a tool may read. +budget_usd+ and +max_turns+
    # bound the work; +timeout+ bounds wall-clock seconds. +environment+ adds
    # child-process variables and takes precedence over harness defaults.
    #
    # Values that reach the command line are checked so they cannot be read as
    # options.
    class Request < Data.define(
      :prompt, :cwd, :session_id, :model, :instructions, :add_dirs, :budget_usd, :max_turns, :timeout, :environment
    )
      IDENTIFIER = %r{\A[A-Za-z0-9][A-Za-z0-9._:/@+-]{0,199}\z} # :nodoc:
      DEFAULT_TIMEOUT = 600 # :nodoc:

      ##
      # :attr_reader: prompt
      # The task given to the harness.

      ##
      # :attr_reader: cwd
      # Workspace path used as the working directory, or nil for the root.

      ##
      # :attr_reader: session_id
      # Harness session to resume, or nil to start a new one.

      ##
      # :attr_reader: model
      # Model name passed to the harness, or nil for its default.

      ##
      # :attr_reader: instructions
      # Additional instructions for the harness, or nil.

      ##
      # :attr_reader: add_dirs
      # Frozen Array of extra absolute directories the harness may read.

      ##
      # :attr_reader: budget_usd
      # Maximum spend in US dollars, or nil.

      ##
      # :attr_reader: max_turns
      # Maximum agent turns, or nil.

      ##
      # :attr_reader: timeout
      # Wall-clock limit in seconds.

      ##
      # :attr_reader: environment
      # Frozen Hash of additional child-process variables.

      # Builds a validated request. Raises ArgumentError for invalid values.
      def initialize(prompt:, cwd: nil, session_id: nil, model: nil, instructions: nil, add_dirs: [],
        budget_usd: nil, max_turns: nil, timeout: DEFAULT_TIMEOUT, environment: {})
        prompt = String(prompt)
        raise ArgumentError, "harness prompt must not be empty" if prompt.strip.empty?

        super(
          prompt: prompt.dup.freeze,
          cwd: cwd&.to_s&.dup&.freeze,
          session_id: identifier(session_id, "session_id"),
          model: identifier(model, "model"),
          instructions: instructions && String(instructions).dup.freeze,
          add_dirs: Array(add_dirs).map { |path| directory(path) }.freeze,
          budget_usd: budget_usd && positive_number(budget_usd, "budget_usd"),
          max_turns: max_turns && positive_integer(max_turns, "max_turns"),
          timeout: positive_number(timeout, "timeout"),
          environment: environment.to_h { |name, value| [String(name).dup.freeze, String(value).dup.freeze] }.freeze
        )
      end

      private

      def identifier(value, name)
        return if value.nil?

        value = String(value)
        raise ArgumentError, "harness #{name} contains unsupported characters" unless IDENTIFIER.match?(value)

        value.dup.freeze
      end

      def directory(value)
        value = String(value)
        raise ArgumentError, "harness add_dirs must be absolute paths" unless value.start_with?("/")

        value.dup.freeze
      end

      def positive_number(value, name)
        number = Float(value)
        raise ArgumentError, "harness #{name} must be positive" unless number.finite? && number.positive?

        (number == number.floor) ? number.to_i : number
      rescue TypeError
        raise ArgumentError, "harness #{name} must be a number"
      end

      def positive_integer(value, name)
        raise ArgumentError, "harness #{name} must be a positive integer" unless value.is_a?(Integer) && value.positive?

        value
      end
    end
  end
end
