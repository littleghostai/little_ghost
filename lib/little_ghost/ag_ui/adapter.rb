# frozen_string_literal: true

require "securerandom"

module LittleGhost
  # AG-UI connects LittleGhost streams to user interfaces that speak the AG-UI
  # protocol. Require +little_ghost/ag_ui+ to load this optional integration.
  module AGUI
    # Adapter turns a LittleGhost stream into AG-UI event hashes. It lets a Ruby
    # agent drive compatible chat interfaces without changing the agent itself.
    #
    #   events = CustomerSupportAgent.stream_ask("Where is my order?")
    #   adapter = LittleGhost::AGUI::Adapter.new
    #   adapter.stream(events, thread_id: "thread-1", run_id: "run-1").each do |event|
    #     websocket.write(JSON.generate(event))
    #   end
    #
    # The adapter has no state between #stream calls, so one instance can
    # translate independent runs.
    #
    # Progress comes from the Run's native +:agent_stream+ events. By default,
    # only the top-level Agent's progress reaches the interface: its
    # AgentStreamSource[rdoc-ref:LittleGhost::AgentStreamSource] has +agent_path+
    # <tt>/root</tt> and an empty +assembly_path+. A composite run's final
    # response arrives in +RUN_FINISHED+ independently of participant progress.
    # Unwrapped progress and wrapped invocation usage or terminal events are
    # ignored; run lifecycle and aggregate usage remain separate.
    #
    # === Choose what the interface receives
    #
    # Pass a +source_filter+ callable to select a participant whose progress is
    # intended for the destination. The callable receives an AgentStreamSource
    # and replaces the default root selection. Choose it in trusted application
    # code, not from request or model values.
    #
    #   adapter = LittleGhost::AGUI::Adapter.new(source_filter: lambda { |source|
    #     step = source.assembly_path.first
    #     source.agent_path == "/root" && source.assembly_path.length == 1 &&
    #       step.assembly_id == "response_workflow" && step.participant == "response"
    #   })
    #
    # Provider plaintext reasoning becomes AG-UI reasoning events. Tool
    # arguments and results, invocation metadata, subagent events, trace context,
    # and selected error text also pass through without redaction. Authorize and
    # filter the complete stream before transport, and send it only to an
    # interface intended to display that data. Encrypted reasoning and provider
    # continuity artifacts are never exposed here.
    class Adapter
      TERMINAL_EVENTS = %i[run_partial run_cancel run_stop run_error].freeze # :nodoc:
      PROGRESS_EVENTS = %i[
        message_start reasoning_delta text_delta message_stop
        tool_call_start tool_call_delta tool_call_stop tool_stop
        model_retry agent_interjection_delivered
      ].freeze # :nodoc:

      # Selects which Agent's progress reaches the interface.
      #
      # +source_filter+ is a callable receiving an AgentStreamSource and returning
      # a truthy value to include its progress. Omit it to include only a root
      # Agent outside any composite assembly. A shared adapter may call the filter
      # concurrently for independent streams, so keep its captured state safe for
      # concurrent use. Filter exceptions propagate to the caller of #stream.
      # Raises ArgumentError when +source_filter+ is not callable.
      def initialize(source_filter: nil)
        if !source_filter.nil? && !source_filter.respond_to?(:call)
          raise ArgumentError, "source_filter must be callable"
        end

        @source_filter = source_filter
      end

      # Lazily translates a Run's +events+ into AG-UI hashes for one interface run.
      #
      # Returns an Enumerator. Selected Agent progress arrives as it is produced;
      # +RUN_FINISHED+ carries the run's final response in <tt>result[:response]</tt>.
      def stream(events, thread_id:, run_id:)
        Enumerator.new do |output|
          message_id = nil
          message_started = false
          reasoning_id = nil
          reasoning_message_id = nil
          tool_call_ids = {}

          events.each do |source|
            source = selected_event(source)
            next unless source

            superseded_message_id = message_id if source.type == :model_retry && message_started
            if reasoning_id && source.type != :reasoning_delta
              output << event("REASONING_MESSAGE_END", messageId: reasoning_message_id)
              output << event("REASONING_END", messageId: reasoning_id)
              reasoning_id = nil
              reasoning_message_id = nil
            end
            if message_started && (TERMINAL_EVENTS.include?(source.type) || source.type == :model_retry)
              output << event("TEXT_MESSAGE_END", messageId: message_id)
              message_id = nil
              message_started = false
            end
            if message_started && source.type == :message_start
              output << event("TEXT_MESSAGE_END", messageId: message_id)
              message_id = nil
              message_started = false
            end

            case source.type
            when :run_start
              output << event("RUN_STARTED", threadId: thread_id, runId: run_id)
            when :message_start
              message_id = SecureRandom.uuid
            when :reasoning_delta
              if message_started
                output << event("TEXT_MESSAGE_END", messageId: message_id)
                message_id = nil
                message_started = false
              end
              unless reasoning_id
                reasoning_id = SecureRandom.uuid
                reasoning_message_id = SecureRandom.uuid
                output << event("REASONING_START", messageId: reasoning_id)
                output << event(
                  "REASONING_MESSAGE_START",
                  messageId: reasoning_message_id,
                  role: "reasoning"
                )
              end
              output << event(
                "REASONING_MESSAGE_CONTENT",
                messageId: reasoning_message_id,
                delta: source.data.fetch(:text)
              )
            when :text_delta
              message_id ||= SecureRandom.uuid
              unless message_started
                output << event("TEXT_MESSAGE_START", messageId: message_id, role: "assistant")
                message_started = true
              end
              output << event("TEXT_MESSAGE_CONTENT", messageId: message_id, delta: source.data.fetch(:text))
            when :message_stop
              if message_started
                output << event("TEXT_MESSAGE_END", messageId: message_id)
              end
              message_id = nil
              message_started = false
            when :tool_call_start
              tool_call_ids[source.data.fetch(:index)] = source.data.fetch(:id)
              output << event(
                "TOOL_CALL_START",
                toolCallId: source.data.fetch(:id),
                toolCallName: source.data.fetch(:name),
                parentMessageId: (message_id if message_started)
              )
            when :tool_call_delta
              output << event(
                "TOOL_CALL_ARGS",
                toolCallId: tool_call_ids.fetch(source.data.fetch(:index), source.data.fetch(:index).to_s),
                delta: source.data.fetch(:arguments)
              )
            when :tool_call_stop
              output << event("TOOL_CALL_END", toolCallId: source.data.fetch(:tool_use).id)
            when :tool_stop
              tool_use = source.data.fetch(:tool_use)
              result = source.data.fetch(:result)
              output << event(
                "TOOL_CALL_RESULT",
                messageId: SecureRandom.uuid,
                toolCallId: tool_use.id,
                content: result.content,
                status: result.status,
                role: "tool"
              )
            when :invocation_stop
              result = source.data.fetch(:result)
              output << custom(
                "little_ghost.usage",
                usage: result.usage.to_h,
                metadata: source.data.fetch(:metadata, {})
              )
            when :invocation_error
              output << custom(
                "little_ghost.usage",
                usage: source.data.fetch(:usage).to_h,
                metadata: source.data.fetch(:metadata, {})
              )
            when :model_retry
              tool_call_ids.clear
              output << custom(
                "little_ghost.model_retry",
                source.data.merge(superseded_message_id:).compact
              )
            when :agent_interjection_delivered
              output << custom(
                "little_ghost.agent_interjection_delivered",
                source.data.slice(:interjection_ids, :batch_key).compact
              )
            when :subagent
              output << custom("little_ghost.subagent", source.data.fetch(:event, source.data))
            when :trace_context
              output << custom("little_ghost.trace_context", source.data.fetch(:context, source.data))
            when :run_partial
              output << custom(
                "little_ghost.run.partial",
                response: source.data.fetch(:response),
                message: source.data[:error]&.message
              )
              output << event(
                "RUN_FINISHED", threadId: thread_id, runId: run_id,
                result: {response: source.data.fetch(:response)}
              )
            when :run_cancel
              output << custom("little_ghost.run.canceled", reason: source.data[:error]&.message)
              output << event("RUN_FINISHED", threadId: thread_id, runId: run_id)
            when :run_stop
              output << event(
                "RUN_FINISHED", threadId: thread_id, runId: run_id,
                result: {response: source.data.fetch(:response)}
              )
            when :run_error
              output << event(
                "RUN_ERROR", threadId: thread_id, runId: run_id,
                message: source.data.fetch(:message),
                cleanupFailed: source.data.fetch(:cleanup_failed, true)
              )
            end
          end
        end
      end

      private

      def selected_event(event)
        return unless event.is_a?(StreamEvent)
        return PROGRESS_EVENTS.include?(event.type) ? nil : event unless event.type == :agent_stream

        source = event.data[:source]
        progress = event.data[:event]
        return unless source.is_a?(AgentStreamSource) && progress.is_a?(StreamEvent)
        return unless PROGRESS_EVENTS.include?(progress.type)

        selected = if @source_filter
          @source_filter.call(source)
        else
          source.agent_path == "/root" && source.assembly_path.empty?
        end
        progress if selected
      end

      def event(type, **attributes)
        {type:, **attributes.compact}
      end

      def custom(name, value = nil, **attributes)
        event("CUSTOM", name:, value: value || attributes)
      end
    end
  end
end
