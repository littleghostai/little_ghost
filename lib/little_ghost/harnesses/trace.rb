# frozen_string_literal: true

module LittleGhost
  module Harnesses
    # Trace records one harness run in Instrumentation beneath the operation
    # that delegated it: each tool call the harness makes becomes a +:tool+
    # operation, and its start and messages become +:harness_start+ and
    # +:harness_text+ events. Tool inputs, tool outputs, and message text are
    # diagnostic content, so they appear only under a ContentCapture policy.
    class Trace # :nodoc:
      INCOMPLETE = "harness_tool_incomplete"
      FAILED = "harness_tool_failed"

      def initialize(harness:, parent_operation_id:)
        @harness = harness.to_s
        @parent_operation_id = parent_operation_id
        @calls = {}
      end

      def record(event)
        activity = event.data.fetch(:event)
        case activity[:kind]
        when :start then publish(:harness_start, model: activity[:model], version: activity[:version])
        when :text then publish(:harness_text, diagnostic: {output: activity[:text]})
        when :tool_call then start_call(activity)
        when :tool_result then finish_call(activity[:id], error_type: (FAILED if activity[:error]), output: activity[:output])
        when :stop then close
        end
      end

      # Finishes tool calls the harness started but never reported.
      def close
        @calls.keys.each { |id| finish_call(id, error_type: INCOMPLETE) }
      end

      private

      def publish(name, diagnostic: nil, **attributes)
        Instrumentation.publish(name, operation_id: @parent_operation_id, harness: @harness, diagnostic:, **attributes)
      end

      def start_call(activity)
        id = activity[:id].to_s
        return if id.empty? || @calls.key?(id)

        @calls[id] = Instrumentation.start(
          :tool,
          parent: @parent_operation_id,
          detached: true,
          harness: @harness,
          tool_name: activity[:name].to_s,
          tool_type: "function",
          tool_call_id: id,
          diagnostic: {input: activity[:input]}
        )
      end

      def finish_call(id, error_type:, output: nil)
        handle = @calls.delete(id.to_s)
        return unless handle

        handle.finish(
          outcome: error_type ? :error : :ok,
          error_type:,
          diagnostic: output.nil? ? nil : {output:}
        )
      end
    end
  end
end
