# frozen_string_literal: true

require "json"

module LittleGhost
  module Tracing
    # Keeps span attributes within a byte budget before a tracing backend
    # rejects or silently drops them. Captured model histories, Tool
    # arguments, and Tool results can grow far beyond what an exporter accepts;
    # a PayloadLimiter shortens them while keeping the parts a reader needs.
    #
    #   LittleGhost.configure do |config|
    #     config.instrument LittleGhost::Tracing::OpenTelemetry.new(
    #       payload_limiter: LittleGhost::Tracing::PayloadLimiter.new(max_bytes: 64_000)
    #     )
    #   end
    #
    # Only String attributes larger than +max_bytes+ change. Message lists in
    # +gen_ai.input.messages+ and the OpenInference +input.value+ keep the most
    # recent messages that fit, plus a leading system or developer message when
    # there is room. Output messages keep the leading choices. A Tool call and
    # its result are kept or dropped together, so a preview never shows a result
    # without its call. JSON values stay valid JSON, long strings keep their
    # beginning and end around a <tt>...[truncated]...</tt> marker, and
    # multibyte characters are never split.
    #
    # Each shortened attribute is recorded under +telemetry_truncation+ in the
    # OpenInference +metadata+ attribute, with its original and captured sizes
    # and, for message lists, how many messages were omitted. Existing metadata
    # is preserved.
    #
    # The limiter only shortens content that was already captured. It does not
    # scrub or redact; configure Support::ContentCapture for that. A limiter
    # holds no mutable state and can be shared across threads.
    class PayloadLimiter
      Result = Data.define(:value, :details) # :nodoc:
      private_constant :Result

      MESSAGE_ATTRIBUTES = {
        "gen_ai.input.messages" => :recent,
        "gen_ai.output.messages" => :leading
      }.freeze # :nodoc:
      OPENINFERENCE_MESSAGE_ATTRIBUTES = {
        "input.value" => :recent,
        "output.value" => :leading
      }.freeze # :nodoc:
      JSON_ATTRIBUTES = %w[
        gen_ai.tool.definitions
        gen_ai.tool.call.arguments
        gen_ai.tool.call.result
        tool.json_schema
      ].freeze # :nodoc:
      PROTECTED_STRING_KEYS = %w[role type id name finish_reason mime_type].freeze # :nodoc:
      TRUNCATION_MARKER = "...[truncated]..." # :nodoc:
      MINIMUM_BYTES = 1_024 # :nodoc:

      # The largest String attribute, in bytes, that passes through unchanged.
      attr_reader :max_bytes

      # Creates a limiter for String attributes larger than +max_bytes+, which
      # must be at least 1,024.
      def initialize(max_bytes:)
        @max_bytes = Integer(max_bytes)
        raise ArgumentError, "max_bytes must be at least #{MINIMUM_BYTES}" if @max_bytes < MINIMUM_BYTES
      end

      # Returns +attributes+ itself when every String fits, or a new Hash with
      # oversized values shortened and the +metadata+ attribute updated. If an
      # attribute cannot be shortened, only that attribute is omitted and
      # recorded as omitted, and a +little_ghost.tracing.payload_limit_failed+
      # warning is emitted through Events.
      def call(attributes)
        return attributes unless attributes.is_a?(Hash)

        transformed = attributes.dup
        truncations = {}
        attributes.each do |name, value|
          next if name == "metadata"
          next unless value.is_a?(String) && value.bytesize > @max_bytes

          result = limit_attribute(name, value)
          transformed[name] = result.value
          truncations[name] = result.details
        rescue => error
          Events.warn("little_ghost.tracing.payload_limit_failed", error_type: error.class.name)
          transformed.delete(name)
          truncations[name] = {"omitted" => true, "error" => error.class.name}
        end
        if transformed["metadata"].is_a?(String) && transformed["metadata"].bytesize > @max_bytes
          result = limit_json(transformed.fetch("metadata"))
          transformed["metadata"] = result.value
          truncations["metadata"] = result.details
        end
        return attributes if truncations.empty?

        transformed["metadata"] = metadata_with_truncations(transformed["metadata"], truncations)
        transformed
      rescue => error
        Events.warn("little_ghost.tracing.payload_limit_failed", error_type: error.class.name)
        omit_oversized_content(attributes, error)
      end

      private

      def limit_attribute(name, value)
        if MESSAGE_ATTRIBUTES.key?(name)
          limit_messages(value, selection: MESSAGE_ATTRIBUTES.fetch(name))
        elsif OPENINFERENCE_MESSAGE_ATTRIBUTES.key?(name)
          limit_openinference_value(value, selection: OPENINFERENCE_MESSAGE_ATTRIBUTES.fetch(name))
        else
          limit_json(value)
        end
      end

      def limit_messages(serialized, selection:)
        messages = JSON.parse(serialized)
        raise JSON::ParserError, "messages must be an array" unless messages.is_a?(Array)

        encoded, captured = encoded_message_preview(messages, selection:)
        message_truncation_result(serialized, encoded, messages.length, captured.length, selection)
      end

      def limit_openinference_value(serialized, selection:)
        value = JSON.parse(serialized)
        messages, wrapper = openinference_messages(value)
        return limit_json(serialized) unless messages

        encoded_messages, = encoded_message_preview(messages, selection:)
        encoded = wrapper ? fit_wrapped_messages(wrapper, JSON.parse(encoded_messages)) : encoded_messages
        captured_count = (openinference_messages(JSON.parse(encoded)).first || []).length
        message_truncation_result(serialized, encoded, messages.length, captured_count, selection)
      rescue JSON::ParserError
        limit_json(serialized)
      end

      def encoded_message_preview(messages, selection:)
        preview, = if selection == :recent
          recent_message_preview(messages)
        else
          leading_message_preview(messages)
        end
        encoded = fit_json(preview)
        [encoded, JSON.parse(encoded)]
      end

      def message_truncation_result(serialized, encoded, original_count, captured_count, selection)
        details = truncation_details(serialized, encoded)
        details["omitted_messages"] = original_count - captured_count
        details["selection"] = (selection == :recent) ? "recent_suffix" : "leading_choices"
        Result.new(value: encoded, details:)
      end

      def openinference_messages(value)
        return [value, nil] if value.is_a?(Array)
        return [nil, nil] unless value.is_a?(Hash) && value["messages"].is_a?(Array)

        [value.fetch("messages"), value]
      end

      def fit_wrapped_messages(wrapper, messages)
        candidate = deep_copy(wrapper)
        candidate["messages"] = messages
        encoded = JSON.generate(candidate)
        return encoded if encoded.bytesize <= @max_bytes

        fit_json(candidate)
      end

      def recent_message_preview(messages)
        groups = message_groups(messages)
        retained = []
        selected = []
        selected_count = 0
        selected_bytes = 0

        groups.reverse_each do |group|
          values = group.map(&:last)
          group_bytes = values.sum { |message| encoded_size(message) }
          if array_size(selected_bytes + group_bytes, selected_count + values.length) > @max_bytes
            break unless selected_count.zero?

            values = fit_recent_group(values)
            group_bytes = values.sum { |message| encoded_size(message) }
          end
          selected << values
          selected_count += values.length
          selected_bytes += group_bytes
          retained.concat(group.map(&:first))
        end
        preview = selected.reverse.flatten(1)

        if instruction_message?(messages.first) && !retained.include?(0) &&
            array_size(encoded_size(preview) - 2 + encoded_size(messages.first), preview.length + 1) <= @max_bytes
          preview.unshift(messages.first)
          retained << 0
        end

        [preview, retained.uniq.sort]
      end

      def fit_recent_group(messages)
        encoded = fit_json(messages)
        captured = JSON.parse(encoded)
        return captured if tool_pair_integrity?(messages, captured)

        paired_ids = paired_tool_ids(messages)
        return captured if paired_ids.empty?

        best = nil
        lower = 1
        upper = paired_ids.length
        while lower <= upper
          count = (lower + upper) / 2
          selected_ids = paired_ids.last(count)
          candidate = tool_group_subset(messages, selected_ids)
          candidate_encoded = fit_json(candidate)
          candidate_captured = JSON.parse(candidate_encoded)
          if tool_pair_integrity?(candidate, candidate_captured)
            best = candidate_captured
            lower = count + 1
          else
            upper = count - 1
          end
        end
        best || []
      end

      def paired_tool_ids(messages)
        call_ids = messages.flat_map { |message| tool_call_ids(message) }
        result_ids = messages.flat_map { |message| tool_result_ids(message) }.to_h { |id| [id, true] }
        call_ids.select { |id| result_ids.key?(id) }.uniq
      end

      def tool_group_subset(messages, selected_ids)
        messages.filter_map do |message|
          next unless message.is_a?(Hash)

          filtered_parts = message_parts(message).select do |part|
            next true unless part.is_a?(Hash) && %w[tool_call tool_call_response].include?(part["type"])

            selected_ids.include?(part["id"].to_s)
          end
          next if filtered_parts.empty?

          message.merge("parts" => filtered_parts)
        end
      end

      def tool_pair_integrity?(expected, captured)
        expected_ids = paired_tool_ids(expected)
        return true if expected_ids.empty?
        return false unless captured.is_a?(Array)

        captured_calls = captured.flat_map { |message| tool_call_ids(message) }.uniq
        captured_results = captured.flat_map { |message| tool_result_ids(message) }.uniq
        captured_calls.any? && captured_calls.sort == captured_results.sort
      end

      def leading_message_preview(messages)
        preview = []
        retained = []
        preview_bytes = 0
        messages.each_with_index do |message, index|
          message_bytes = encoded_size(message)
          if array_size(preview_bytes + message_bytes, preview.length + 1) <= @max_bytes
            preview << message
            preview_bytes += message_bytes
            retained << index
          elsif preview.empty?
            preview = JSON.parse(fit_json([message]))
            retained << index
          else
            break
          end
        end
        [preview, retained]
      end

      def message_groups(messages)
        groups = []
        index = 0
        while index < messages.length
          group = [[index, messages.fetch(index)]]
          call_ids = tool_call_ids(messages.fetch(index))
          following = index + 1
          while call_ids.any? && following < messages.length
            result_ids = tool_result_ids(messages.fetch(following))
            break if result_ids.empty? || (result_ids - call_ids).any?

            group << [following, messages.fetch(following)]
            following += 1
          end
          groups << group
          index = following
        end
        groups
      end

      def tool_call_ids(message)
        message_parts(message).filter_map do |part|
          part["id"].to_s if part.is_a?(Hash) && part["type"] == "tool_call"
        end
      end

      def tool_result_ids(message)
        message_parts(message).filter_map do |part|
          part["id"].to_s if part.is_a?(Hash) && part["type"] == "tool_call_response"
        end
      end

      def message_parts(message)
        message.is_a?(Hash) ? Array(message["parts"]) : []
      end

      def instruction_message?(message)
        message.is_a?(Hash) && %w[system developer].include?(message["role"].to_s)
      end

      def limit_json(serialized)
        value = JSON.parse(serialized)
        encoded = fit_json(value)
        details = truncation_details(serialized, encoded)
        if value.is_a?(Array)
          captured = JSON.parse(encoded)
          details["omitted_items"] = value.length - captured.length if captured.is_a?(Array)
        end
        Result.new(value: encoded, details:)
      rescue JSON::ParserError
        encoded = truncate_string(serialized, @max_bytes)
        Result.new(value: encoded, details: truncation_details(serialized, encoded))
      end

      def fit_json(value)
        working = deep_copy(value)
        encoded = JSON.generate(working)
        return encoded if encoded.bytesize <= @max_bytes

        references = shrinkable_strings(working)
        unless references.empty?
          lower = TRUNCATION_MARKER.bytesize
          upper = [references.map { |entry| entry.fetch(:value).bytesize }.max, @max_bytes].min
          best = nil
          while lower <= upper
            target = (lower + upper) / 2
            references.each do |reference|
              original = reference.fetch(:value)
              assign(
                reference.fetch(:parent),
                reference.fetch(:key),
                truncate_string(original, [original.bytesize, target].min)
              )
            end
            candidate = JSON.generate(working)
            if candidate.bytesize <= @max_bytes
              best = candidate
              lower = target + 1
            else
              upper = target - 1
            end
          end
          return best if best
        end

        fallback = minimal_value(working)
        encoded = JSON.generate(fallback)
        return encoded if encoded.bytesize <= @max_bytes

        JSON.generate("truncated" => true)
      end

      def shrinkable_strings(value, parent: nil, key: nil, result: [])
        case value
        when Hash
          value.each do |child_key, child|
            shrinkable_strings(child, parent: value, key: child_key, result:)
          end
        when Array
          value.each_with_index do |child, index|
            shrinkable_strings(child, parent: value, key: index, result:)
          end
        when String
          unless PROTECTED_STRING_KEYS.include?(key.to_s) || value.bytesize <= TRUNCATION_MARKER.bytesize
            result << {parent:, key:, value:}
          end
        end
        result
      end

      def truncate_string(value, target_bytes)
        return value if value.bytesize <= target_bytes
        return TRUNCATION_MARKER.byteslice(0, target_bytes) if target_bytes <= TRUNCATION_MARKER.bytesize

        available = target_bytes - TRUNCATION_MARKER.bytesize
        head_bytes = available / 2
        tail_bytes = available - head_bytes
        head = utf8_slice(value, 0, head_bytes)
        tail = utf8_slice(value, value.bytesize - tail_bytes, tail_bytes)
        "#{head}#{TRUNCATION_MARKER}#{tail}"
      end

      # scrub("") drops the partial characters at a cut edge, so a slice never grows.
      def utf8_slice(value, start, length)
        value.byteslice(start, length).force_encoding(Encoding::UTF_8).scrub("")
      end

      def minimal_value(value)
        case value
        when Array
          value.empty? ? [] : [minimal_value(value.last)]
        when Hash
          if value.key?("role")
            minimal_message(value)
          else
            {"truncated" => true}
          end
        when String
          TRUNCATION_MARKER
        else
          value
        end
      end

      def minimal_message(message)
        result = {"role" => message["role"].to_s, "parts" => []}
        result["finish_reason"] = message["finish_reason"] if message["finish_reason"]
        part = message_parts(message).last
        result["parts"] << minimal_part(part) if part
        result
      end

      def minimal_part(part)
        return {"type" => "text", "content" => TRUNCATION_MARKER} unless part.is_a?(Hash)

        case part["type"]
        when "tool_call"
          {
            "type" => "tool_call",
            "id" => part["id"].to_s,
            "name" => part["name"].to_s,
            "arguments" => {"truncated" => true}
          }
        when "tool_call_response"
          {
            "type" => "tool_call_response",
            "id" => part["id"].to_s,
            "response" => {"truncated" => true}
          }
        else
          {"type" => part["type"].to_s.empty? ? "text" : part["type"].to_s, "content" => TRUNCATION_MARKER}
        end
      end

      def metadata_with_truncations(serialized, truncations)
        metadata = JSON.parse(serialized.to_s)
        metadata = {} unless metadata.is_a?(Hash)
        existing = metadata["telemetry_truncation"]
        metadata["telemetry_truncation"] = (existing.is_a?(Hash) ? existing : {}).merge(truncations)
        encoded = JSON.generate(metadata)
        return encoded if encoded.bytesize <= @max_bytes

        fit_json("telemetry_truncation" => truncations)
      rescue JSON::ParserError, JSON::GeneratorError, EncodingError
        fit_json("telemetry_truncation" => truncations)
      end

      def truncation_details(original, captured)
        {
          "original_bytes" => original.bytesize,
          "captured_bytes" => captured.bytesize
        }
      end

      def omit_oversized_content(attributes, error)
        transformed = attributes.dup
        omitted = transformed.filter_map do |name, value|
          name if value.is_a?(String) && value.bytesize > @max_bytes
        end
        return attributes if omitted.empty?

        omitted.each { |name| transformed.delete(name) }
        truncations = omitted.to_h do |name|
          [name, {"omitted" => true, "error" => error.class.to_s}]
        end
        transformed["metadata"] = metadata_with_truncations(transformed["metadata"], truncations)
        transformed
      rescue
        transformed = attributes.reject { |_name, value| value.is_a?(String) && value.bytesize > @max_bytes }
        transformed.delete("metadata")
        transformed
      end

      def deep_copy(value)
        JSON.parse(JSON.generate(value))
      end

      def encoded_size(value)
        JSON.generate(value).bytesize
      end

      def array_size(element_bytes, count)
        2 + element_bytes + [count - 1, 0].max
      end

      def assign(parent, key, value)
        parent[key] = value
      end
    end
  end
end
