# frozen_string_literal: true

module LittleGhost
  module Harnesses
    # Mutable progress that a harness parser records while reading one run's
    # output. Base#run creates one State per run and passes it to
    # Base#parse_line and Base#finalize; it is not shared across threads.
    class State
      # Session identifier reported by the tool.
      attr_accessor :session_id
      # Model reported by the tool.
      attr_accessor :model
      # The tool's latest or final answer text.
      attr_accessor :text
      # Reported spend in US dollars.
      attr_accessor :cost_usd
      # Completed agent turns.
      attr_accessor :turns
      # The tool's own reason for stopping.
      attr_accessor :stop_reason
      # Result status reported by the tool, overriding the exit code.
      attr_accessor :status
      # Accumulated token counts as a LittleGhost::Usage.
      attr_accessor :usage
      # Count of output lines that were not JSON objects.
      attr_accessor :malformed_lines

      # Builds empty progress.
      def initialize
        @usage = Usage.new
        @malformed_lines = 0
        @values = {}
      end

      # Parser-specific scratch values.
      attr_reader :values

      # Adds token counts to #usage.
      def add_usage(**counts)
        self.usage += Usage.new(**counts)
      end
    end
  end
end
