# frozen_string_literal: true

require "json"
require "securerandom"

module LittleGhost
  class Agent
    # Keep long conversations within the model's available context window.
    # The capability summarizes older turns while preserving trusted instructions
    # and recent messages.
    #
    #   class CustomerSupportAgent < LittleGhost::Agent
    #     manage_context compression_threshold: 0.75,
    #       preserve_recent_messages: 12
    #   end
    #
    # As a support thread reaches the threshold, the next model request contains
    # a generated summary and targets retaining its 12 most recent conversation
    # messages. System and developer messages remain intact, and tool-use/result
    # pairs are never split merely to hit the requested count.
    #
    # A message whose metadata sets PINNED_METADATA_KEY is never summarized
    # away. +true+ pins it for good; an agent operation id pins it only during
    # that invocation. Pinned messages, with the other half of any tool-use/result
    # pair, stay verbatim ahead of the summary and still count toward the window.
    # Each invocation's request is pinned this way unless
    # +preserve_invocation_request: false+ is declared.
    #
    # The summary's metadata lists, under SUMMARIZED_METADATA_KEY, the scalar
    # metadata of every message it replaced, including those replaced by earlier
    # summaries, so applications can tell compacted messages from new ones.
    #
    # Context management is inactive until +manage_context+ is declared. The
    # configured window is a fallback: provider metadata takes precedence when
    # it advertises a positive context-window size. Compaction uses the current
    # model with the request's settings, cancellation token, and deadline.
    #
    # Request size is estimated at four characters per token. Once the
    # provider reports input usage, including cache reads and writes, a request
    # that extends the measured one is sized from that report plus an estimate
    # for the added messages, whichever is larger. Dense content such as
    # identifiers, numbers, and escaped JSON then still compacts before the
    # provider rejects it.
    #
    # Proactive compaction failures leave the original request unchanged and emit
    # diagnostic instrumentation. A provider context-overflow error triggers one
    # compaction replacement through the model-error callback; cancellation,
    # deadlines, and cleanup failures still escape as control flow.
    module ContextManagement
      DEFAULT_CONTEXT_WINDOW_TOKENS = 200_000 # :nodoc:
      DEFAULT_COMPRESSION_THRESHOLD = 0.85 # :nodoc:
      DEFAULT_SUMMARY_RATIO = 0.3 # :nodoc:
      DEFAULT_PRESERVE_RECENT_MESSAGES = 10 # :nodoc:
      ESTIMATED_CHARS_PER_TOKEN = 4 # :nodoc:
      # Message metadata key that keeps a message out of compaction summaries.
      PINNED_METADATA_KEY = "little_ghost.pinned"
      # Summary metadata key listing the scalar metadata of the messages it replaced.
      SUMMARIZED_METADATA_KEY = "little_ghost.summarized_metadata"
      OUTPUT_LIMIT_STOP_REASONS = %i[max_tokens limit_output_tokens limit_total_tokens limit_turns].freeze # :nodoc:
      def self.included(base) # :nodoc:
        base.extend(ClassMethods)
        base.class_attribute :context_management_configuration_value
      end

      # Exposes context-management declarations on agent classes.
      # These methods become inheritable DSL entries when the capability is included.
      module ClassMethods
        # Enables automatic context compaction for the agent class.
        #
        # The defaults assume a 200,000-token window, compact at 85% usage,
        # summarize about 30% of conversation messages, and preserve the 10 most
        # recent messages. The model's declared context window takes precedence
        # over +context_window_tokens+ when available.
        #
        # Invalid ranges raise ArgumentError when the agent class is defined.
        def manage_context(
          context_window_tokens: DEFAULT_CONTEXT_WINDOW_TOKENS,
          compression_threshold: DEFAULT_COMPRESSION_THRESHOLD,
          summary_ratio: DEFAULT_SUMMARY_RATIO,
          preserve_recent_messages: DEFAULT_PRESERVE_RECENT_MESSAGES,
          preserve_invocation_request: true
        )
          context_window_tokens = Integer(context_window_tokens)
          compression_threshold = Float(compression_threshold)
          summary_ratio = Float(summary_ratio)
          preserve_recent_messages = Integer(preserve_recent_messages)
          raise ArgumentError, "context_window_tokens must be positive" unless context_window_tokens.positive?
          unless compression_threshold.positive? && compression_threshold <= 1
            raise ArgumentError, "compression_threshold must be between 0 and 1"
          end
          unless summary_ratio.between?(0.1, 0.8)
            raise ArgumentError, "summary_ratio must be between 0.1 and 0.8"
          end
          raise ArgumentError, "preserve_recent_messages must be at least 2" if preserve_recent_messages < 2

          self.context_management_configuration_value = {
            context_window_tokens:,
            compression_threshold:,
            summary_ratio:,
            preserve_recent_messages:,
            preserve_invocation_request: preserve_invocation_request ? true : false
          }
          before_invocation :pin_invocation_request
          before_model :compact_model_context
          after_model :record_reported_context_tokens
          after_model_error :compact_context_after_overflow
        end

        def context_management_configuration = context_management_configuration_value # :nodoc:
      end

      private

      def pin_invocation_request(payload, context: nil)
        messages = payload.fetch(:messages)
        request = messages.last
        return Support::Callbacks.continue unless self.class.context_management_configuration.fetch(:preserve_invocation_request)
        return Support::Callbacks.continue unless request&.role == :user && context&.agent_operation_id
        return Support::Callbacks.continue if pinned_message?(request, context)

        pinned = Message.new(
          role: request.role,
          content: request.content,
          metadata: request.metadata.to_h.merge(PINNED_METADATA_KEY => context.agent_operation_id)
        )
        Support::Callbacks.replace(payload.merge(messages: [*messages[...-1], pinned]))
      end

      def compact_model_context(payload, context: nil)
        request = payload.fetch(:request)
        configuration = self.class.context_management_configuration
        limit = model_context_window_tokens(configuration)
        threshold = limit * configuration.fetch(:compression_threshold)
        return Support::Callbacks.continue if context_tokens(request) < threshold

        compacted = compact_context(
          request,
          configuration,
          context,
          context_window_tokens: limit,
          parent_operation_id: payload[:parent_operation_id]
        )
        Support::Callbacks.replace(payload.merge(request: compacted))
      rescue CancelledError, DeadlineExceededError, CleanupError
        raise
      rescue => error
        Instrumentation.publish(:context_compaction, outcome: :error, error_class: error.class.name)
        Support::Callbacks.continue
      end

      def record_reported_context_tokens(payload, context: nil)
        usage = payload.fetch(:response).usage
        tokens = usage.input_tokens + usage.cache_read_tokens + usage.cache_write_tokens
        @_little_ghost_reported_context = {messages: payload.fetch(:request).messages, tokens:} if tokens.positive?
        Support::Callbacks.continue
      end

      def compact_context_after_overflow(payload, context: nil)
        return Support::Callbacks.continue unless payload.fetch(:error).is_a?(ContextWindowOverflowError)

        configuration = self.class.context_management_configuration
        request = payload.fetch(:request)
        compacted = compact_context(
          request,
          configuration,
          context,
          context_window_tokens: model_context_window_tokens(configuration),
          reason: :overflow,
          parent_operation_id: payload[:parent_operation_id]
        )
        Support::Callbacks.replace(payload.merge(request: compacted))
      end

      def summarize_oldest_messages(request, configuration, context, parent_operation_id:)
        trusted, conversation = request.messages.partition { |message| %i[system developer].include?(message.role) }
        pinned = pinned_messages(conversation, context)
        kept = conversation.take_while { |message| pinned.include?(message) }
        conversation = conversation.drop(kept.length)
        preserve = configuration.fetch(:preserve_recent_messages)
        split = [(conversation.length * configuration.fetch(:summary_ratio)).floor, 1].max
        split = [split, conversation.length - preserve].min
        raise ProtocolError, "Not enough conversation history to compact" unless split.positive?

        split = safe_summary_split(conversation, split)
        hoisted, to_summarize = conversation.first(split).partition { |message| pinned.include?(message) }
        summary = generate_context_summary(to_summarize, request, context, parent_operation_id:)
        ModelRequest.new(
          messages: [*trusted, *kept, *hoisted, summary, *conversation.drop(split)],
          tools: request.tools,
          settings: request.settings,
          output_schema: request.output_schema,
          tool_choice: request.tool_choice,
          required_capabilities: request.required_capabilities,
          cancellation_token: request.cancellation_token,
          deadline: request.deadline
        )
      end

      def compact_context(
        request,
        configuration,
        context,
        context_window_tokens:,
        parent_operation_id:,
        reason: :threshold
      )
        compacted = summarize_oldest_messages(request, configuration, context, parent_operation_id:)
        Instrumentation.publish(
          :context_compaction,
          reason:,
          removed_messages: request.messages.length - compacted.messages.length,
          estimated_tokens: context_tokens(request),
          context_window_tokens:
        )
        compacted
      end

      def pinned_messages(messages, context)
        pinned = Set.new.compare_by_identity
        messages.each_cons(2) do |use, result|
          next unless tool_pair?(use, result)
          next unless pinned_message?(use, context) || pinned_message?(result, context)

          pinned << use << result
        end
        pinned.merge(messages.select { |message| pinned_message?(message, context) })
      end

      def pinned_message?(message, context)
        value = message.metadata[PINNED_METADATA_KEY]
        value == true || (!value.nil? && value == context&.agent_operation_id)
      end

      def summarized_metadata(messages)
        messages.flat_map do |message|
          earlier = Array(message.metadata[SUMMARIZED_METADATA_KEY]).map(&:to_h)
          own = message.metadata.to_h.except(SUMMARIZED_METADATA_KEY, PINNED_METADATA_KEY).select { |_key, value| scalar?(value) }
          own.empty? ? earlier : [*earlier, own]
        end.uniq
      end

      def scalar?(value)
        value.is_a?(String) || value.is_a?(Numeric) || value == true || value == false
      end

      def tool_pair?(use, result)
        use.content.any?(Content::ToolUse) && result.content.any?(Content::ToolResult)
      end

      def safe_summary_split(messages, split)
        while split < messages.length
          current = messages.fetch(split)
          previous = messages.fetch(split - 1)
          current_results = current.content.grep(Content::ToolResult).map(&:tool_use_id)
          previous_uses = previous.content.grep(Content::ToolUse).map(&:id)
          break if current_results.empty? && previous_uses.empty?

          split += 1
        end
        split
      end

      def generate_context_summary(messages, request, context, parent_operation_id:)
        operation_id = SecureRandom.uuid
        started_at = monotonic_time
        summary_request = ModelRequest.new(
          messages: [
            Message.new(role: :system, content: render_framework_prompt("context_management/summary/system_instruction")),
            *messages,
            Message.new(role: :user, content: render_framework_prompt("context_management/summary/request"))
          ],
          tools: [],
          settings: request.settings,
          cancellation_token: request.cancellation_token,
          deadline: request.deadline
        )
        instrument(
          :model_start,
          operation_id:,
          parent_operation_id:,
          purpose: :context_compaction,
          diagnostic: {
            input: summary_request.messages.map { |message| diagnostic_message(message) },
            tool_definitions: summary_request.tools
          },
          model_settings: summary_request.settings,
          **model_attributes
        )
        response = nil
        time_to_first_token = nil
        model.stream(summary_request).each do |event|
          context&.check!
          time_to_first_token ||= duration_seconds(started_at) if model_output_event?(event)
          response = event.data[:response] if event.type == :message_stop
        end
        raise ProtocolError, "Context summarization ended without a response" unless response
        context&.record_usage(response.usage)
        if OUTPUT_LIMIT_STOP_REASONS.include?(response.stop_reason)
          raise OutputLimitError, "The context summary stopped before completion"
        end

        instrument(
          :model_stop,
          operation_id:,
          parent_operation_id:,
          purpose: :context_compaction,
          outcome: :completed,
          duration_ms: duration_ms(started_at),
          time_to_first_token:,
          stop_reason: response.stop_reason,
          **response_attributes(response),
          diagnostic: {output: diagnostic_message(response.message)},
          **model_attributes,
          **usage_attributes(response.usage)
        )
        provenance = summarized_metadata(messages)
        Message.new(
          role: :user,
          content: response.message.content,
          metadata: provenance.empty? ? {} : {SUMMARIZED_METADATA_KEY => provenance}
        )
      rescue => error
        instrument(
          :model_stop,
          operation_id:,
          parent_operation_id:,
          purpose: :context_compaction,
          outcome: :error,
          duration_ms: duration_ms(started_at),
          time_to_first_token:,
          error_type: error.class.name,
          diagnostic: {exception: diagnostic_exception(error)},
          **model_attributes
        )
        raise
      end

      def model_context_window_tokens(configuration)
        value = model.details.context_window
        value = Integer(value) if value
        value&.positive? ? value : configuration.fetch(:context_window_tokens)
      rescue ArgumentError, TypeError
        configuration.fetch(:context_window_tokens)
      end

      def context_tokens(request)
        estimate = estimated_request_tokens(request)
        reported = @_little_ghost_reported_context
        return estimate unless reported && extends_messages?(request.messages, reported.fetch(:messages))

        added = request.messages.drop(reported.fetch(:messages).length)
        [estimate, reported.fetch(:tokens) + estimated_message_tokens(added)].max
      end

      def extends_messages?(messages, prefix)
        prefix.length <= messages.length && prefix.each_with_index.all? { |message, index| messages[index].equal?(message) }
      end

      def estimated_message_tokens(messages)
        (JSON.generate(messages.map { |message| estimation_message(message) }).length.to_f / ESTIMATED_CHARS_PER_TOKEN).ceil
      rescue JSON::GeneratorError
        messages.sum { |message| message.text.length } / ESTIMATED_CHARS_PER_TOKEN
      end

      def estimation_message(message)
        message.to_h.merge("metadata" => message.metadata.to_h.except(SUMMARIZED_METADATA_KEY))
      end

      def estimated_request_tokens(request)
        characters = JSON.generate(
          messages: request.messages.map { |message| estimation_message(message) },
          tools: request.tools,
          output_schema: request.output_schema,
          tool_choice: request.tool_choice
        ).length
        (characters.to_f / ESTIMATED_CHARS_PER_TOKEN).ceil
      rescue JSON::GeneratorError
        request.messages.sum { |message| message.text.length } / ESTIMATED_CHARS_PER_TOKEN
      end
    end
  end
end
