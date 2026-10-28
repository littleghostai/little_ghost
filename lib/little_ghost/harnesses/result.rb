# frozen_string_literal: true

module LittleGhost
  module Harnesses
    # The outcome of one Harnesses::Base#run.
    #
    # +status+ is one of:
    #
    # [+:completed+]
    #   The tool finished its task.
    # [+:failed+]
    #   The tool reported an error or exited unsuccessfully.
    # [+:timed_out+]
    #   The request's +timeout+ elapsed and the process was stopped.
    # [+:budget_exceeded+]
    #   The tool or the harness stopped because spending exceeded +budget_usd+.
    # [+:turns_exceeded+]
    #   The tool or the harness stopped because work exceeded +max_turns+.
    #
    # Any of +text+, +session_id+, +cost_usd+, +turns+, and +stop_reason+ may
    # be nil when the tool did not report them. A Result contains the tool's
    # output, which can include repository content; treat it as untrusted.
    class Result < Data.define(
      :harness, :status, :text, :session_id, :cost_usd, :usage, :turns, :exit_code, :stop_reason, :stderr_tail
    )
      STATUSES = %i[completed failed timed_out budget_exceeded turns_exceeded].freeze # :nodoc:

      ##
      # :attr_reader: harness
      # Identifier of the harness that produced the result, such as +:codex+.

      ##
      # :attr_reader: status
      # One of +:completed+, +:failed+, +:timed_out+, +:budget_exceeded+, or
      # +:turns_exceeded+.

      ##
      # :attr_reader: text
      # The tool's final answer, or nil.

      ##
      # :attr_reader: session_id
      # Session identifier that a later Request can resume, or nil.

      ##
      # :attr_reader: cost_usd
      # Reported spend in US dollars, or nil when the tool does not report it.

      ##
      # :attr_reader: usage
      # Token counts as a LittleGhost::Usage.

      ##
      # :attr_reader: turns
      # Number of agent turns, or nil.

      ##
      # :attr_reader: exit_code
      # Process exit status, or nil when the process was stopped by a signal.

      ##
      # :attr_reader: stop_reason
      # The tool's own reason for stopping, as a String, or nil.

      ##
      # :attr_reader: stderr_tail
      # The last few kilobytes of standard error.

      # Builds a result. Raises ArgumentError for an unknown +status+.
      def initialize(harness:, status:, usage: Usage.new, text: nil, session_id: nil, cost_usd: nil, turns: nil,
        exit_code: nil, stop_reason: nil, stderr_tail: "")
        status = status.to_sym
        raise ArgumentError, "unknown harness result status: #{status}" unless STATUSES.include?(status)

        super(
          harness: harness.to_sym,
          status:,
          text: text&.dup&.freeze,
          session_id: session_id&.dup&.freeze,
          cost_usd:,
          usage:,
          turns:,
          exit_code:,
          stop_reason: stop_reason&.to_s&.dup&.freeze,
          stderr_tail: String(stderr_tail).dup.freeze
        )
      end

      # Whether the tool finished its task.
      def completed? = status == :completed

      # Returns a JSON-compatible Hash with usage expanded.
      def to_h
        super.merge(usage: usage.to_h)
      end
    end
  end
end
